#!/usr/bin/env bash
# Derruba o ambiente na ordem certa.
#
# A ORDEM IMPORTA. O terraform nao conhece os recursos que o kubernetes
# criou na aws - o Load Balancer do ingress-nginx e o maior deles. Se
# rodar terraform destroy direto, ele tenta apagar a vpc, a vpc recusa
# porque tem um load balancer dentro, e o destroy trava depois de uns
# 20 minutos. O load balancer fica orfao cobrando por hora.
#
# Uso: ./scripts/teardown.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REGIAO=${AWS_REGION:-us-east-1}

echo "==> 1/5 removendo os Applications do argocd"
# sem isso o argocd recria os deployments enquanto a gente apaga
kubectl delete -f gitops/argocd/applications.yaml --ignore-not-found --wait=true || true

echo "==> 2/5 removendo os ingress (libera o load balancer)"
kubectl delete ingress --all -A --ignore-not-found || true

echo "==> 3/5 desinstalando ingress-nginx e argocd"
helm uninstall ingress-nginx -n ingress-nginx --wait 2>/dev/null || true
helm uninstall argocd -n argocd --wait 2>/dev/null || true
kubectl delete namespace ingress-nginx argocd --ignore-not-found --wait=true 2>/dev/null || true
kubectl delete namespace auth flags targeting evaluation analytics --ignore-not-found --wait=true 2>/dev/null || true

echo "==> 4/5 esperando o load balancer sumir da aws"
# o controlador apaga o NLB de forma assincrona. seguir antes dele sumir
# e o jeito classico de travar o destroy da vpc.
for i in $(seq 1 30); do
  N=$(aws elbv2 describe-load-balancers --region "$REGIAO" \
        --query "length(LoadBalancers[?VpcId!=null])" --output text 2>/dev/null || echo 0)
  C=$(aws elb describe-load-balancers --region "$REGIAO" \
        --query "length(LoadBalancerDescriptions)" --output text 2>/dev/null || echo 0)
  echo "    load balancers restantes: nlb/alb=$N classic=$C (tentativa $i/30)"
  [ "$N" = "0" ] && [ "$C" = "0" ] && break
  sleep 10
done

echo "==> 5/5 terraform destroy"
cd infra
terraform destroy -auto-approve

echo
echo "pronto. confira no console se sobrou algo:"
echo "  EC2 -> Instances, Volumes, Elastic IPs, Load Balancers"
echo "  VPC | CloudWatch Log Groups | ECR | Secrets Manager"
