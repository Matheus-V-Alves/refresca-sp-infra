#!/usr/bin/env bash
# =============================================================================
# Etapa 02 — Rede: IP fixo, gateway e DNS via netplan
#
# Segurança contra perda de acesso:
#   1. só aplica se o IP atual da interface for igual ao STATIC_IP configurado;
#   2. faz backup da configuração anterior;
#   3. valida a sintaxe antes de aplicar (netplan generate);
#   4. testa IP, rota, DNS e internet depois de aplicar;
#   5. se qualquer teste falhar, faz ROLLBACK automático.
#
# No Azure a interface é identificada por MAC + driver (hv_netvsc), para que a
# interface auxiliar da Accelerated Networking (enP*, mesmo MAC) não seja tocada.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
LOG_STEP="rede"
require_root; log_init; enable_error_trap

NETPLAN_DIR="/etc/netplan"
NETPLAN_FILE="${NETPLAN_DIR}/60-refresca.yaml"
CLOUD_NET_CFG="/etc/cloud/cloud.cfg.d/99-refresca-disable-network.cfg"
BACKUP_DIR="/var/backups/refresca/netplan-$(date +%Y%m%d-%H%M%S)"

if [[ ! -d "/sys/class/net/${NET_IFACE}" ]]; then
  log_error "Interface ${NET_IFACE} não existe. Interfaces disponíveis: $(ls /sys/class/net | tr '\n' ' ')"
  exit 1
fi

CURRENT_IP="$(ip -4 -o addr show dev "$NET_IFACE" | awk '{print $4}' | cut -d/ -f1 | head -n1)"
MAC="$(cat "/sys/class/net/${NET_IFACE}/address")"
DRIVER="$(basename "$(readlink -f "/sys/class/net/${NET_IFACE}/device/driver" 2>/dev/null || echo '')")"

log_info "Interface ${NET_IFACE} | MAC ${MAC} | driver ${DRIVER:-?} | IP atual ${CURRENT_IP:-nenhum} | IP desejado ${STATIC_IP}/${NET_PREFIX}"

if [[ "$CURRENT_IP" != "$STATIC_IP" && "${FORCE_NETWORK:-0}" != "1" ]]; then
  log_error "IP atual (${CURRENT_IP}) difere do STATIC_IP (${STATIC_IP}). Ajuste config/refresca.conf para não perder o acesso SSH (ou use FORCE_NETWORK=1 se tiver acesso ao console)."
  exit 1
fi

fazer_backup() {
  install -d -m 700 "$BACKUP_DIR"
  cp -a "${NETPLAN_DIR}"/*.yaml "$BACKUP_DIR"/ 2>/dev/null || true
  [[ -f "$CLOUD_NET_CFG" ]] && cp -a "$CLOUD_NET_CFG" "$BACKUP_DIR"/
  ls -l "$BACKUP_DIR"
}

desativar_rede_cloud_init() {
  if [[ ! -d /etc/cloud/cloud.cfg.d ]]; then
    echo "cloud-init não encontrado — nada a fazer"; return 0
  fi
  cat > "$CLOUD_NET_CFG" <<EOF
# Gerado por refresca-sp-infra/provision/02-network.sh em $(date '+%F %T')
# A rede passa a ser definida apenas pelo netplan do projeto (60-refresca.yaml).
network: {config: disabled}
EOF
  cat "$CLOUD_NET_CFG"
}

escrever_netplan() {
  local dns_yaml s
  dns_yaml=""
  for s in $DNS_SERVERS; do dns_yaml+="${s}, "; done
  dns_yaml="[${dns_yaml%, }]"

  # remove as configurações antigas (DHCP do cloud-init); elas estão no backup
  find "$NETPLAN_DIR" -maxdepth 1 -name '*.yaml' ! -name "$(basename "$NETPLAN_FILE")" -print -delete

  {
    cat <<EOF
# Gerado por refresca-sp-infra/provision/02-network.sh em $(date '+%F %T')
# Backup da configuração anterior: ${BACKUP_DIR}
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NET_IFACE}:
      match:
        macaddress: "${MAC}"
EOF
    if [[ -n "$DRIVER" ]]; then
      echo "        driver: ${DRIVER}"
    fi
    cat <<EOF
      set-name: ${NET_IFACE}
      dhcp4: false
      dhcp6: false
      addresses:
        - ${STATIC_IP}/${NET_PREFIX}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        search: [${DOMAIN}]
        addresses: ${dns_yaml}
EOF
  } > "$NETPLAN_FILE"
  chmod 600 "$NETPLAN_FILE"
  cat "$NETPLAN_FILE"
}

restaurar() {
  log_warn "ROLLBACK: restaurando a configuração de rede a partir de ${BACKUP_DIR}"
  rm -f "$NETPLAN_FILE" "$CLOUD_NET_CFG"
  cp -a "$BACKUP_DIR"/*.yaml "$NETPLAN_DIR"/ 2>/dev/null || true
  [[ -f "${BACKUP_DIR}/$(basename "$CLOUD_NET_CFG")" ]] && cp -a "${BACKUP_DIR}/$(basename "$CLOUD_NET_CFG")" "$CLOUD_NET_CFG"
  if netplan apply; then
    log_warn "Rollback aplicado — a rede voltou à configuração anterior"
  else
    log_error "Rollback falhou — acesse pelo Console serial do Azure e restaure ${BACKUP_DIR}"
  fi
}

validar_rede() {
  local falhas=0
  run_step "Conferir IP ${STATIC_IP} em ${NET_IFACE}" \
    bash -c "ip -4 addr show dev ${NET_IFACE} | grep -q 'inet ${STATIC_IP}/'" || falhas=1
  run_step "Conferir rota padrão via ${GATEWAY}" \
    bash -c "ip route show default | grep -q 'via ${GATEWAY}'" || falhas=1
  run_step "Resolver nome externo pelo DNS (archive.ubuntu.com)" \
    resolvectl query archive.ubuntu.com || falhas=1
  run_step "Testar saída para a internet (TCP 80)" \
    timeout 5 bash -c '</dev/tcp/archive.ubuntu.com/80' || falhas=1
  run_step "Resolver nome local (${NEW_HOSTNAME}.${DOMAIN})" \
    getent hosts "${NEW_HOSTNAME}.${DOMAIN}" || falhas=1
  return "$falhas"
}

run_step "Backup da configuração de rede atual"           fazer_backup
run_step "Desativar a configuração de rede do cloud-init" desativar_rede_cloud_init
run_step "Gerar ${NETPLAN_FILE} (IP fixo + DNS)"          escrever_netplan

if ! run_step "Validar sintaxe (netplan generate)" netplan generate; then
  restaurar; exit 1
fi
if ! run_step "Aplicar configuração (netplan apply)" netplan apply; then
  restaurar; exit 1
fi

sleep 5
if ! validar_rede; then
  log_error "Validação da rede falhou após aplicar a configuração"
  restaurar
  exit 1
fi

run_step "Registrar estado final da rede" bash -c 'ip -br a; echo; ip route; echo; resolvectl dns; resolvectl domain'
log_ok "Rede configurada: ${STATIC_IP}/${NET_PREFIX} via ${GATEWAY} | DNS ${DNS_SERVERS} | domínio ${DOMAIN}"
