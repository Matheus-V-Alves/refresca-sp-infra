#!/usr/bin/env bash
# =============================================================================
# Etapa 01 — Identidade do servidor
#   * hostname e FQDN
#   * resolução local de nomes (/etc/hosts)
#   * fuso horário (logs com horário de Brasília)
#   * impede o cloud-init do Azure de desfazer o hostname no próximo boot
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
LOG_STEP="hostname"
require_root; log_init; enable_error_trap

FQDN="${NEW_HOSTNAME}.${DOMAIN}"
CLOUD_CFG="/etc/cloud/cloud.cfg.d/99-refresca-hostname.cfg"
BACKUP_DIR="/var/backups/refresca"

configurar_cloud_init() {
  if [[ ! -d /etc/cloud/cloud.cfg.d ]]; then
    echo "cloud-init não encontrado neste sistema — nada a fazer"
    return 0
  fi
  cat > "$CLOUD_CFG" <<EOF
# Gerado por refresca-sp-infra/provision/01-hostname.sh em $(date '+%F %T')
# Impede que o cloud-init sobrescreva o hostname e o /etc/hosts a cada boot.
preserve_hostname: true
manage_etc_hosts: false
EOF
  cat "$CLOUD_CFG"
}

configurar_hosts() {
  install -d -m 700 "$BACKUP_DIR"
  cp -a /etc/hosts "${BACKUP_DIR}/hosts.$(date +%Y%m%d-%H%M%S)"
  # remove o bloco anterior (idempotência) e grava o novo
  sed -i '/# BEGIN REFRESCA-SP/,/# END REFRESCA-SP/d' /etc/hosts
  {
    echo "# BEGIN REFRESCA-SP (gerenciado por provision/01-hostname.sh — não editar)"
    printf '%-15s %s %s %s\n' "$STATIC_IP" "$FQDN" "$NEW_HOSTNAME" "$EXTRA_HOST_ALIASES"
    echo "# END REFRESCA-SP"
  } >> /etc/hosts
  cat /etc/hosts
}

log_info "Hostname atual: $(hostname) | novo: ${NEW_HOSTNAME} (FQDN ${FQDN})"

run_step "Configurar cloud-init para preservar hostname"        configurar_cloud_init
run_step "Registrar ${FQDN} e aliases no /etc/hosts"            configurar_hosts
run_step "Aplicar hostname ${NEW_HOSTNAME}"                     hostnamectl set-hostname "$NEW_HOSTNAME"
run_step "Definir fuso horário ${TIMEZONE}"                     timedatectl set-timezone "$TIMEZONE"
run_step "Validar resolução local de ${FQDN}"                   getent hosts "$FQDN"

log_ok "Identidade: hostname=$(hostnamectl --static) | fqdn=$(hostname -f 2>/dev/null || echo '?') | tz=$(timedatectl show -p Timezone --value)"
