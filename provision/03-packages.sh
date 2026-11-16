#!/usr/bin/env bash
# =============================================================================
# Etapa 03 — Pacotes e dependências
#   Atualiza o sistema e instala tudo o que a aplicação e o monitoramento usam.
#   Cada pacote instalado é registrado com a versão em install.log (auditoria).
# =============================================================================
set -Eeuo pipefail
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
LOG_STEP="pacotes"
require_root; log_init; enable_error_trap

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a           # evita a tela interativa do needrestart no Ubuntu 24.04
APT_OPTS=(-y -q -o DPkg::Lock::Timeout=300
          -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
INSTALL_LOG="${LOG_DIR}/install.log"

# pacote -> para que serve (documentação viva do ambiente)
declare -A PACKAGES=(
  [libicu74]="globalização do .NET (datas, textos, culturas)"
  [nginx]="proxy reverso (porta 80 -> API)"
  [sqlite3]="cliente para inspecionar o banco da API"
  [curl]="download do .NET e health check da API"
  [jq]="formatar JSON nas demonstrações"
  [sysstat]="ferramentas de desempenho (mpstat, iostat)"
  [stress-ng]="simulação de consumo elevado nos testes de falha"
  [ufw]="firewall"
  [logrotate]="rotação dos logs do projeto"
  [git]="download do código da API (repositório da disciplina de C#)"
)

registrar_versoes() {
  local p v
  for p in "${!PACKAGES[@]}"; do
    # shellcheck disable=SC2016
    v="$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null || echo 'NAO INSTALADO')"
    printf '%s | %s | %-12s | %-28s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" \
      "$(hostname -s)" "$p" "$v" "${PACKAGES[$p]}" >> "$INSTALL_LOG"
    printf '%-12s %-28s %s\n' "$p" "$v" "${PACKAGES[$p]}"
  done
}

run_step "Atualizar índice de pacotes (apt-get update)"  apt-get update -q -o DPkg::Lock::Timeout=300
run_step "Atualizar pacotes do sistema (apt-get upgrade)" apt-get upgrade "${APT_OPTS[@]}"
run_step "Instalar dependências: ${!PACKAGES[*]}"        apt-get install "${APT_OPTS[@]}" "${!PACKAGES[@]}"
run_step "Registrar versões instaladas em install.log"   registrar_versoes

if [[ -f /var/run/reboot-required ]]; then
  log_warn "Atualização exige reinicialização (kernel). Faça ao final do setup — serve como teste de reboot."
fi
