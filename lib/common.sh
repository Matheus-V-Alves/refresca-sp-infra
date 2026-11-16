#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# lib/common.sh — carregado no início de todos os scripts do projeto.
# Localiza o repositório, carrega a configuração e a biblioteca de log.
# =============================================================================

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_FILE="${CONFIG_FILE:-${REPO_DIR}/config/refresca.conf}"

if [[ ! -r "$CONFIG_FILE" ]]; then
  echo "ERRO: arquivo de configuração não encontrado: ${CONFIG_FILE}" >&2
  exit 1
fi

set -a
# shellcheck source=../config/refresca.conf
source "$CONFIG_FILE"
set +a

# shellcheck source=logging.sh
source "${REPO_DIR}/lib/logging.sh"

# Instala o tratador de falhas usado pelo "OnFailure=" das units systemd.
install_failure_handler() {
  install -d -o root -g root -m 755 "${APP_DIR}/bin"
  install -o root -g root -m 755 "${REPO_DIR}/tools/registrar-falha.sh" "${APP_DIR}/bin/registrar-falha.sh"
  install -o root -g root -m 644 "${REPO_DIR}/systemd/refresca-failure@.service" /etc/systemd/system/
}
