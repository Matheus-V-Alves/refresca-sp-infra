#!/usr/bin/env bash
# =============================================================================
# Etapa 04 — Usuários, grupos, diretórios e permissões
#
# Princípio do menor privilégio:
#   refresca      usuário de serviço da API (sem shell, sem login)
#   refresca-mon  usuário de serviço do monitoramento (sem shell, sem login)
#   refresca-ops  grupo de operadores: lê os logs e reinicia os serviços do
#                 projeto via sudo, sem ter root completo
#
# Estrutura criada:
#   /opt/refresca          código (root, somente leitura para os serviços)
#   /var/lib/refresca      dados da API (banco SQLite) — só o usuário refresca
#   /etc/refresca          configuração e variáveis de ambiente
#   /var/log/refresca      logs por componente (provision, monitor, app, tests)
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
LOG_STEP="usuarios"
require_root; log_init; enable_error_trap

OPS_GROUP="refresca-ops"
ADMIN="${ADMIN_USER:-${SUDO_USER:-azureuser}}"

criar_usuario_servico() {
  local user="$1" desc="$2"
  if id "$user" &>/dev/null; then
    echo "Usuário ${user} já existe"
  else
    useradd --system --user-group --no-create-home --home-dir "$APP_DIR" \
            --shell /usr/sbin/nologin --comment "$desc" "$user"
  fi
  id "$user"
  getent passwd "$user"
}

# dir_perm DONO GRUPO MODO CAMINHO
dir_perm() {
  mkdir -p "$4"
  chown "$1:$2" "$4"
  chmod "$3" "$4"
}

criar_diretorios() {
  dir_perm root           root           755  "$APP_DIR"
  dir_perm root           root           755  "${APP_DIR}/bin"
  dir_perm root           root           755  "${APP_DIR}/lib"
  dir_perm root           root           755  "${APP_DIR}/monitor"
  dir_perm root           "$APP_USER"    750  "${APP_DIR}/api"
  dir_perm "$APP_USER"    "$APP_USER"    750  "$DATA_DIR"
  dir_perm root           root           755  /etc/refresca
  dir_perm root           "$OPS_GROUP"   755  /var/log/refresca
  dir_perm root           "$OPS_GROUP"   2750 /var/log/refresca/provision
  dir_perm "$MONITOR_USER" "$OPS_GROUP"  2750 /var/log/refresca/monitor
  dir_perm "$APP_USER"    "$OPS_GROUP"   2750 /var/log/refresca/app
  dir_perm root           "$OPS_GROUP"   2750 /var/log/refresca/tests
  dir_perm root           root           700  /var/backups/refresca

  # arquivos de log já existentes da etapa de provisionamento ficam legíveis pelo grupo
  chgrp -R "$OPS_GROUP" /var/log/refresca/provision
  find /var/log/refresca/provision -type f -exec chmod 640 {} +

  ls -ld "$APP_DIR" "$APP_DIR"/* "$DATA_DIR" /etc/refresca /var/log/refresca /var/log/refresca/*
}

configurar_sudoers() {
  local destino="/etc/sudoers.d/refresca-ops" tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Gerado por refresca-sp-infra/provision/04-users-dirs.sh
# Operadores administram apenas os serviços do projeto, sem root completo.
Cmnd_Alias REFRESCA_SVC = /usr/bin/systemctl start refresca-*, \\
                          /usr/bin/systemctl stop refresca-*, \\
                          /usr/bin/systemctl restart refresca-*, \\
                          /usr/bin/systemctl status refresca-*
%${OPS_GROUP} ALL=(root) NOPASSWD: REFRESCA_SVC
EOF
  visudo -cf "$tmp"                   # valida a sintaxe antes de instalar
  install -o root -g root -m 440 "$tmp" "$destino"
  rm -f "$tmp"
  cat "$destino"
}

configurar_logrotate() {
  cat > /etc/logrotate.d/refresca <<'EOF'
# Gerado por refresca-sp-infra — rotação semanal dos logs do projeto
/var/log/refresca/*.log /var/log/refresca/*/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su root refresca-ops
}
EOF
  logrotate -d /etc/logrotate.d/refresca 2>&1 | tail -n 5
}

run_step "Criar grupo de operadores ${OPS_GROUP}"            groupadd -f "$OPS_GROUP"
run_step "Criar usuário de serviço da API (${APP_USER})"     criar_usuario_servico "$APP_USER" "Refresca SP - API"
run_step "Criar usuário de serviço do monitor (${MONITOR_USER})" criar_usuario_servico "$MONITOR_USER" "Refresca SP - Monitor"
run_step "Adicionar ${ADMIN} ao grupo ${OPS_GROUP}"          usermod -aG "$OPS_GROUP" "$ADMIN"
run_step "Criar diretórios e aplicar permissões"            criar_diretorios
run_step "Configurar sudo restrito para ${OPS_GROUP}"        configurar_sudoers
run_step "Configurar rotação de logs (logrotate)"            configurar_logrotate

log_ok "Usuários e permissões prontos. ${ADMIN} precisa sair e entrar de novo no SSH para usar o grupo ${OPS_GROUP}."
