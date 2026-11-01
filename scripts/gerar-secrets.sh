#!/usr/bin/env bash
# Gera os Secrets do kubernetes a partir do que ja existe na aws.
#
# Nada e digitado na mao. Endpoint errado nao da erro de sintaxe: o pod
# sobe e falha na conexao, e voce perde meia hora achando que e outra
# coisa. Entao tudo vem de consulta.
#
# Mudou da fase 2:
#   - a senha do rds vem do secrets manager, nao de um .env local
#   - AWS_ACCESS_KEY_ID e AWS_SECRET_ACCESS_KEY SUMIRAM. quem autentica
#     agora e o irsa, pela service account do pod.
#
# Esses secrets NAO vao pro git de proposito - o repositorio e publico.
# Por isso tambem nao estao nos manifestos do gitops/: se estivessem,
# o argocd com selfHeal reverteria o valor real pro placeholder.
#
# Uso:
#   ./scripts/gerar-secrets.sh | kubectl apply -f -
#
# A SERVICE_API_KEY so existe depois do auth-service estar no ar. Na
# primeira rodada ela vai vazia; depois de gerar a chave, rode de novo:
#   SERVICE_API_KEY=tm_key_... ./scripts/gerar-secrets.sh | kubectl apply -f -
set -euo pipefail

REGIAO=${AWS_REGION:-us-east-1}
NOME=togglemaster
DB_USER=toggle

segredo() {
  aws secretsmanager get-secret-value --region "$REGIAO" \
    --secret-id "$1" --query SecretString --output text
}

# a senha nasceu do random_password no terraform e foi parar aqui.
# ninguem nunca digitou ela.
RDS_PASSWORD=$(segredo "${NOME}/rds" | python3 -c 'import json,sys; print(json.load(sys.stdin)["password"], end="")')
MASTER_KEY=$(segredo "${NOME}/auth-master-key")

: "${SERVICE_API_KEY:=}"
[ -n "$SERVICE_API_KEY" ] || echo "aviso: SERVICE_API_KEY vazia - o evaluation vai tomar 401 ate voce gerar a chave" >&2

rds() {
  aws rds describe-db-instances --region "$REGIAO" \
    --db-instance-identifier "$1" \
    --query 'DBInstances[0].Endpoint.Address' --output text
}

RDS_AUTH=$(rds ${NOME}-auth)
RDS_FLAGS=$(rds ${NOME}-flags)
RDS_TARGETING=$(rds ${NOME}-targeting)

REDIS=$(aws elasticache describe-replication-groups --region "$REGIAO" \
          --replication-group-id ${NOME}-redis \
          --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address' --output text)

# o cluster subiu com criptografia em transito, entao e rediss:// e nao
# redis://. o go-redis liga o tls sozinho ao ver esse esquema na url.
# consultado em vez de chumbado: se mudar no terraform, isso acompanha.
TLS=$(aws elasticache describe-replication-groups --region "$REGIAO" \
        --replication-group-id ${NOME}-redis \
        --query 'ReplicationGroups[0].TransitEncryptionEnabled' --output text)
[ "$TLS" = "True" ] && SCHEME=rediss || SCHEME=redis

SQS_URL=$(aws sqs get-queue-url --region "$REGIAO" --queue-name ${NOME}-events --query QueueUrl --output text)

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# a senha vai dentro de uma url de conexao, entao precisa de
# percent-encoding. aprendi na marra na fase 2: senha com # cortava a
# string no parser do pgx e o auth nao subia. hoje a senha vem sem
# caractere especial do terraform, mas a protecao fica.
urlenc() { printf '%s' "$1" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read(), safe=""), end="")'; }
PW=$(urlenc "$RDS_PASSWORD")

cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: auth-secret
  namespace: auth
type: Opaque
data:
  DATABASE_URL: "$(b64 "postgres://${DB_USER}:${PW}@${RDS_AUTH}:5432/auth_db?sslmode=require")"
  MASTER_KEY: "$(b64 "$MASTER_KEY")"
---
apiVersion: v1
kind: Secret
metadata:
  name: flag-secret
  namespace: flags
type: Opaque
data:
  DATABASE_URL: "$(b64 "postgres://${DB_USER}:${PW}@${RDS_FLAGS}:5432/flags_db?sslmode=require")"
---
apiVersion: v1
kind: Secret
metadata:
  name: targeting-secret
  namespace: targeting
type: Opaque
data:
  DATABASE_URL: "$(b64 "postgres://${DB_USER}:${PW}@${RDS_TARGETING}:5432/targeting_db?sslmode=require")"
---
apiVersion: v1
kind: Secret
metadata:
  name: evaluation-secret
  namespace: evaluation
type: Opaque
data:
  REDIS_URL: "$(b64 "${SCHEME}://${REDIS}:6379")"
  SERVICE_API_KEY: "$(b64 "$SERVICE_API_KEY")"
  AWS_SQS_URL: "$(b64 "$SQS_URL")"
---
apiVersion: v1
kind: Secret
metadata:
  name: analytics-secret
  namespace: analytics
type: Opaque
data:
  AWS_SQS_URL: "$(b64 "$SQS_URL")"
YAML
