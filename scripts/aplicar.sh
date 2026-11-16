#!/usr/bin/env bash
# =====================================================================
# Sobe o ambiente inteiro da fase 4, na ordem do contrato no SSM
# ---------------------------------------------------------------------
#   1. plataforma (este repo) ..... rede, EKS, RabbitMQ no cluster
#   2. infra de cada serviço ....... banco do OS, banco da Execução,
#                                    tabela do Billing
#   3. deploy dos serviços ......... workflow CD de cada repo no GitHub
#                                    (OS primeiro: a Lambda precisa dele)
#   4. Lambda de autenticação ...... workflow CI/CD do oficina-auth-lambda
#
# Os passos 3 e 4 rodam no GitHub Actions — é o deploy automatizado que o
# enunciado pede — e por isso exigem os secrets renovados nesta sessão
# (scripts/renovar-secrets.sh). Com --sem-deploy, para no passo 2.
#
# Pré-requisitos: os repositórios clonados lado a lado na mesma pasta,
# credenciais do lab no ~/.aws, terraform, kubectl, gh e o backend do
# state (scripts/bootstrap.sh, uma vez por conta).
#
# Uso:  bash scripts/aplicar.sh hom
#       bash scripts/aplicar.sh hom --sem-deploy
# =====================================================================
set -euo pipefail

AMBIENTE="${1:-hom}"
DEPLOY=true
[ "${2:-}" = "--sem-deploy" ] && DEPLOY=false
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASTA="$(cd "$RAIZ/.." && pwd)"
PY="$(command -v python3 || command -v python)"

case "$AMBIENTE" in
  hom|prod) ;;
  *) echo "Ambiente deve ser 'hom' ou 'prod'."; exit 1 ;;
esac

# ---------------------------------------------------------------- checagens
for ferramenta in aws terraform kubectl; do
  command -v "$ferramenta" >/dev/null 2>&1 || { echo "Falta '$ferramenta' no PATH."; exit 1; }
done
if $DEPLOY; then
  command -v gh >/dev/null 2>&1 || { echo "Falta 'gh' (ou use --sem-deploy)."; exit 1; }
fi
for repo in oficina-os-service oficina-execucao-service oficina-billing-service oficina-auth-lambda; do
  [ -d "$PASTA/$repo" ] || { echo "Clone $repo ao lado deste repositório ($PASTA)."; exit 1; }
done
if [ -f "$RAIZ/scripts/.backend.env" ]; then
  # shellcheck disable=SC1091
  source "$RAIZ/scripts/.backend.env"
fi
if [ -z "${TF_STATE_BUCKET:-}" ] || [ -z "${TF_LOCK_TABLE:-}" ]; then
  echo "Backend do Terraform não configurado. Rode antes:  bash scripts/bootstrap.sh SEU-SUFIXO"
  exit 1
fi
aws sts get-caller-identity >/dev/null 2>&1 || { echo "Credenciais AWS inválidas ou vencidas (~/.aws/credentials)."; exit 1; }

# Dono dos repositórios no GitHub, a partir do remote deste clone.
DONO=$(git -C "$RAIZ" remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#/.*##')

# ---------------------------------------------------------------- funções
# A chave do state carrega o módulo e o ambiente (ADR 005 da fase 3).
aplicar_terraform() {
  local dir="$1" modulo="$2"
  echo
  echo "======================================================================"
  echo "  $modulo  ->  $AMBIENTE"
  echo "======================================================================"
  (
    cd "$dir"
    terraform init -input=false -reconfigure \
      -backend-config="bucket=${TF_STATE_BUCKET}" \
      -backend-config="dynamodb_table=${TF_LOCK_TABLE}" \
      -backend-config="key=${modulo}/${AMBIENTE}/terraform.tfstate" >/dev/null
    terraform apply -auto-approve -input=false -var="ambiente=${AMBIENTE}"
  )
}

# Dispara um workflow e devolve o id da execução criada por ESTE disparo
# (não a anterior: filtra pela hora).
disparar() {
  local repo="$1" workflow="$2" inicio id=""
  inicio=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  gh workflow run "$workflow" --repo "$DONO/$repo" -f ambiente="$AMBIENTE" >/dev/null
  for _ in $(seq 1 30); do
    id=$(gh run list --repo "$DONO/$repo" --workflow "$workflow" --event workflow_dispatch --limit 5 \
           --json databaseId,createdAt \
         | "$PY" -c 'import json,sys; r=[x for x in json.load(sys.stdin) if x["createdAt"]>=sys.argv[1]]; print(r[-1]["databaseId"] if r else "")' "$inicio")
    [ -n "$id" ] && break
    sleep 3
  done
  [ -n "$id" ] || { echo "Não achei a execução de $workflow em $repo." >&2; return 1; }
  echo "$id"
}

esperar() {
  local repo="$1" id="$2"
  if gh run watch "$id" --repo "$DONO/$repo" --exit-status >/dev/null 2>&1; then
    echo "   ✓ $repo"
  else
    echo "   ✗ $repo — veja: gh run view $id --repo $DONO/$repo --log-failed" >&2
    return 1
  fi
}

# ---------------------------------------------------------------- 1 e 2
aplicar_terraform "$RAIZ" infra-k8s
bash "$RAIZ/scripts/plataforma-k8s.sh" "$AMBIENTE"
aplicar_terraform "$PASTA/oficina-os-service/infra"       os-service
aplicar_terraform "$PASTA/oficina-execucao-service/infra" execucao-service
aplicar_terraform "$PASTA/oficina-billing-service/infra"  billing-service

if ! $DEPLOY; then
  echo
  echo "Infraestrutura de '$AMBIENTE' no ar (sem deploy). Para implantar: Run workflow no CD de cada serviço."
  exit 0
fi

# ---------------------------------------------------------------- 3 e 4
echo
echo "======================================================================"
echo "  Deploy pelos workflows do GitHub (secrets renovados nesta sessão?)"
echo "======================================================================"
id_os=$(disparar oficina-os-service cd.yml)
echo "   OS Service ............. execução $id_os"
esperar oficina-os-service "$id_os"

id_ex=$(disparar oficina-execucao-service cd.yml)
id_bi=$(disparar oficina-billing-service cd.yml)
echo "   Execução e Billing ..... execuções $id_ex e $id_bi"
esperar oficina-execucao-service "$id_ex"
esperar oficina-billing-service "$id_bi"

id_la=$(disparar oficina-auth-lambda ci-cd.yml)
echo "   Lambda ................. execução $id_la"
esperar oficina-auth-lambda "$id_la"

# ---------------------------------------------------------------- endereços
endereco() { kubectl -n oficina get svc "$1" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true; }
gateway=$(aws ssm get-parameter --name "/oficina/${AMBIENTE}/apigw/invoke-url" --query Parameter.Value --output text 2>/dev/null || echo "?")
cat <<FIM

======================================================================
  Ambiente '$AMBIENTE' no ar
======================================================================
  OS Service ...... http://$(endereco oficina-os-publico)/swagger
  Execução ........ http://$(endereco oficina-execucao-publico)/swagger
  Billing ......... http://$(endereco oficina-billing-publico)/swagger
  Login do cliente  ${gateway}/auth/cliente

  Os load balancers nascem FECHADOS. Para abrir para o seu IP:
     bash scripts/liberar-meu-ip.sh
  New Relic (agente no cluster):
     bash scripts/observabilidade.sh $AMBIENTE

  QUANDO TERMINAR:  bash scripts/destruir.sh $AMBIENTE
FIM
