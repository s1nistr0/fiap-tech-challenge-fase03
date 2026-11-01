#!/usr/bin/env bash
# Cria o bucket do estado remoto.
#
# Ovo e galinha: o backend s3 declarado no versions.tf precisa do bucket
# existindo antes do primeiro terraform init. Por isso isso aqui e shell
# e nao terraform.
set -euo pipefail

BUCKET=tfstate-togglemaster-541754963625
REGIAO=us-east-1

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "bucket $BUCKET ja existe, nada a fazer"
  exit 0
fi

# us-east-1 e a unica regiao que nao aceita LocationConstraint na criacao
aws s3api create-bucket --bucket "$BUCKET" --region "$REGIAO"

# versionamento: se o estado corromper ou um apply entrar errado,
# da pra voltar na versao anterior do objeto
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# o tfstate guarda a senha do rds em texto puro dentro dele.
# criptografia aqui nao e enfeite.
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }'

aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo "bucket $BUCKET pronto"
