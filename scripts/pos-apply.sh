#!/usr/bin/env bash
# Tudo que precisa acontecer DEPOIS do terraform apply.
#
# O terraform entrega a infraestrutura. Isso aqui entrega o cluster
# utilizavel: argocd, controlador de ingress, namespaces, secrets,
# schema dos bancos e a chave de servico.
#
# Idempotente: rodar de novo nao quebra nada.
#
# Uso: ./scripts/pos-apply.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REGIAO=${AWS_REGION:-us-east-1}
CLUSTER=togglemaster

echo "==> 1/7 apontando o kubectl pro cluster"
aws eks update-kubeconfig --region "$REGIAO" --name "$CLUSTER"
kubectl get nodes

echo "==> 1.5 conferindo que o ecr tem as imagens"
# o destroy apaga os repositorios do ecr junto (force_delete). num
# ambiente recriado eles nascem vazios, e os manifestos do gitops
# apontam pra uma tag que nao existe mais -> ImagePullBackOff.
# falhar aqui com mensagem clara e melhor que travar no passo 7.
FALTANDO=""
for s in auth-service flag-service targeting-service evaluation-service analytics-service; do
  TAG=$(sed -n "s|.*image: .*/togglemaster/${s}:||p" "gitops/${s}/app.yaml" | tr -d ' ')
  EXISTE=$(aws ecr describe-images --region "$REGIAO" \
            --repository-name "togglemaster/${s}" --image-ids imageTag="$TAG" \
            --query 'imageDetails[0].imageTags' --output text 2>/dev/null || true)
  [ -n "$EXISTE" ] || FALTANDO="$FALTANDO\n    togglemaster/${s}:${TAG}"
done
if [ -n "$FALTANDO" ]; then
  echo >&2
  echo "ERRO: faltam imagens no ecr:$(printf "$FALTANDO")" >&2
  echo >&2
  echo "dispare os pipelines e espere terminarem:" >&2
  for s in auth flag targeting evaluation analytics; do
    echo "  gh workflow run ci-${s}-service.yml" >&2
  done
  echo >&2
  echo "eles empurram a imagem pro ecr e commitam a tag nova no gitops/." >&2
  echo "depois: git pull && ./scripts/pos-apply.sh" >&2
  exit 1
fi
echo "    todas as 5 imagens presentes"

echo "==> 2/7 instalando o argocd"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd -n argocd --create-namespace --wait --timeout 10m

echo "==> 3/7 instalando o controlador de ingress"
# sem controlador, Ingress e so um objeto no etcd: nenhum load balancer
# e criado e o argocd deixa o Application em Progressing pra sempre.
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo update ingress-nginx >/dev/null
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"=nlb \
  --wait --timeout 10m

echo "==> 4/7 namespaces e secrets"
# os namespaces vem antes dos secrets, e os secrets antes do argocd
# sincronizar, senao os pods sobem sem credencial e caem em CrashLoop.
kubectl apply -f gitops/base/00-namespaces.yaml
./scripts/gerar-secrets.sh | kubectl apply -f -

echo "==> 5/7 schema dos bancos"
# o rds entrega banco vazio. no docker-compose da fase 2 a imagem do
# postgres rodava o init.sql sozinha; aqui nao tem esse gancho.
# os rds so aceitam conexao dos nos, entao roda de dentro do cluster.
aplica_schema() {
  local svc=$1 ns=$2 sec=$3
  echo "    $svc -> ns $ns"
  local ov
  ov=$(python3 -c "
import json
print(json.dumps({'spec':{'containers':[{'name':'psql','image':'postgres:16-alpine',
'stdin':True,'stdinOnce':True,'envFrom':[{'secretRef':{'name':'$sec'}}],
'command':['sh','-c','psql \"\$DATABASE_URL\" -v ON_ERROR_STOP=1 -f -']}],'restartPolicy':'Never'}}))")
  kubectl run "psql-$ns-$RANDOM" -n "$ns" --rm -i --restart=Never \
    --image=postgres:16-alpine --overrides="$ov" < "services/$svc/db/init.sql"
}
aplica_schema auth-service      auth      auth-secret
aplica_schema flag-service      flags     flag-secret
aplica_schema targeting-service targeting targeting-secret

echo "==> 6/7 applications do argocd"
# o unico kubectl apply que sobra. bootstrap do gitops.
kubectl apply -f gitops/argocd/applications.yaml
echo "    esperando os pods subirem..."
for i in $(seq 1 40); do
  P=$(kubectl get pods -n auth --no-headers 2>/dev/null | grep -c "1/1" || echo 0)
  [ "$P" -gt 0 ] && break
  sleep 10
done

echo "==> 7/7 chave de servico do evaluation"
# so pode ser gerada depois do auth estar no ar e com schema criado.
LB=""
for i in $(seq 1 30); do
  LB=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$LB" ] && curl -sf --max-time 5 "http://$LB/auth/health" >/dev/null 2>&1 && break
  echo "    esperando o load balancer responder (tentativa $i/30)"
  sleep 15
done

MK=$(aws secretsmanager get-secret-value --region "$REGIAO" \
      --secret-id togglemaster/auth-master-key --query SecretString --output text)
RESP=$(curl -s --max-time 20 -X POST "http://$LB/auth/admin/keys" \
        -H "Authorization: Bearer $MK" -H "Content-Type: application/json" \
        -d '{"name":"evaluation-service"}')
KEY=$(printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("key",""))' 2>/dev/null || true)

if [ -z "$KEY" ]; then
  echo "    nao consegui gerar a chave. resposta: $RESP" >&2
  exit 1
fi
echo "    chave gerada: ${KEY:0:10}********"

SERVICE_API_KEY="$KEY" ./scripts/gerar-secrets.sh | kubectl apply -f -
kubectl rollout restart deploy/evaluation-service -n evaluation
kubectl rollout status deploy/evaluation-service -n evaluation --timeout=180s

echo
echo "pronto. load balancer: http://$LB"
echo "  curl http://$LB/auth/health"
echo "  curl 'http://$LB/evaluate?user_id=u1&flag_name=novo-checkout'"
echo
kubectl get applications -n argocd
