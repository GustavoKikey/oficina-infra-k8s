#!/usr/bin/env bash
# =====================================================================
# Derruba o ambiente da fase 4, na ordem inversa do aplicar.sh
# ---------------------------------------------------------------------
#   1. Lambda (lê do SSM do OS Service — precisa dele ainda de pé)
#   2. tudo dentro do cluster: os Services LoadBalancer PRIMEIRO
#   3. infra dos serviços: tabela do Billing, bancos da Execução e do OS
#   4. plataforma: RabbitMQ some com o cluster; rede e EKS
#
# O passo 2 é o que costuma travar: os load balancers que o Kubernetes
# criou (um por Service LoadBalancer) não pertencem ao Terraform. Se o
# cluster for destruído antes, eles ficam órfãos segurando interfaces de
# rede, e o destroy dos security groups falha com DependencyViolation.
#
# Ficam de propósito: o bucket e a tabela do state (bootstrap) e os
# repositórios do ECR (centavos por mês; as imagens servem à próxima sessão).
#
# Uso:  bash scripts/destruir.sh hom
# =====================================================================
set -euo pipefail

AMBIENTE="${1:-hom}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASTA="$(cd "$RAIZ/.." && pwd)"
REGIAO="${AWS_REGION:-us-east-1}"

case "$AMBIENTE" in
  hom|prod) ;;
  *) echo "Ambiente deve ser 'hom' ou 'prod'."; exit 1 ;;
esac
if [ -f "$RAIZ/scripts/.backend.env" ]; then
  # shellcheck disable=SC1091
  source "$RAIZ/scripts/.backend.env"
fi
[ -n "${TF_STATE_BUCKET:-}" ] || { echo "Backend não configurado (scripts/bootstrap.sh)."; exit 1; }
aws sts get-caller-identity >/dev/null 2>&1 || { echo "Credenciais AWS inválidas ou vencidas."; exit 1; }

destruir_terraform() {
  local dir="$1" modulo="$2"
  echo
  echo "== destroy: $modulo ($AMBIENTE)"
  (
    cd "$dir"
    terraform init -input=false -reconfigure \
      -backend-config="bucket=${TF_STATE_BUCKET}" \
      -backend-config="dynamodb_table=${TF_LOCK_TABLE}" \
      -backend-config="key=${modulo}/${AMBIENTE}/terraform.tfstate" >/dev/null
    terraform destroy -auto-approve -input=false -var="ambiente=${AMBIENTE}"
  )
}

# 1. Lambda — o pacote é montado no plan (archive_file), então a pasta basta.
if aws ssm get-parameter --name "/oficina/${AMBIENTE}/os/url-interna" >/dev/null 2>&1; then
  destruir_terraform "$PASTA/oficina-auth-lambda/infra" lambda-auth
else
  echo "== Lambda: sem URL do OS Service no SSM — nunca foi implantada aqui, pulando."
fi
aws ssm delete-parameter --name "/oficina/${AMBIENTE}/os/url-interna" >/dev/null 2>&1 || true

# 2. Cluster: load balancers primeiro.
if cluster=$(aws ssm get-parameter --name "/oficina/${AMBIENTE}/eks/cluster-name" --query Parameter.Value --output text 2>/dev/null); then
  echo
  echo "== Kubernetes ($cluster): load balancers, depois o namespace"
  aws eks update-kubeconfig --region "$REGIAO" --name "$cluster" >/dev/null
  # O finalizer do Service só o libera depois que a AWS apagou o LB.
  kubectl -n oficina delete svc --all --wait=true --timeout=10m 2>/dev/null || true
  command -v helm >/dev/null 2>&1 && helm -n newrelic uninstall newrelic-bundle >/dev/null 2>&1 || true
  kubectl delete namespace oficina newrelic --ignore-not-found --wait=true --timeout=10m || true
fi

# 3. Infra dos serviços (ainda lê a rede da plataforma no SSM).
destruir_terraform "$PASTA/oficina-billing-service/infra"  billing-service
destruir_terraform "$PASTA/oficina-execucao-service/infra" execucao-service
destruir_terraform "$PASTA/oficina-os-service/infra"       os-service

# 4. Plataforma.
destruir_terraform "$RAIZ" infra-k8s

cat <<FIM

======================================================================
  Ambiente '$AMBIENTE' destruído
======================================================================
  Continuam existindo (de propósito): bucket e tabela do state, e os
  repositórios do ECR com as imagens.
FIM
