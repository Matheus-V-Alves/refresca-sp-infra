#!/usr/bin/env bash
# =============================================================================
# registrar-falha.sh — chamado pela refresca-failure@.service (OnFailure=)
# Registra que uma unidade do projeto entrou em estado "failed", junto com as
# últimas linhas do journal dela, em /var/log/refresca/servicos-falhas.log
# =============================================================================
set -uo pipefail
UNIT="${1:-desconhecida}"
LOG="/var/log/refresca/servicos-falhas.log"
{
  printf '%s | %s | registrar-falha.sh | ERROR | %s | Unidade entrou em estado FAILED (resultado=%s, reinícios=%s)\n' \
    "$(date '+%Y-%m-%d %H:%M:%S %z')" "$(hostname -s)" "$UNIT" \
    "$(systemctl show -p Result --value "$UNIT")" "$(systemctl show -p NRestarts --value "$UNIT")"
  journalctl -u "$UNIT" -n 15 --no-pager -o short-iso 2>/dev/null | sed 's/^/        | /'
} >> "$LOG"
logger -t refresca-falha -p user.err "Unidade ${UNIT} entrou em estado failed"
