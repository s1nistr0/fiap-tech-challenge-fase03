# --------------------------------------------------------------------------
# Credenciais
#
# A dor do enunciado era "credenciais do banco em arquivos de texto sem
# seguranca". Aqui a senha e gerada pelo terraform e guardada no secrets
# manager: ninguem digita, ninguem commita, ninguem precisa saber qual e.
# --------------------------------------------------------------------------

resource "random_password" "rds" {
  length = 32
  # sem caractere especial de proposito. a senha entra dentro de uma URL de
  # conexao (postgres://user:senha@host) e um # ou / ali corta a string no
  # parser do driver. 32 caracteres alfanumericos ja dao entropia de sobra.
  special = false
}

resource "random_password" "master_key" {
  length  = 40
  special = false
}

resource "aws_secretsmanager_secret" "rds" {
  name = "${var.nome}/rds"
  # 0 = apaga na hora no destroy. o default e 30 dias de "recuperacao", e
  # nesse periodo o nome fica reservado - recriar o ambiente hoje a noite
  # falharia com "secret ja existe".
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "rds" {
  secret_id = aws_secretsmanager_secret.rds.id
  secret_string = jsonencode({
    username = "toggle"
    password = random_password.rds.result
    hosts    = { for k, v in aws_db_instance.bancos : k => v.address }
  })
}

resource "aws_secretsmanager_secret" "master_key" {
  name                    = "${var.nome}/auth-master-key"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "master_key" {
  secret_id     = aws_secretsmanager_secret.master_key.id
  secret_string = random_password.master_key.result
}

# --------------------------------------------------------------------------
# RDS PostgreSQL - 3 instancias (auth, flags, targeting)
#
# Um bloco so gera as tres, via for_each no var.bancos. Adicionar um quarto
# banco e adicionar uma linha no map, nao copiar 25 linhas de hcl.
# --------------------------------------------------------------------------

resource "aws_db_instance" "bancos" {
  for_each = var.bancos

  identifier = "${var.nome}-${each.key}"
  db_name    = each.value

  engine = "postgres"
  # so a major. a aws resolve a minor mais recente disponivel e o
  # auto_minor_version_upgrade mantem atualizado.
  engine_version = "16"

  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  username = "toggle"
  password = random_password.rds.result

  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  # subnet privada e sem ip publico. quem alcanca sao os nos do eks, e so
  # eles, pela regra do security group no vpc.tf.
  publicly_accessible = false
  multi_az            = false

  auto_minor_version_upgrade = true
  apply_immediately          = true

  # ATENCAO - as tres linhas abaixo estao ERRADAS para producao.
  # existem para o destroy de hoje a noite rodar limpo e nao deixar
  # snapshot cobrando. em producao: retention >= 7, snapshot final sim,
  # deletion protection ligada.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
}

# --------------------------------------------------------------------------
# ElastiCache Redis - cache do evaluation-service (o caminho quente)
# --------------------------------------------------------------------------

resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.nome}-redis"
  description          = "cache de avaliacao de flags"

  engine               = "redis"
  engine_version       = "7.1"
  node_type            = "cache.t3.micro"
  num_cache_clusters   = 1
  parameter_group_name = "default.redis7"
  port                 = 6379

  subnet_group_name  = aws_elasticache_subnet_group.redis.name
  security_group_ids = [aws_security_group.redis.id]

  # criptografia em transito liga o TLS na porta. com isso a URL vira
  # rediss:// (dois s) e o go-redis ativa o tls sozinho ao ver o esquema.
  # o gerar-secrets.sh detecta isso consultando a api, nao chumbado.
  transit_encryption_enabled = true
  at_rest_encryption_enabled = true

  # no replica, logo nao tem pra onde failover. decisao de custo, igual
  # ao nat gateway unico.
  automatic_failover_enabled = false

  snapshot_retention_limit = 0
  apply_immediately        = true
}

# --------------------------------------------------------------------------
# DynamoDB - eventos de avaliacao (volume)
# --------------------------------------------------------------------------

resource "aws_dynamodb_table" "analytics" {
  name = "ToggleMasterAnalytics"
  # pay per request em vez de capacidade provisionada: sem carga constante
  # nao faz sentido pagar RCU/WCU reservada parada.
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "event_id"

  attribute {
    name = "event_id"
    type = "S"
  }

  server_side_encryption {
    enabled = true
  }
}

# --------------------------------------------------------------------------
# SQS - fila entre evaluation (produtor) e analytics (consumidor)
# --------------------------------------------------------------------------

resource "aws_sqs_queue" "eventos" {
  name = "${var.nome}-events"

  # 30s pra processar antes da mensagem voltar a ficar visivel pra outro
  # consumidor. o analytics grava no dynamo em ms, folga grande.
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400

  sqs_managed_sse_enabled = true
}

# --------------------------------------------------------------------------
# ECR - um repositorio por servico
# --------------------------------------------------------------------------

resource "aws_ecr_repository" "servicos" {
  for_each = toset(var.servicos)

  name                 = "${var.nome}/${each.key}"
  image_tag_mutability = "MUTABLE"

  # sem isso o destroy falha se tiver imagem dentro - e vai ter, o
  # pipeline empurra imagem a cada push na main.
  force_delete = true

  image_scanning_configuration {
    # scan tambem no registro, nao so no pipeline. defesa em profundidade:
    # cve novo em imagem ja empurrada aparece aqui.
    scan_on_push = true
  }
}
