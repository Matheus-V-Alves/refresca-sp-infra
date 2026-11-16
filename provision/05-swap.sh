#!/usr/bin/env bash
# =============================================================================
# Etapa 05 — Memória de troca (swap)
#   A VM do Azure vem sem swap. Sem ele, um pico de memória faz o kernel matar
#   processos (OOM killer), podendo derrubar a API ou o SSH. O swap dá margem
#   para o teste de estresse de memória acontecer sem derrubar o servidor.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
LOG_STEP="swap"
require_root; log_init; enable_error_trap

SWAPFILE="/swapfile"

criar_swap() {
  local ativos
  ativos="$(swapon --show=NAME --noheadings)"
  if grep -qx "$SWAPFILE" <<< "$ativos"; then
    echo "Swap ${SWAPFILE} já está ativo"
  else
    [[ -f "$SWAPFILE" ]] || fallocate -l "$SWAP_SIZE" "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE"
    swapon "$SWAPFILE"
  fi
  swapon --show
}

persistir_swap() {
  if ! grep -q "^${SWAPFILE} " /etc/fstab; then
    echo "${SWAPFILE} none swap sw 0 0" >> /etc/fstab
  fi
  grep swap /etc/fstab
}

ajustar_swappiness() {
  echo "vm.swappiness=10" > /etc/sysctl.d/99-refresca.conf
  sysctl -p /etc/sysctl.d/99-refresca.conf
}

run_step "Criar e ativar swap de ${SWAP_SIZE} em ${SWAPFILE}" criar_swap
run_step "Persistir swap no /etc/fstab (sobrevive ao reboot)" persistir_swap
run_step "Ajustar vm.swappiness=10 (usa swap só sob pressão)" ajustar_swappiness

log_ok "Memória: $(free -h | awk '/^Mem:/{print "RAM " $2} /^Swap:/{print "| Swap " $2}' | tr '\n' ' ')"
