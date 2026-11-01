# --------------------------------------------------------------------------
# Outputs
#
# Variaveis que so existem DEPOIS do apply: endpoint que a aws sorteia, arn
# que ela gera, url do ecr. Sem isso a alternativa e caçar valor na console
# e digitar na mao - que e lento e erra.
#
# Esses valores alimentam os ConfigMaps e Secrets do gitops/.
# --------------------------------------------------------------------------

output "cluster_nome" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "kubeconfig" {
  description = "comando pra apontar o kubectl pro cluster"
  value       = "aws eks update-kubeconfig --region ${var.regiao} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

# --------------------------------------------------------------------------
# Data stores - vao pros ConfigMaps/Secrets do gitops/
# --------------------------------------------------------------------------

output "rds_enderecos" {
  description = "endpoint de cada postgres, por servico"
  value       = { for k, v in aws_db_instance.bancos : k => v.address }
}

output "rds_bancos" {
  description = "nome do banco dentro de cada instancia"
  value       = { for k, v in aws_db_instance.bancos : k => v.db_name }
}

output "redis_endpoint" {
  description = "endpoint primario. a url usa rediss:// porque tls esta ligado"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "sqs_url" {
  value = aws_sqs_queue.eventos.url
}

output "dynamodb_tabela" {
  value = aws_dynamodb_table.analytics.name
}

# --------------------------------------------------------------------------
# ECR - o pipeline usa pra montar a tag da imagem
# --------------------------------------------------------------------------

output "ecr_urls" {
  description = "url de push de cada repositorio"
  value       = { for k, v in aws_ecr_repository.servicos : k => v.repository_url }
}

output "ecr_registry" {
  description = "o host do registry, sem o nome do repositorio"
  value       = split("/", aws_ecr_repository.servicos[var.servicos[0]].repository_url)[0]
}

# --------------------------------------------------------------------------
# IRSA - viram annotation nas service accounts do gitops/
# --------------------------------------------------------------------------

output "irsa_role_arns" {
  description = "arn da role de cada servico que fala com a aws"
  value = {
    evaluation = aws_iam_role.evaluation.arn
    analytics  = aws_iam_role.analytics.arn
  }
}

output "oidc_provider" {
  description = "emissor dos tokens das service accounts"
  value       = module.eks.oidc_provider
}

# --------------------------------------------------------------------------
# Secrets Manager
#
# So o nome. O valor nao sai aqui de proposito: output nao-sensitive vai
# pro log do terminal e pro log do CI. Pra ler a senha:
#   aws secretsmanager get-secret-value --secret-id togglemaster/rds
# --------------------------------------------------------------------------

output "secret_rds" {
  value = aws_secretsmanager_secret.rds.name
}

output "secret_master_key" {
  value = aws_secretsmanager_secret.master_key.name
}
