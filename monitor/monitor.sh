#!/usr/bin/env bash
# =============================================================================
# monitor.sh — monitoramento de CPU, memória RAM, disco e da API Refresca SP
#
# Modos:
#   monitor.sh --once          uma verificação e sai (padrão)
#   monitor.sh --daemon        laço contínuo (usado pela refresca-monitor.service)
#   monitor.sh --simular-erro  falha controlada, para demonstrar o registro de erros
#
# Saídas:
#   /var/log/refresca/monitor/monitor.log  uma linha por verificação
#   /var/log/refresca/monitor/alerts.log   alertas (ALERTA, CRITICO, NORMALIZADO)
#   /var/log/refresca/monitor/errors.log   erros do próprio monitor
#
# Limites lidos de /etc/refresca/monitor.conf (gerado por install-monitor.sh).
# =============================================================================
set -Eeuo pipefail

LOG_COMPONENT="monitor"
SCRIPT_NAME="monitor.sh"
LOG_STEP="coleta"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r /opt/refresca/lib/logging.sh ]]; then
  LIB="/opt/refresca/lib/logging.sh"
else
  LIB="${SELF_DIR}/../lib/logging.sh"          # execução direta a partir do repositório
fi
# shellcheck source=../lib/logging.sh
source "$LIB"

MONITOR_CONF="${MONITOR_CONF:-/etc/refresca/monitor.conf}"
if [[ -r "$MONITOR_CONF" ]]; then
  # shellcheck disable=SC1090
  source "$MONITOR_CONF"
fi
: "${MONITOR_INTERVAL:=15}"
: "${CPU_WARN:=80}"  "${CPU_CRIT:=95}"
: "${MEM_WARN:=80}"  "${MEM_CRIT:=95}"
: "${DISK_WARN:=85}" "${DISK_CRIT:=95}"
: "${HEALTH_URL:=http://127.0.0.1/api/refugios}"
: "${API_UNIT:=refresca-api.service}"

ALERT_FILE="${LOG_DIR}/alerts.log"
declare -A ESTADO_ANTERIOR=()     # lembra o último nível de cada recurso (para detectar normalização)
PIOR="OK"
API_STATUS="N/A"

uso() { sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; }

# ----------------------------------------------------------------------------
# Coleta de métricas (lidas direto do kernel via /proc, sem dependências)
# ----------------------------------------------------------------------------

# CPU: compara dois instantes de /proc/stat com 1s de intervalo
ler_cpu() {
  local -a a b
  local i tot_a=0 tot_b=0 idle_a idle_b dt di
  read -r -a a < /proc/stat
  sleep 1
  read -r -a b < /proc/stat
  # campos: cpu user nice system idle iowait irq softirq steal
  idle_a=$(( a[4] + a[5] )); idle_b=$(( b[4] + b[5] ))
  for i in 1 2 3 4 5 6 7 8; do
    tot_a=$(( tot_a + a[i] )); tot_b=$(( tot_b + b[i] ))
  done
  dt=$(( tot_b - tot_a )); di=$(( idle_b - idle_a ))
  if (( dt <= 0 )); then echo 0; else echo $(( 100 * (dt - di) / dt )); fi
}

# Memória: usa MemAvailable (o que realmente está livre para novos processos)
# saída: "percentual usado_MiB total_MiB"
ler_memoria() {
  awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2}
       END { if (t == 0) exit 1; printf "%d %d %d\n", (t-a)*100/t, (t-a)/1024, t/1024 }' /proc/meminfo
}

ler_swap() {
  awk '/^SwapTotal:/{t=$2} /^SwapFree:/{f=$2}
       END { if (t == 0) print 0; else printf "%d\n", (t-f)*100/t }' /proc/meminfo
}

# Disco: partição raiz; saída "percentual livre_GiB"
ler_disco() {
  df -Pk / | awk 'NR==2 { gsub("%", "", $5); printf "%d %.1f\n", $5, $4/1048576 }'
}

# ----------------------------------------------------------------------------
# Avaliação e alertas
# ----------------------------------------------------------------------------
registrar_alerta() {   # NIVEL RECURSO mensagem
  local nivel="$1" recurso="$2"; shift 2
  printf '%s | %s | %-11s | %-7s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" \
    "$(hostname -s)" "$nivel" "$recurso" "$*" >> "$ALERT_FILE" 2>/dev/null || true
  if [[ "$nivel" == "NORMALIZADO" ]]; then
    LOG_STEP="$recurso" log_ok "${nivel}: $*"
  else
    LOG_STEP="$recurso" log_warn "${nivel}: $*"
  fi
}

atualizar_pior() {
  case "$1" in
    CRITICO) PIOR="CRITICO" ;;
    ALERTA)  [[ "$PIOR" == "CRITICO" ]] || PIOR="ALERTA" ;;
  esac
}

