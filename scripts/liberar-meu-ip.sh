#!/usr/bin/env bash
# =====================================================================
# Abre os 3 load balancers públicos (OS, Execução, Billing) para o seu IP
# ---------------------------------------------------------------------
# Eles nascem fechados (127.0.0.1/32). O deploy preserva o que estiver
# liberado, então basta rodar de novo ao trocar de rede.
#
# Uso:  bash scripts/liberar-meu-ip.sh              # descobre o seu IP
#       bash scripts/liberar-meu-ip.sh 200.1.2.3    # IP(s) explícito(s)
#       bash scripts/liberar-meu-ip.sh --fechar     # tranca de novo
# =====================================================================
set -euo pipefail
# Git Bash (Windows) converte argumentos que começam com "/" em caminho do
# Windows antes de chamar o aws.exe: /oficina/hom/... vira C:/Program
# Files/Git/oficina/hom/... e o SSM responde ParameterNotFound. Sem efeito no Linux.
export MSYS_NO_PATHCONV=1

NS=oficina
SERVICOS="oficina-os-publico oficina-execucao-publico oficina-billing-publico"
AMOSTRAS="${AMOSTRAS:-4}"

meu_ip() {
  local ip
  ip=$(curl -s --max-time 8 https://checkip.amazonaws.com 2>/dev/null || true)
  ip=$(printf '%s' "$ip" | tr -d '[:space:]')
  if [ -z "$ip" ]; then
    ip=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null || true)
    ip=$(printf '%s' "$ip" | tr -d '[:space:]')
  fi
  printf '%s' "$ip"
}

if [ "${1:-}" = "--fechar" ]; then
  IPS="127.0.0.1"
  echo "==> fechando o acesso externo"
elif [ $# -gt 0 ]; then
  IPS="$*"
else
  # Mais de uma amostra: algumas redes saem por mais de um IP (balanceamento
  # de operadora), e liberar só um deixa requisições caindo ao acaso.
  echo "==> descobrindo o(s) IP(s) público(s) desta máquina"
  IPS=""
  for _ in $(seq 1 "$AMOSTRAS"); do
    ip=$(meu_ip)
    case " $IPS " in
      *" $ip "*) ;;
      *) [ -n "$ip" ] && IPS="${IPS:+$IPS }$ip" ;;
    esac
  done
fi

FAIXAS=""
for ip in $IPS; do
  if ! printf '%s' "$ip" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Ignorando valor que não é IPv4: '$ip'"
    continue
  fi
  FAIXAS="${FAIXAS:+$FAIXAS,}\"${ip}/32\""
  echo "    ${ip}/32"
done
[ -n "$FAIXAS" ] || { echo "Nenhum IPv4 válido. Informe: bash scripts/liberar-meu-ip.sh SEU.IP"; exit 1; }

for svc in $SERVICOS; do
  if kubectl -n "$NS" patch service "$svc" --type merge \
       -p "{\"spec\":{\"loadBalancerSourceRanges\":[${FAIXAS}]}}" >/dev/null 2>&1; then
    host=$(kubectl -n "$NS" get svc "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    printf '   %-26s http://%s/swagger\n' "$svc" "${host:-(sem endereço ainda)}"
  else
    printf '   %-26s (ainda não implantado)\n' "$svc"
  fi
done

echo
echo "Um LB recém-criado leva 2 a 3 minutos para responder. Terminou? --fechar"
