#!/usr/bin/env bash
# =====================================================================
# Agente do New Relic no cluster (nri-bundle) — o mesmo da fase 3
# ---------------------------------------------------------------------
# Os serviços exportam traces sozinhos (OTLP, com a license key do Secret
# oficina-newrelic). O agente cobre o resto:
#
#   - CPU, memória e estado dos pods, eventos do Kubernetes, logs;
#   - as métricas de negócio em /q/metrics de cada serviço (oficina_os_*,
#     oficina_saga_*, ...) e as do RabbitMQ (filas, DLQ) na porta 15692.
#
# integrations_filter desligado: com ele ligado, o agente só raspa
# integrações conhecidas e ignora as aplicações, mesmo anotadas.
#
# Uso:
#   export NEW_RELIC_LICENSE_KEY=...   # chave de INGESTÃO (sufixo NRAL)
#   bash scripts/observabilidade.sh hom
# =====================================================================
set -euo pipefail
# Git Bash (Windows) converte argumentos que começam com "/" em caminho do
# Windows antes de chamar o aws.exe: /oficina/hom/... vira C:/Program
# Files/Git/oficina/hom/... e o SSM responde ParameterNotFound. Sem efeito no Linux.
export MSYS_NO_PATHCONV=1

AMBIENTE="${1:-hom}"
REGIAO="${AWS_REGION:-us-east-1}"
HELM="${HELM:-helm}"

case "$AMBIENTE" in
  hom|prod) ;;
  *) echo "Ambiente deve ser 'hom' ou 'prod'."; exit 1 ;;
esac
[ -n "${NEW_RELIC_LICENSE_KEY:-}" ] || {
  echo "Exporte a license key antes:  export NEW_RELIC_LICENSE_KEY=sua-chave-NRAL"
  echo "É a chave de INGESTÃO (termina em NRAL), não a de API (NRAK)."
  exit 1
}
command -v "$HELM" >/dev/null 2>&1 || { echo "helm não encontrado (HELM=/caminho/helm.exe)."; exit 1; }

CLUSTER=$(aws ssm get-parameter --name "/oficina/${AMBIENTE}/eks/cluster-name" --query Parameter.Value --output text)
aws eks update-kubeconfig --region "$REGIAO" --name "$CLUSTER" >/dev/null
echo "==> cluster: $CLUSTER"

"$HELM" repo add newrelic https://helm-charts.newrelic.com >/dev/null 2>&1 || true
"$HELM" repo update newrelic >/dev/null

echo "==> nri-bundle (alguns minutos)"
"$HELM" upgrade --install newrelic-bundle newrelic/nri-bundle \
  --namespace newrelic --create-namespace \
  --set global.licenseKey="$NEW_RELIC_LICENSE_KEY" \
  --set global.cluster="$CLUSTER" \
  --set global.lowDataMode=true \
  --set kube-state-metrics.enabled=true \
  --set newrelic-prometheus-agent.enabled=true \
  --set newrelic-prometheus-agent.config.kubernetes.integrations_filter.enabled=false \
  --set kubeEvents.enabled=true \
  --set newrelic-logging.enabled=true \
  --set nri-metadata-injection.enabled=true \
  --wait --timeout 10m

kubectl -n newrelic get pods
cat <<FIM

======================================================================
  Agente instalado — cluster $CLUSTER
======================================================================
  A coleta aparece em 1 a 3 minutos. Para conferir no New Relic:

    SELECT count(*) FROM K8sPodSample WHERE clusterName = '$CLUSTER' SINCE 10 minutes ago
    SELECT count(*) FROM Span WHERE service.name LIKE 'oficina-%' FACET service.name SINCE 10 minutes ago

  Painel e alertas da saga: scripts/newrelic-saga.py
FIM
