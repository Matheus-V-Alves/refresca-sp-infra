#!/usr/bin/env bash
# =============================================================================
# deploy-app.sh — instala e coloca no ar a API de Pontos de Refúgio (C# / .NET)
#   1. instala o SDK do .NET (versão definida em DOTNET_CHANNEL)
#   2. baixa o código do repositório da disciplina de C# (git clone / pull)
#   3. executa os testes unitários do projeto (portão de qualidade)
#   4. publica a aplicação em /opt/refresca/api (somente leitura para o serviço)
#   5. gera as variáveis de ambiente em /etc/refresca/refresca.env
#   6. configura o nginx como proxy reverso (porta 80)
#   7. instala a unit systemd, habilita no boot e inicia
#   8. aguarda a API responder
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
LOG_STEP="aplicacao"
require_root; log_init; enable_error_trap

SRC_DIR="${APP_DIR}/src"
API_DIR="${APP_DIR}/api"
PUBLISH_TMP="${APP_DIR}/.publish-tmp"
DOTNET="${DOTNET_DIR}/dotnet"
ENV_FILE="/etc/refresca/refresca.env"
UNIT="refresca-api.service"
INSTALL_LOG="${LOG_DIR}/install.log"

export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_ROOT="$DOTNET_DIR"

if ! id "$APP_USER" &>/dev/null; then
  log_error "Usuário ${APP_USER} não existe — execute antes: sudo bash setup.sh 04"
  exit 1
fi

registrar_instalacao() {   # componente versão
  printf '%s | %s | %-12s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$(hostname -s)" "$1" "$2" >> "$INSTALL_LOG"
}

instalar_dotnet() {
  if [[ -x "$DOTNET" ]] && "$DOTNET" --list-sdks | grep -q "^${DOTNET_CHANNEL}\."; then
    echo "SDK .NET ${DOTNET_CHANNEL} já instalado em ${DOTNET_DIR}"
  else
    curl -fsSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
    bash /tmp/dotnet-install.sh --channel "$DOTNET_CHANNEL" --install-dir "$DOTNET_DIR" --no-path
    rm -f /tmp/dotnet-install.sh
  fi
  chmod -R o+rX "$DOTNET_DIR"                       # o usuário do serviço precisa ler o runtime
  ln -sf "$DOTNET" /usr/local/bin/dotnet
  "$DOTNET" --list-sdks
  "$DOTNET" --list-runtimes
  registrar_instalacao "dotnet-sdk" "$("$DOTNET" --version)"
}

obter_codigo() {
  if [[ -d "${SRC_DIR}/.git" ]]; then
    git -C "$SRC_DIR" fetch --depth 1 origin "$APP_REPO_REF"
    git -C "$SRC_DIR" reset --hard FETCH_HEAD
    git -C "$SRC_DIR" clean -fdx
  else
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "$APP_REPO_REF" "$APP_REPO_URL" "$SRC_DIR"
  fi
  local versao
  versao="$(git -C "$SRC_DIR" log -1 --format='%h %ad %s' --date=short)"
  echo "Commit implantado: ${versao}"
  registrar_instalacao "app-commit" "${APP_REPO_URL} @ ${versao}"
}

rodar_testes() {
  if [[ "${RUN_APP_TESTS:-1}" != "1" ]]; then
    echo "Testes desativados (RUN_APP_TESTS=${RUN_APP_TESTS})"; return 0
  fi
  cd "$SRC_DIR"
  "$DOTNET" test --nologo --verbosity minimal
}

