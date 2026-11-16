#!/usr/bin/env bash
# =============================================================================
# install-monitor.sh — instala o monitoramento como serviço systemd
#   * copia monitor.sh e a biblioteca de log para /opt/refresca
#   * gera /etc/refresca/monitor.conf com os limites de alerta
#   * prepara os arquivos de log com dono e permissões corretos
#   * roda uma verificação de teste antes de ativar o serviço
#   * instala, habilita no boot e inicia a refresca-monitor.service
#   * instala o comando de painel "refresca-status"
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
LOG_STEP="monitoramento"
require_root; log_init; enable_error_trap

UNIT="refresca-monitor.service"
MON_LOG_DIR="/var/log/refresca/monitor"

if ! id "$MONITOR_USER" &>/dev/null; then
  log_error "Usuário ${MONITOR_USER} não existe — execute antes: sudo bash setup.sh 04"
  exit 1
fi

instalar_arquivos() {
  install -d -o root -g root -m 755 "${APP_DIR}/monitor" "${APP_DIR}/lib"
  install -o root -g root -m 755 "${REPO_DIR}/monitor/monitor.sh" "${APP_DIR}/monitor/monitor.sh"
  install -o root -g root -m 644 "${REPO_DIR}/lib/logging.sh"     "${APP_DIR}/lib/logging.sh"
  install -o root -g root -m 755 "${REPO_DIR}/tools/status.sh"    /usr/local/bin/refresca-status
  ls -l "${APP_DIR}/monitor" "${APP_DIR}/lib" /usr/local/bin/refresca-status
}

gerar_conf() {
  cat > /etc/refresca/monitor.conf <<EOF
# Limites do monitoramento Refresca SP (em %)
# Gerado por monitor/install-monitor.sh em $(date '+%F %T') a partir de config/refresca.conf
MONITOR_INTERVAL=${MONITOR_INTERVAL}
CPU_WARN=${CPU_WARN}
CPU_CRIT=${CPU_CRIT}
MEM_WARN=${MEM_WARN}
MEM_CRIT=${MEM_CRIT}
DISK_WARN=${DISK_WARN}
DISK_CRIT=${DISK_CRIT}
HEALTH_URL=http://127.0.0.1${HEALTH_PATH}
API_UNIT=refresca-api.service
EOF
  chmod 644 /etc/refresca/monitor.conf
  cat /etc/refresca/monitor.conf
}

preparar_logs() {
  local f
  for f in monitor.log alerts.log errors.log; do
    touch "${MON_LOG_DIR}/${f}"
    chown "$MONITOR_USER":refresca-ops "${MON_LOG_DIR}/${f}"
    chmod 640 "${MON_LOG_DIR}/${f}"
  done
  touch /var/log/refresca/servicos-falhas.log
  chown root:refresca-ops /var/log/refresca/servicos-falhas.log
  chmod 640 /var/log/refresca/servicos-falhas.log
  ls -l "$MON_LOG_DIR" /var/log/refresca/servicos-falhas.log
}

instalar_servico() {
  install -o root -g root -m 644 "${REPO_DIR}/systemd/${UNIT}" /etc/systemd/system/
  install_failure_handler
  systemctl daemon-reload
  systemctl enable "$UNIT"
  systemctl restart "$UNIT"
  sleep 3
  systemctl is-active "$UNIT"
  systemctl --no-pager --lines=5 status "$UNIT" || true
}

run_step "Instalar scripts em ${APP_DIR}"                      instalar_arquivos
run_step "Gerar limites em /etc/refresca/monitor.conf"         gerar_conf
run_step "Preparar arquivos de log do monitoramento"           preparar_logs
run_step "Verificação de teste (monitor.sh --once como ${MONITOR_USER})" \
         sudo -u "$MONITOR_USER" "${APP_DIR}/monitor/monitor.sh" --once
run_step "Instalar, habilitar e iniciar ${UNIT}"               instalar_servico

log_ok "Monitoramento ativo a cada ${MONITOR_INTERVAL}s. Acompanhe: tail -f ${MON_LOG_DIR}/monitor.log | painel: refresca-status"
