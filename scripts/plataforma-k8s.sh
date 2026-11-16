#!/usr/bin/env bash
# =====================================================================
# Plataforma dentro do cluster (fase 4)
# ---------------------------------------------------------------------
# Depois do terraform apply deste repositório:
#   1. namespace "oficina";
#   2. Secrets do RabbitMQ, lidos do Secrets Manager (mensageria.tf) —
#      oficina-rabbitmq-admin e um oficina-<servico>-rabbitmq por serviço,
#      os nomes que os Deployments dos serviços já referenciam;
#   3. o RabbitMQ (k8s/rabbitmq/) e o Job que cria os usuários.
#
# Idempotente: pode rodar quantas vezes quiser.
#
# Uso:  bash scripts/plataforma-k8s.sh hom
# =====================================================================
set -euo pipefail

AMBIENTE="${1:-hom}"
REGIAO="${AWS_REGION:-us-east-1}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$(command -v python3 || command -v python)"
NS=oficina

case "$AMBIENTE" in
  hom|prod) ;;
  *) echo "Ambiente deve ser 'hom' ou 'prod'."; exit 1 ;;
esac

ssm() { aws ssm get-parameter --name "/oficina/${AMBIENTE}/$1" --query Parameter.Value --output text; }

echo "== Cluster"
cluster=$(ssm eks/cluster-name)
aws eks update-kubeconfig --region "$REGIAO" --name "$cluster" >/dev/null
kubectl get nodes

echo "== Namespace e Secrets do RabbitMQ"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
json=$(aws secretsmanager get-secret-value --secret-id "$(ssm mensageria/secret-arn)" \
  --query SecretString --output text)

campo() {
  printf '%s' "$json" | "$PY" -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]][sys.argv[2]], end="")' "$1" "$2"
}

secret_rabbitmq() {
  local nome="$1" chave="$2" dir
  dir=$(mktemp -d)
  # Arquivos em vez de --from-literal: a senha não aparece na lista de processos.
  campo "$chave" username >"$dir/username"
  campo "$chave" password >"$dir/password"
  kubectl -n "$NS" create secret generic "$nome" \
    --from-file=username="$dir/username" --from-file=password="$dir/password" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  rm -rf "$dir"
  echo "   $nome"
}

secret_rabbitmq oficina-rabbitmq-admin    admin
secret_rabbitmq oficina-os-rabbitmq       os
secret_rabbitmq oficina-execucao-rabbitmq execucao
secret_rabbitmq oficina-billing-rabbitmq  billing

echo "== RabbitMQ"
kubectl apply -f "$RAIZ/k8s/rabbitmq/10-configmap.yaml" \
              -f "$RAIZ/k8s/rabbitmq/20-statefulset.yaml" \
              -f "$RAIZ/k8s/rabbitmq/30-service.yaml"
kubectl -n "$NS" rollout status statefulset/rabbitmq --timeout=300s

echo "== Usuários dos serviços"
# Job é imutável: para rodar de novo, apaga o anterior.
kubectl -n "$NS" delete job rabbitmq-usuarios --ignore-not-found >/dev/null
kubectl apply -f "$RAIZ/k8s/rabbitmq/40-job-usuarios.yaml"
if ! kubectl -n "$NS" wait --for=condition=complete job/rabbitmq-usuarios --timeout=180s; then
  kubectl -n "$NS" logs job/rabbitmq-usuarios --tail=50 || true
  exit 1
fi
kubectl -n "$NS" logs job/rabbitmq-usuarios --tail=5

echo
echo "Plataforma pronta em '$AMBIENTE'. Painel do RabbitMQ:"
echo "   kubectl -n $NS port-forward svc/rabbitmq 15672:15672   # http://localhost:15672"
