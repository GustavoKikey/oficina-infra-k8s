# =====================================================================
# Mensageria — credenciais do RabbitMQ (fase 4)
# ---------------------------------------------------------------------
# O RabbitMQ roda DENTRO do cluster (k8s/rabbitmq/, ADR 008 do OS
# Service); aqui só nascem as credenciais. Uma identidade por serviço:
# cada um tem o próprio usuário, e uma credencial vazada não fala pelos
# outros dois.
#
# As senhas vão para o Secrets Manager. scripts/plataforma-k8s.sh as lê
# de lá e cria os Secrets do Kubernetes que os Deployments já referenciam
# (oficina-<servico>-rabbitmq). Nenhum serviço precisa conhecer este repo.
# =====================================================================

locals {
  # Nome do serviço -> usuário no RabbitMQ.
  usuarios_rabbitmq = {
    os       = "os-service"
    execucao = "execucao-service"
    billing  = "billing-service"
  }
}

resource "random_password" "rabbitmq_admin" {
  length  = 32
  special = false # vai em URL de management e em header Basic sem escapar
}

resource "random_password" "rabbitmq_servico" {
  for_each = local.usuarios_rabbitmq
  length   = 32
  special  = false
}

resource "aws_secretsmanager_secret" "rabbitmq" {
  name        = "${var.projeto}-${var.ambiente}-rabbitmq"
  description = "Credenciais do RabbitMQ do cluster (admin e um usuario por servico)"

  # Mesmo motivo do secret do banco: o Learner Lab não deixa reaproveitar o
  # nome antes da janela de recuperação, e o ambiente é recriado com frequência.
  recovery_window_in_days = 0

  tags = local.tags
}

resource "aws_secretsmanager_secret_version" "rabbitmq" {
  secret_id = aws_secretsmanager_secret.rabbitmq.id
  secret_string = jsonencode(merge(
    {
      admin = {
        username = "admin"
        password = random_password.rabbitmq_admin.result
      }
    },
    {
      for servico, usuario in local.usuarios_rabbitmq : servico => {
        username = usuario
        password = random_password.rabbitmq_servico[servico].result
      }
    }
  ))
}

resource "aws_ssm_parameter" "rabbitmq_secret_arn" {
  name        = "${local.prefixo_ssm}/mensageria/secret-arn"
  description = "ARN do secret com as credenciais do RabbitMQ"
  type        = "String"
  value       = aws_secretsmanager_secret.rabbitmq.arn
  overwrite   = true
  tags        = local.tags
}

resource "aws_ssm_parameter" "rabbitmq_host" {
  name        = "${local.prefixo_ssm}/mensageria/host"
  description = "Endereco do RabbitMQ dentro do cluster"
  type        = "String"
  value       = "rabbitmq.oficina.svc.cluster.local"
  overwrite   = true
  tags        = local.tags
}
