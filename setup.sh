#!/usr/bin/env bash
# =============================================================================
# setup.sh — provisionamento completo do servidor Refresca SP
#
# Uso:
#   sudo bash setup.sh            # executa todas as etapas, em ordem
#   sudo bash setup.sh 03 app     # executa só as etapas indicadas (prefixo ou nome)
#   sudo bash setup.sh --list     # lista as etapas
#
# Cada etapa é um script independente (pode ser executado sozinho) e é
# idempotente: rodar de novo não quebra o que já está configurado.
# Logs: /var/log/refresca/provision/{provision,install,errors}.log
# =============================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_DIR
LOG_COMPONENT="provision"
# shellcheck source=lib/common.sh
source "${REPO_DIR}/lib/common.sh"
LOG_STEP="setup"

ALL_STEPS=(
  provision/01-hostname.sh
  provision/02-network.sh
  provision/03-packages.sh
  provision/04-users-dirs.sh
  provision/05-swap.sh
  provision/06-firewall.sh
  app/deploy-app.sh
  monitor/install-monitor.sh
)

usage() {
  sed -n '3,13p' "$0" | sed 's/^# \{0,1\}//'
}

SELECTED=()
if (( $# == 0 )); then
  SELECTED=("${ALL_STEPS[@]}")
else
  for arg in "$@"; do
    case "$arg" in
      -h|--help) usage; exit 0 ;;
      --list)    printf '%s\n' "${ALL_STEPS[@]}"; exit 0 ;;
    esac
    found=0
    for s in "${ALL_STEPS[@]}"; do
      if [[ "$(basename "$s")" == "${arg}"* || "$s" == *"${arg}"* ]]; then
        SELECTED+=("$s"); found=1
      fi
    done
    if (( found == 0 )); then
      echo "Etapa desconhecida: ${arg} (use --list)" >&2
      exit 1
    fi
  done
fi

require_root
log_init
enable_error_trap

RESULTS=()
print_summary() {
  log_info "================ RESUMO DO PROVISIONAMENTO ================"
  local r
  for r in "${RESULTS[@]}"; do
    if [[ "$r" == FALHA* ]]; then log_error "$r"; else log_ok "$r"; fi
  done
  log_info "Logs: ${LOG_FILE} | instalações: ${LOG_DIR}/install.log | erros: ${ERR_FILE}"
}

RUN_START=$(date +%s)
log_info "===== Provisionamento Refresca SP iniciado por ${SUDO_USER:-root} — ${#SELECTED[@]} etapa(s) ====="

for step in "${SELECTED[@]}"; do
  name="$(basename "$step" .sh)"
  t0=$(date +%s)
  log_info ">>>>> Etapa ${name}"
  if bash "${REPO_DIR}/${step}"; then
    RESULTS+=("OK    ${name} ($(( $(date +%s) - t0 ))s)")
  else
    rc=$?
    RESULTS+=("FALHA ${name} (código ${rc})")
    log_error "Etapa ${name} falhou — provisionamento interrompido. Detalhes em ${ERR_FILE}"
    print_summary
    exit "$rc"
  fi
done

print_summary
log_ok "Ambiente Refresca SP pronto em $(( $(date +%s) - RUN_START ))s. Teste: curl http://api.${DOMAIN}${HEALTH_PATH}"
if [[ -f /var/run/reboot-required ]]; then
  log_warn "O sistema pede reinicialização (kernel atualizado). Rode 'sudo reboot' e depois 'sudo bash tests/falhas.sh pos-reboot'."
fi
