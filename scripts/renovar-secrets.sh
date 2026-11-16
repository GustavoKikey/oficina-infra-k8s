#!/usr/bin/env bash
# =====================================================================
# Renova os secrets dos 5 repositórios da fase 4 no GitHub
# ---------------------------------------------------------------------
# A sessão do Learner Lab dura 4h e as credenciais mudam a cada Start Lab.
# Os workflows (CD dos serviços, Terraform, Lambda) dependem delas.
#
# Sempre:    AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN
#            (lidos do ~/.aws/credentials)
# Se houver: TF_STATE_BUCKET, TF_LOCK_TABLE (scripts/.backend.env, do bootstrap)
# Opcionais, se exportados antes de rodar:
#            NEW_RELIC_LICENSE_KEY -> os três serviços (traces no New Relic)
#            MP_ACCESS_TOKEN       -> só o Billing (Mercado Pago de verdade)
#
# Quem roda é você: são credenciais reais, e o valor nunca passa por
# arquivo versionado nem pela linha de comando de outra pessoa.
#
# Uso:
#   1. No lab: AWS Details -> AWS CLI -> Show; cole em ~/.aws/credentials
#   2. bash scripts/renovar-secrets.sh SEU-USUARIO-GITHUB
# =====================================================================
set -euo pipefail
# Git Bash (Windows) converte argumentos que começam com "/" em caminho do
# Windows antes de chamar o aws.exe: /oficina/hom/... vira C:/Program
# Files/Git/oficina/hom/... e o SSM responde ParameterNotFound. Só os nomes
# do SSM ficam de fora da conversão — caminhos de arquivo (/c/Users/...)
# continuam sendo convertidos. Sem efeito no Linux.
export MSYS2_ARG_CONV_EXCL="/oficina"

USUARIO="${1:-}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -z "$USUARIO" ]; then
  echo "Uso: bash scripts/renovar-secrets.sh SEU-USUARIO-GITHUB"
  exit 1
fi
command -v gh >/dev/null 2>&1 || { echo "gh não instalado:  winget install --id GitHub.cli -e"; exit 1; }

# Lido direto do ~/.aws/credentials: copiar valor por valor é onde o erro acontece.
ler() { awk -F' *= *' "/^${1}/ {print \$2; exit}" ~/.aws/credentials | tr -d '\r'; }
CHAVE=$(ler aws_access_key_id)
SEGREDO=$(ler aws_secret_access_key)
TOKEN=$(ler aws_session_token)
[ -n "$CHAVE" ] || { echo "Não achei aws_access_key_id em ~/.aws/credentials."; exit 1; }

# Valida ANTES de distribuir: credencial vencida em 5 repos só adia a
# descoberta para o meio de um deploy.
echo "Validando as credenciais..."
aws sts get-caller-identity >/dev/null 2>&1 || { echo "Credenciais inválidas ou expiradas. Recopie do lab."; exit 1; }
echo "OK."

if [ -f "$RAIZ/scripts/.backend.env" ]; then
  # shellcheck disable=SC1091
  source "$RAIZ/scripts/.backend.env"
fi

definir() { # repo nome valor
  printf '%s' "$3" | gh secret set "$2" --repo "$USUARIO/$1" >/dev/null
}

SERVICOS="oficina-os-service oficina-execucao-service oficina-billing-service"
for repo in oficina-infra-k8s oficina-auth-lambda $SERVICOS; do
  echo "==> $USUARIO/$repo"
  if ! definir "$repo" AWS_ACCESS_KEY_ID "$CHAVE" 2>/dev/null; then
    echo "    (sem acesso ao repositório — pulando)"
    continue
  fi
  definir "$repo" AWS_SECRET_ACCESS_KEY "$SEGREDO"
  [ -n "$TOKEN" ] && definir "$repo" AWS_SESSION_TOKEN "$TOKEN"
  if [ -n "${TF_STATE_BUCKET:-}" ]; then
    definir "$repo" TF_STATE_BUCKET "$TF_STATE_BUCKET"
    definir "$repo" TF_LOCK_TABLE "$TF_LOCK_TABLE"
  fi
  case " $SERVICOS " in
    *" $repo "*)
      [ -n "${NEW_RELIC_LICENSE_KEY:-}" ] && definir "$repo" NEW_RELIC_LICENSE_KEY "$NEW_RELIC_LICENSE_KEY" && echo "    + NEW_RELIC_LICENSE_KEY"
      ;;
  esac
  if [ "$repo" = oficina-billing-service ] && [ -n "${MP_ACCESS_TOKEN:-}" ]; then
    definir "$repo" MP_ACCESS_TOKEN "$MP_ACCESS_TOKEN" && echo "    + MP_ACCESS_TOKEN"
  fi
  echo "    secrets atualizados"
done

echo
echo "Pronto. Os workflows funcionam até a sessão do lab expirar (~4h)."