publicar() {
  rm -rf "$PUBLISH_TMP"
  "$DOTNET" publish "${SRC_DIR}/${APP_PROJECT}" -c Release -o "$PUBLISH_TMP" --nologo
  [[ -f "${PUBLISH_TMP}/${APP_DLL}" ]] || { echo "Publicação não gerou ${APP_DLL}"; return 1; }

  # troca o conteúdo publicado (remove versões anteriores, inclusive de outras stacks)
  install -d -o root -g "$APP_USER" -m 750 "$API_DIR"
  find "$API_DIR" -mindepth 1 -delete
  cp -a "${PUBLISH_TMP}/." "$API_DIR"/
  rm -rf "$PUBLISH_TMP"
  chown -R root:"$APP_USER" "$API_DIR"
  find "$API_DIR" -type d -exec chmod 750 {} +
  find "$API_DIR" -type f -exec chmod 640 {} +
  ls -l "$API_DIR" | head -n 15
}

gerar_env() {
  cat > "$ENV_FILE" <<EOF
# Variáveis de ambiente da API Refresca SP (.NET)
# Gerado por app/deploy-app.sh em $(date '+%F %T') — não editar manualmente
ASPNETCORE_ENVIRONMENT=Production
ASPNETCORE_URLS=http://127.0.0.1:${API_PORT}
ConnectionStrings__RefrescaSP="Data Source=${DATA_DIR}/refresca-sp.db"
DOTNET_ROOT=${DOTNET_DIR}
DOTNET_CLI_TELEMETRY_OPTOUT=1
DOTNET_NOLOGO=1
EOF
  chown root:"$APP_USER" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
  ls -l "$ENV_FILE"
  cat "$ENV_FILE"
}

configurar_nginx() {
  local names="${NEW_HOSTNAME} ${NEW_HOSTNAME}.${DOMAIN} ${EXTRA_HOST_ALIASES} _"
  sed -e "s/__API_PORT__/${API_PORT}/g" -e "s/__SERVER_NAMES__/${names}/g" \
    "${REPO_DIR}/app/nginx-refresca.conf" > /etc/nginx/sites-available/refresca
  ln -sf /etc/nginx/sites-available/refresca /etc/nginx/sites-enabled/refresca
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl enable nginx
  systemctl reload nginx || systemctl restart nginx
}

instalar_servico() {
  touch /var/log/refresca/app/api.log
  chown "$APP_USER":refresca-ops /var/log/refresca/app/api.log
  chmod 640 /var/log/refresca/app/api.log
  install -o root -g root -m 644 "${REPO_DIR}/systemd/${UNIT}" /etc/systemd/system/
  install_failure_handler
  systemctl daemon-reload
  systemctl enable "$UNIT"
  systemctl restart "$UNIT"
  systemctl is-enabled "$UNIT"
}

aguardar_api() {
  local i url="http://127.0.0.1${HEALTH_PATH}"
  for i in $(seq 1 30); do
    if curl -fsS -m 3 -o /dev/null "$url"; then
      echo "API respondeu em ${url} na tentativa ${i}"
      return 0
    fi
    sleep 2
  done
  echo "A API não respondeu em 60s. Últimas linhas:"
  journalctl -u "$UNIT" -n 15 --no-pager || true
  tail -n 20 /var/log/refresca/app/api.log || true
  return 1
}

run_step "Instalar SDK .NET ${DOTNET_CHANNEL} em ${DOTNET_DIR}"     instalar_dotnet
run_step "Baixar código da API (${APP_REPO_URL})"                   obter_codigo
run_step "Executar testes unitários do projeto (dotnet test)"       rodar_testes
run_step "Publicar a aplicação em ${API_DIR} (Release)"            publicar
run_step "Gerar variáveis de ambiente (${ENV_FILE})"                gerar_env
run_step "Configurar nginx como proxy reverso (porta 80)"           configurar_nginx
run_step "Instalar, habilitar e iniciar ${UNIT}"                    instalar_servico
run_step "Aguardar a API responder em ${HEALTH_PATH}"               aguardar_api
run_step "Testar acesso pelo nome api.${DOMAIN}"                    curl -fsS -m 5 "http://api.${DOMAIN}${HEALTH_PATH}"

log_ok "API no ar: http://api.${DOMAIN}/swagger (local) | http://<IP público>/swagger (navegador)"
