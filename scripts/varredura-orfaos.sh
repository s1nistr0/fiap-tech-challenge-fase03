#!/usr/bin/env bash
# confere se o destroy deixou recurso para tras.
# nao apaga nada: so lista. decidir e apagar e com voce.
set -uo pipefail
REGIAO="${AWS_REGION:-us-east-1}"
MARCA="togglemaster"
ACHOU=0

titulo() { printf '\n== %s\n' "$1"; }

reporta() {
  # $1 descricao, $2 saida do comando
  # a aws cli imprime "None" quando a chave consultada vem nula: nao e recurso.
  local S
  S=$(printf '%s' "$2" | grep -v '^None$' | sed '/^[[:space:]]*$/d')
  if [ -n "$S" ]; then
    printf '   SOBROU:\n'
    printf '%s\n' "$S" | sed 's/^/     /'
    ACHOU=1
  else
    printf '   limpo\n'
  fi
}

titulo "cluster eks"
reporta "" "$(aws eks list-clusters --region "$REGIAO" \
  --query "clusters[?contains(@,'$MARCA')]" --output text 2>/dev/null)"

titulo "instancias ec2 (nos do cluster)"
reporta "" "$(aws ec2 describe-instances --region "$REGIAO" \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].[InstanceId,Tags[?Key=='Name']|[0].Value]" \
  --output text 2>/dev/null | grep -i "$MARCA" || true)"

titulo "bancos rds"
reporta "" "$(aws rds describe-db-instances --region "$REGIAO" \
  --query "DBInstances[?contains(DBInstanceIdentifier,'$MARCA')].DBInstanceIdentifier" \
  --output text 2>/dev/null)"

titulo "elasticache"
reporta "" "$(aws elasticache describe-replication-groups --region "$REGIAO" \
  --query "ReplicationGroups[?contains(ReplicationGroupId,'$MARCA')].ReplicationGroupId" \
  --output text 2>/dev/null)"

titulo "load balancers (os que o kubernetes cria ficam orfaos)"
reporta "" "$(aws elbv2 describe-load-balancers --region "$REGIAO" \
  --query "LoadBalancers[].LoadBalancerName" --output text 2>/dev/null)"
printf '   classicos: '
CLB=$(aws elb describe-load-balancers --region "$REGIAO" \
  --query "LoadBalancerDescriptions[].LoadBalancerName" --output text 2>/dev/null)
[ -n "$CLB" ] && { printf '\n'; reporta "" "$CLB"; } || printf 'limpo\n'

titulo "elastic ips soltos (cobram quando nao associados)"
reporta "" "$(aws ec2 describe-addresses --region "$REGIAO" \
  --query "Addresses[?AssociationId==null].[PublicIp,AllocationId]" \
  --output text 2>/dev/null)"

titulo "nat gateways"
reporta "" "$(aws ec2 describe-nat-gateways --region "$REGIAO" \
  --filter "Name=state,Values=pending,available,deleting" \
  --query "NatGateways[].[NatGatewayId,State]" --output text 2>/dev/null)"

titulo "volumes ebs disponiveis (cobram parados)"
reporta "" "$(aws ec2 describe-volumes --region "$REGIAO" \
  --filters "Name=status,Values=available" \
  --query "Volumes[].[VolumeId,Size]" --output text 2>/dev/null)"

titulo "vpc"
reporta "" "$(aws ec2 describe-vpcs --region "$REGIAO" \
  --query "Vpcs[?!(IsDefault)].[VpcId,Tags[?Key=='Name']|[0].Value]" \
  --output text 2>/dev/null)"

titulo "repositorios ecr"
reporta "" "$(aws ecr describe-repositories --region "$REGIAO" \
  --query "repositories[?contains(repositoryName,'$MARCA')].repositoryName" \
  --output text 2>/dev/null)"

titulo "fila sqs"
reporta "" "$(aws sqs list-queues --region "$REGIAO" \
  --queue-name-prefix "$MARCA" --query "QueueUrls" --output text 2>/dev/null)"

titulo "tabela dynamodb"
reporta "" "$(aws dynamodb list-tables --region "$REGIAO" \
  --query "TableNames[?contains(@,'ToggleMaster')]" --output text 2>/dev/null)"

titulo "secrets manager (ficam agendados para exclusao)"
reporta "" "$(aws secretsmanager list-secrets --region "$REGIAO" \
  --query "SecretList[?contains(Name,'$MARCA')].[Name,DeletedDate]" \
  --output text 2>/dev/null)"

titulo "log groups do cloudwatch"
reporta "" "$(aws logs describe-log-groups --region "$REGIAO" \
  --query "logGroups[?contains(logGroupName,'$MARCA')].logGroupName" \
  --output text 2>/dev/null)"

titulo "roles de iam do projeto"
reporta "" "$(aws iam list-roles \
  --query "Roles[?contains(RoleName,'$MARCA')].RoleName" --output text 2>/dev/null)"

printf '\n'
if [ "$ACHOU" -eq 0 ]; then
  echo "nada sobrou. ambiente limpo."
else
  echo "tem recurso de pe. confira a lista acima antes de dar o dia por encerrado."
  echo "lembrete: o bucket do tfstate e o usuario do github actions ficam de proposito."
fi
