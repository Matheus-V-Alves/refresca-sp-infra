#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# lib/logging.sh — biblioteca de log e auditoria do Refresca SP
#
# Cada linha de log responde às perguntas da auditoria:
#   QUANDO | ONDE (host) | QUEM (script) | NÍVEL | ETAPA | O QUÊ e RESULTADO
#   2026-11-16 10:42:01 -0300 | refresca-srv01 | 02-network.sh | OK    | rede | SUCESSO -> ...
#
# Variáveis aceitas antes do "source":
#   LOG_COMPONENT      provision | monitor | tests  (define a pasta do log)
#   LOG_STEP           nome da etapa atual
#   REFRESCA_LOG_ROOT  raiz dos logs (padrão /var/log/refresca)
# =============================================================================

REFRESCA_LOG_ROOT="${REFRESCA_LOG_ROOT:-/var/log/refresca}"
LOG_COMPONENT="${LOG_COMPONENT:-provision}"
LOG_DIR="${REFRESCA_LOG_ROOT}/${LOG_COMPONENT}"
LOG_FILE="${LOG_DIR}/${LOG_COMPONENT}.log"
ERR_FILE="${LOG_DIR}/errors.log"
SCRIPT_NAME="${SCRIPT_NAME:-$(basename "$0")}"
LOG_STEP="${LOG_STEP:-${SCRIPT_NAME%.sh}}"

if [[ -t 1 ]]; then
  _C_RED=$'\e[31m'; _C_YEL=$'\e[33m'; _C_GRN=$'\e[32m'; _C_RST=$'\e[0m'
else
  _C_RED=""; _C_YEL=""; _C_GRN=""; _C_RST=""
fi

# Garante que a pasta de log existe (não aborta o script se não conseguir).
log_init() {
  mkdir -p "$LOG_DIR" 2>/dev/null || echo "AVISO: não foi possível criar ${LOG_DIR}" >&2
  return 0
}

_log_line() {
  printf '%s | %s | %s | %-5s | %s | %s' \
    "$(date '+%Y-%m-%d %H:%M:%S %z')" "$(hostname -s 2>/dev/null || echo '?')" \
    "$SCRIPT_NAME" "$1" "$LOG_STEP" "$2"
}

# log_write NIVEL mensagem — grava no arquivo do componente e mostra no terminal.
# Erros vão também para errors.log, que concentra as falhas para auditoria.
log_write() {
  local level="$1"; shift
  local line color=""
  line="$(_log_line "$level" "$*")"
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
  if [[ "$level" == "ERROR" ]]; then
    printf '%s\n' "$line" >> "$ERR_FILE" 2>/dev/null || true
  fi
  case "$level" in
    ERROR) color="$_C_RED" ;;
    WARN)  color="$_C_YEL" ;;
    OK)    color="$_C_GRN" ;;
  esac
  if [[ "$level" == "ERROR" ]]; then
    printf '%s%s%s\n' "$color" "$line" "$_C_RST" >&2
  else
    printf '%s%s%s\n' "$color" "$line" "$_C_RST"
  fi
  return 0
}

log_info()  { log_write INFO  "$*"; }
log_ok()    { log_write OK    "$*"; }
log_warn()  { log_write WARN  "$*"; }
log_error() { log_write ERROR "$*"; }

# run_step "descrição" comando [args...]
# Executa uma etapa registrando início, saída completa, duração e resultado.
# O comando roda num subshell com "set -e" ativo, então uma função passada aqui
# para no primeiro comando que falhar.
# ATENÇÃO (regra do bash): se run_step estiver dentro de um if/||/&&, o "set -e"
# é ignorado dentro da FUNÇÃO executada. Por isso, dentro de condições, use
# run_step apenas com comandos externos (ex.: netplan, curl), nunca com funções.
run_step() {
  local desc="$1"; shift
  local start rc tmp had_e=0 saved_trap
  start=$(date +%s)
  tmp=$(mktemp)
  [[ $- == *e* ]] && had_e=1
  saved_trap=$(trap -p ERR)

  log_info "INICIO  -> ${desc}"
  set +e
  trap - ERR
  ( set -e; "$@" ) >"$tmp" 2>&1
  rc=$?
  [[ -n "$saved_trap" ]] && eval "$saved_trap"
  (( had_e )) && set -e

  if [[ -s "$tmp" ]]; then
    sed 's/^/        | /' "$tmp" >> "$LOG_FILE" 2>/dev/null || true
  fi
  if (( rc == 0 )); then
    log_ok "SUCESSO -> ${desc} ($(( $(date +%s) - start ))s)"
  else
    log_error "FALHA   -> ${desc} (código ${rc})"
    if [[ -s "$tmp" ]]; then
      tail -n 15 "$tmp" | sed 's/^/        | /' | tee -a "$ERR_FILE" >&2 2>/dev/null || true
    fi
  fi
  rm -f "$tmp"
  return "$rc"
}

# Registra qualquer comando que falhe fora de run_step (com linha e comando).
_on_error() {
  # a falha de run_step já foi registrada com detalhes; evita linha duplicada
  [[ "$3" == 'return "$rc"' ]] && return 0
  log_error "Erro não tratado: '${3}' retornou código ${1} (linha ${2} de ${SCRIPT_NAME})"
}

enable_error_trap() {
  set -o errtrace
  trap '_on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
}

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "Este script precisa de privilégios de root. Execute: sudo bash $0 $*" >&2
    exit 1
  fi
}
