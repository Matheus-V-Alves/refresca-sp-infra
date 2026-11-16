#!/usr/bin/env bash
# =============================================================================
# Etapa 06 — Firewall (ufw)
#   Bloqueia toda entrada por padrão e libera só SSH (22) e HTTP (80).
#   O SSH é liberado ANTES de ativar o firewall, para não perder o acesso.
#   Obs.: no Azure, a porta 80 também precisa estar liberada no NSG da VM.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
LOG_STEP="firewall"
require_root; log_init; enable_error_trap

run_step "Política padrão: negar conexões de entrada"   ufw default deny incoming
run_step "Política padrão: permitir conexões de saída"  ufw default allow outgoing
run_step "Liberar SSH (22/tcp)"                         ufw allow 22/tcp comment 'SSH - administracao'
run_step "Liberar HTTP (80/tcp)"                        ufw allow 80/tcp comment 'Refresca API via nginx'
run_step "Ativar o firewall"                            ufw --force enable
run_step "Registrar regras ativas"                      ufw status verbose

log_ok "Firewall ativo: entrada liberada apenas em 22/tcp e 80/tcp"
log_warn "Lembrete: libere a porta 80 também no NSG do Azure para acessar a API pelo navegador"
