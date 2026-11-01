# --------------------------------------------------------------------------
# IRSA - IAM Roles for Service Accounts
#
# A divida da fase 2. Antes: AWS_ACCESS_KEY_ID e AWS_SECRET_ACCESS_KEY
# dentro de um Secret do kubernetes - credencial de longa duracao, que nao
# expira, e que quem le o secret ganha.
#
# Agora: a service account do pod pega um token curto assinado pelo provedor
# OIDC do cluster, o STS valida esse token e devolve credencial temporaria.
# A aplicacao nao carrega segredo nenhum - o SDK resolve sozinho.
#
# So dois servicos precisam falar com a aws:
#   evaluation -> produz na fila (so manda)
#   analytics  -> consome da fila e grava no dynamo (so recebe e grava)
# Os outros tres so falam com postgres, entao nao tem role.
# --------------------------------------------------------------------------

# A condicao sub e o coracao disso. Ela amarra a role a UM namespace e UMA
# service account: pod em outro namespace do mesmo cluster nao assume.
# Sem essa condicao, qualquer pod do cluster poderia pegar a role.
data "aws_iam_policy_document" "confianca_evaluation" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:evaluation:evaluation-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "confianca_analytics" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = ["system:serviceaccount:analytics:analytics-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# --------------------------------------------------------------------------
# evaluation-service: produtor da fila
#
# Privilegio minimo de verdade: so SendMessage. Se esse pod for
# comprometido, o atacante nao consegue ler nem apagar mensagem da fila,
# nem tocar no dynamodb. E o recurso e a ARN da fila especifica, nao "*".
# --------------------------------------------------------------------------

data "aws_iam_policy_document" "evaluation" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueUrl",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.eventos.arn]
  }
}

resource "aws_iam_role" "evaluation" {
  name               = "${var.nome}-evaluation-irsa"
  assume_role_policy = data.aws_iam_policy_document.confianca_evaluation.json
}

resource "aws_iam_policy" "evaluation" {
  name   = "${var.nome}-evaluation"
  policy = data.aws_iam_policy_document.evaluation.json
}

resource "aws_iam_role_policy_attachment" "evaluation" {
  role       = aws_iam_role.evaluation.name
  policy_arn = aws_iam_policy.evaluation.arn
}

# --------------------------------------------------------------------------
# analytics-service: consumidor da fila e escritor do dynamodb
#
# Recebe e apaga da fila (apagar e parte do consumo no sqs: a mensagem so
# sai de vez com DeleteMessage depois de processada), e grava no dynamo.
# Nao tem SendMessage - nao e produtor.
# --------------------------------------------------------------------------

data "aws_iam_policy_document" "analytics" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueUrl",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.eventos.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "dynamodb:DescribeTable",
    ]
    resources = [aws_dynamodb_table.analytics.arn]
  }
}

resource "aws_iam_role" "analytics" {
  name               = "${var.nome}-analytics-irsa"
  assume_role_policy = data.aws_iam_policy_document.confianca_analytics.json
}

resource "aws_iam_policy" "analytics" {
  name   = "${var.nome}-analytics"
  policy = data.aws_iam_policy_document.analytics.json
}

resource "aws_iam_role_policy_attachment" "analytics" {
  role       = aws_iam_role.analytics.name
  policy_arn = aws_iam_policy.analytics.arn
}