avaliar() {   # RECURSO VALOR LIMITE_ALERTA LIMITE_CRITICO DESCRIÇÃO
  local recurso="$1" valor="$2" warn="$3" crit="$4" desc="$5" nivel anterior
  if   (( valor >= crit )); then nivel="CRITICO"
  elif (( valor >= warn )); then nivel="ALERTA"
  else nivel="OK"; fi
  anterior="${ESTADO_ANTERIOR[$recurso]:-OK}"

  if [[ "$nivel" != "OK" ]]; then
    registrar_alerta "$nivel" "$recurso" "${desc} — limite alerta ${warn}% / crítico ${crit}%"
  elif [[ "$anterior" != "OK" ]]; then
    registrar_alerta "NORMALIZADO" "$recurso" "${desc} — voltou abaixo de ${warn}%"
  fi
  ESTADO_ANTERIOR[$recurso]="$nivel"
  atualizar_pior "$nivel"
}

verificar_api() {
  local anterior="${ESTADO_ANTERIOR[api]:-OK}" estado
  API_STATUS="N/A"
  systemctl cat "$API_UNIT" &>/dev/null || return 0     # API não instalada: nada a verificar

  if ! systemctl is-active --quiet "$API_UNIT"; then
    estado="$(systemctl is-active "$API_UNIT" 2>/dev/null || true)"
    API_STATUS="DOWN(servico:${estado})"
  elif curl -fsS -m 3 -o /dev/null "$HEALTH_URL" 2>/dev/null; then
    API_STATUS="UP"
  else
    API_STATUS="DOWN(sem_resposta_http)"
  fi

  if [[ "$API_STATUS" != "UP" ]]; then
    registrar_alerta "CRITICO" "api" "API indisponível: ${API_STATUS} (${HEALTH_URL})"
    ESTADO_ANTERIOR[api]="CRITICO"
    atualizar_pior "CRITICO"
  else
    if [[ "$anterior" != "OK" ]]; then
      registrar_alerta "NORMALIZADO" "api" "API voltou a responder em ${HEALTH_URL}"
    fi
    ESTADO_ANTERIOR[api]="OK"
  fi
}

numero() { [[ "$1" =~ ^[0-9]+$ ]]; }

coleta() {
  local cpu mem mem_used mem_total swap disk disk_free memline diskline
  cpu="$(ler_cpu)"
  memline="$(ler_memoria)"; read -r mem mem_used mem_total <<< "$memline"
  swap="$(ler_swap)"
  diskline="$(ler_disco)"; read -r disk disk_free <<< "$diskline"

  for v in "$cpu" "$mem" "$disk" "$swap"; do
    if ! numero "$v"; then
      log_error "Leitura de métrica inválida: '${v}' (cpu=${cpu} mem=${mem} disco=${disk} swap=${swap})"
      return 1
    fi
  done

  PIOR="OK"
  avaliar cpu     "$cpu"  "$CPU_WARN"  "$CPU_CRIT"  "CPU em ${cpu}%"
  avaliar memoria "$mem"  "$MEM_WARN"  "$MEM_CRIT"  "Memória em ${mem}% (${mem_used}/${mem_total} MiB)"
  avaliar disco   "$disk" "$DISK_WARN" "$DISK_CRIT" "Disco / em ${disk}% (${disk_free} GiB livres)"
  verificar_api

  LOG_STEP="coleta" log_info "CPU=${cpu}% MEM=${mem}% (${mem_used}/${mem_total}MiB) SWAP=${swap}% DISCO=${disk}% API=${API_STATUS} STATUS=${PIOR}"
}

# ----------------------------------------------------------------------------
# Modos de execução
# ----------------------------------------------------------------------------
modo_daemon() {
  local ciclo=0
  LOG_STEP="servico"
  log_info "Monitoramento INICIADO (PID $$, intervalo ${MONITOR_INTERVAL}s | limites CPU ${CPU_WARN}/${CPU_CRIT}% MEM ${MEM_WARN}/${MEM_CRIT}% DISCO ${DISK_WARN}/${DISK_CRIT}%)"
  trap 'LOG_STEP=servico log_warn "Parada solicitada (sinal recebido) — encerrando PID $$"; exit 0' TERM INT

  while true; do
    ciclo=$(( ciclo + 1 ))
    if ! coleta; then
      LOG_STEP="coleta" log_error "Ciclo ${ciclo}: falha na coleta de métricas — tentando de novo no próximo ciclo"
    fi
    sleep "$MONITOR_INTERVAL" &
    wait $! || true
  done
}

simular_erro() {
  LOG_STEP="simulacao"
  log_warn "Falha CONTROLADA solicitada: lendo uma fonte de métrica inexistente (/proc/refresca_sensor)"
  cat /proc/refresca_sensor > /dev/null      # falha proposital: o trap ERR registra e o script sai com erro
  log_info "Esta linha nunca deveria aparecer"
}

log_init
enable_error_trap

case "${1:---once}" in
  --once)          coleta ;;
  --daemon)        modo_daemon ;;
  --simular-erro)  simular_erro ;;
  -h|--help)       uso ;;
  *)               uso; exit 2 ;;
esac
