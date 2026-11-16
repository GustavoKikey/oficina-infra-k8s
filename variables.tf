variable "ambiente" {
  description = "Ambiente lógico. Prefixa todos os parâmetros no SSM (/oficina/{ambiente}/...)."
  type        = string

  validation {
    condition     = contains(["hom", "prod"], var.ambiente)
    error_message = "Ambiente deve ser 'hom' ou 'prod' — são os dois que a pipeline provisiona."
  }
}

variable "regiao" {
  description = "Região AWS. O AWS Academy Learner Lab só libera us-east-1."
  type        = string
  default     = "us-east-1"
}

variable "projeto" {
  description = "Nome do projeto, usado em nomes de recurso e tags."
  type        = string
  default     = "oficina"
}

variable "versao_kubernetes" {
  description = <<-EOT
    Versão do control plane do EKS. Conferir antes de subir um ambiente:
      aws eks describe-cluster-versions
    Versão fora do suporte padrão (EXTENDED_SUPPORT) custa ~6x mais por hora
    de control plane, e some do catálogo quando o suporte estendido acaba.
    A 1.31 da fase 3 estava nessa situação em 2026-11; a 1.37 é a padrão da
    AWS, com suporte padrão até 2027-11.
  EOT
  type        = string
  default     = "1.37"
}

variable "tipo_instancia_no" {
  description = <<-EOT
    Tipo das instâncias do node group. O Learner Lab restringe a tipos
    pequenos; t3.medium comporta as 5 réplicas do HPA com folga.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "nos_desejados" {
  description = <<-EOT
    Quantidade de nós no node group. Na fase 4 são 3: três serviços Java
    (512 MiB cada, com réplica extra no rollout), o RabbitMQ e o agente do
    New Relic não cabem com folga em dois t3.medium.
  EOT
  type        = number
  default     = 3
}

variable "role_arn_cluster" {
  description = <<-EOT
    ARN da IAM role usada pelo cluster e pelos nós.

    No Learner Lab NÃO é possível criar IAM roles — só reusar a LabRole
    existente. Deixe vazio para o Terraform descobrir a LabRole
    automaticamente; informe um ARN para usar uma role própria numa conta
    AWS comum.

    Ver RFC 001, §5 (restrições do Learner Lab).
  EOT
  type        = string
  default     = ""
}

variable "role_arn_nos" {
  description = <<-EOT
    ARN da IAM role dos NÓS do cluster. Separada da role do control plane
    porque os nós precisam da AmazonEKS_CNI_Policy — sem ela o VPC CNI não
    atribui IP aos pods e o node group sobe NotReady.

    Vazio faz o Terraform procurar a role dedicada do Learner Lab
    (*LabEksNodeRole*) e, se não achar, cair na role do cluster.
  EOT
  type        = string
  default     = ""
}

variable "azs_sem_eks" {
  description = <<-EOT
    Availability zones que não aceitam control plane de EKS e precisam ser
    excluídas das subnets do cluster.

    Em us-east-1 é a us-east-1e — a AWS recusa com
    UnsupportedAvailabilityZoneException. A lista é explícita porque não há
    API que a exponha; se mudar, o erro do apply diz quais AZs são válidas.
  EOT
  type        = list(string)
  default     = ["us-east-1e"]
}
