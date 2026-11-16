#!/usr/bin/env bash
# =============================================================================
# tests/falhas.sh — simulações de falha e verificação da recuperação
#
# Uso: sudo bash tests/falhas.sh <teste>
#
#   servico      mata o monitor com SIGKILL e confirma que o systemd o reinicia
#   start-stop   demonstra iniciar, parar e reiniciar o serviço de monitoramento
#   api          para a API e confirma que o monitor detecta a indisponibilidade
#   cpu          consumo elevado de CPU (stress-ng) -> ALERTA/CRITICO -> NORMALIZADO
#   memoria      consumo elevado de memória (stress-ng) -> ALERTA -> NORMALIZADO
#   disco        enche o disco além do limite com um arquivo temporário
#   erro         falha controlada no monitor.sh e confirma o registro no errors.log
#   limite       derruba o monitor até esgotar as tentativas (estado failed),
#                mostra o registro via OnFailure= e recupera o serviço
#   pos-reboot   após "sudo reboot": confirma que tudo voltou sozinho
#   todos        executa todos, exceto pos-reboot
#
# Resultado de cada teste: /var/log/refresca/tests/tests.log
# =============================================================================
set -Eeuo pipefail
LOG_COMPONENT="tests"
# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

MON="refresca-monitor.service"
API="refresca-api.service"
ALERTS="/var/log/refresca/monitor/alerts.log"
MON_ERRORS="/var/log/refresca/monitor/errors.log"
FALHAS_LOG="/var/log/refresca/servicos-falhas.log"
ESPERA=$(( MONITOR_INTERVAL + 5 ))     # tempo para o monitor completar um ciclo
DISK_TEST_FILE="/var/tmp/refresca-teste-disco.img"
# garante que o arquivo do teste de disco nunca fique para trás (nem com Ctrl+C)
trap 'rm -f "$DISK_TEST_FILE"; kill "${TAIL_PID:-0}" 2>/dev/null || true' EXIT

uso() { sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------- utilitários
linhas() { if [[ -f "$1" ]]; then wc -l < "$1"; else echo 0; fi; }

alerta_registrado() {   # LINHA_INICIAL RECURSO [NIVEL]
  awk -v s="$(( $1 + 1 ))" -v r="| ${2} " -v n="${3:-}" \
    'NR >= s && index($0, r) && (n == "" ? !index($0, "NORMALIZADO") : index($0, n)) { f = 1 }
     END { exit !f }' "$ALERTS"
}

mostrar_desde() {       # ARQUIVO LINHA_INICIAL
  echo "──────── novas linhas em $(basename "$1") ────────"
  tail -n +"$(( $2 + 1 ))" "$1" || true
  echo "──────────────────────────────────────────────"
}

acompanhar_alertas() { tail -n 0 -F "$ALERTS" 2>/dev/null & TAIL_PID=$!; }
parar_acompanhamento() { kill "${TAIL_PID:-0}" 2>/dev/null || true; wait "${TAIL_PID:-0}" 2>/dev/null || true; }

resultado() {           # 0|1 descrição
  if [[ "$1" -eq 0 ]]; then log_ok "TESTE APROVADO: $2"; else log_error "TESTE REPROVADO: $2"; return 1; fi
}

# ---------------------------------------------------------------- testes
teste_servico() {
  LOG_STEP="teste-servico"
  local pid novo antes depois
  pid="$(systemctl show -p MainPID --value "$MON")"
  antes="$(systemctl show -p NRestarts --value "$MON")"
  if (( pid == 0 )); then log_error "O monitor não está rodando"; return 1; fi

  log_warn "Matando o processo do monitor (PID ${pid}) com SIGKILL — simula uma queda inesperada"
  kill -9 "$pid"
  log_info "Aguardando o systemd reiniciar o serviço (RestartSec=5s)..."
  sleep 8
  novo="$(systemctl show -p MainPID --value "$MON")"
  depois="$(systemctl show -p NRestarts --value "$MON")"
  journalctl -u "$MON" -n 6 --no-pager -o short-iso || true

  if systemctl is-active --quiet "$MON" && (( novo > 0 && novo != pid )); then
    log_info "PID ${pid} -> ${novo} | contador de reinícios: ${antes} -> ${depois}"
    resultado 0 "monitor recuperado automaticamente após SIGKILL"
  else
    resultado 1 "monitor não voltou após SIGKILL (estado: $(systemctl is-active "$MON" || true))"
  fi
}

teste_start_stop() {
  LOG_STEP="teste-start-stop"
  log_info "Parando o serviço: systemctl stop ${MON}"
  systemctl stop "$MON"
  log_info "Estado após stop: $(systemctl is-active "$MON" || true)"
  sleep 2
  log_info "Iniciando o serviço: systemctl start ${MON}"
  systemctl start "$MON"
  log_info "Estado após start: $(systemctl is-active "$MON" || true) (PID $(systemctl show -p MainPID --value "$MON"))"
  sleep 2
  log_info "Reiniciando o serviço: systemctl restart ${MON}"
  systemctl restart "$MON"
  sleep 2
  log_info "Estado após restart: $(systemctl is-active "$MON" || true) (PID $(systemctl show -p MainPID --value "$MON"))"
  echo "──────── registro do próprio monitor ────────"
  grep -E 'INICIADO|Parada solicitada' /var/log/refresca/monitor/monitor.log | tail -n 4 || true
  local rc=0
  systemctl is-active --quiet "$MON" || rc=$?
  resultado "$rc" "serviço de monitoramento responde a start, stop e restart"
}

teste_api() {
  LOG_STEP="teste-api"
  local n; n="$(linhas "$ALERTS")"
  acompanhar_alertas
  log_warn "Parando a API manualmente (simula queda da aplicação)"
  systemctl stop "$API"
  log_info "Aguardando ${ESPERA}s para o monitor perceber..."
  sleep "$ESPERA"
  log_info "Religando a API"
  systemctl start "$API"
  sleep "$ESPERA"
  parar_acompanhamento
  mostrar_desde "$ALERTS" "$n"
  if alerta_registrado "$n" api CRITICO && alerta_registrado "$n" api NORMALIZADO; then
    resultado 0 "monitor detectou a API fora do ar e registrou a normalização"
  else
    resultado 1 "alerta da API não registrado"
  fi
}

teste_cpu() {
  LOG_STEP="teste-cpu"
  local n dur; n="$(linhas "$ALERTS")"; dur=$(( MONITOR_INTERVAL * 3 ))
  acompanhar_alertas
  log_warn "Estressando todos os núcleos de CPU a 100% por ${dur}s (stress-ng)"
  stress-ng --cpu 0 --cpu-load 100 --timeout "${dur}s" --quiet || true
  log_info "Estresse encerrado — aguardando ${ESPERA}s pela normalização"
  sleep "$ESPERA"
  parar_acompanhamento
  mostrar_desde "$ALERTS" "$n"
  if alerta_registrado "$n" cpu && alerta_registrado "$n" cpu NORMALIZADO; then
    resultado 0 "consumo elevado de CPU gerou alerta e normalização"
  else
    resultado 1 "alerta de CPU não registrado"
  fi
}

teste_memoria() {
  LOG_STEP="teste-memoria"
  local n dur pct="${MEM_STRESS_PCT:-90}"
  n="$(linhas "$ALERTS")"; dur=$(( MONITOR_INTERVAL * 3 ))
  acompanhar_alertas
  log_warn "Alocando ${pct}% da memória disponível por ${dur}s (stress-ng --vm)"
  stress-ng --vm 1 --vm-bytes "${pct}%" --vm-keep --timeout "${dur}s" --quiet || true
  log_info "Estresse encerrado — aguardando ${ESPERA}s pela normalização"
  sleep "$ESPERA"
  parar_acompanhamento
  mostrar_desde "$ALERTS" "$n"
  if alerta_registrado "$n" memoria && alerta_registrado "$n" memoria NORMALIZADO; then
    resultado 0 "consumo elevado de memória gerou alerta e normalização"
  else
    resultado 1 "alerta de memória não registrado (tente MEM_STRESS_PCT=95)"
  fi
}

teste_disco() {
  LOG_STEP="teste-disco"
  local n usado livre alvo meta=$(( DISK_WARN + 3 )) arquivo="$DISK_TEST_FILE"
  n="$(linhas "$ALERTS")"
  read -r usado livre < <(df -Pk / | awk 'NR==2 {print $3, $4}')
  alvo=$(( (usado + livre) * meta / 100 - usado ))
  if (( alvo <= 0 )); then log_error "Disco já está acima de ${meta}%"; return 1; fi

  acompanhar_alertas
  log_warn "Criando arquivo de $(( alvo / 1048576 )) GiB para levar o disco a ~${meta}%"
  fallocate -l "${alvo}K" "$arquivo"
  df -h /
  sleep "$ESPERA"
  log_info "Removendo o arquivo de teste"
  rm -f "$arquivo"
  sleep "$ESPERA"
  parar_acompanhamento
  mostrar_desde "$ALERTS" "$n"
  if alerta_registrado "$n" disco && alerta_registrado "$n" disco NORMALIZADO; then
    resultado 0 "uso elevado de disco gerou alerta e normalização"
  else
    resultado 1 "alerta de disco não registrado"
  fi
}

teste_erro() {
  LOG_STEP="teste-erro"
  local n rc=0; n="$(linhas "$MON_ERRORS")"
  log_warn "Executando monitor.sh --simular-erro como ${MONITOR_USER}"
  sudo -u "$MONITOR_USER" "${APP_DIR}/monitor/monitor.sh" --simular-erro || rc=$?
  mostrar_desde "$MON_ERRORS" "$n"
  if (( rc != 0 )) && (( $(linhas "$MON_ERRORS") > n )); then
    resultado 0 "falha controlada terminou com código ${rc} e foi registrada em errors.log"
  else
    resultado 1 "falha não foi registrada (código ${rc})"
  fi
}

teste_limite() {
  LOG_STEP="teste-limite"
  local i pid estado n; n="$(linhas "$FALHAS_LOG")"
  log_warn "Derrubando o monitor repetidamente para esgotar StartLimitBurst=5 (falha definitiva)"
  for i in $(seq 1 10); do
    estado="$(systemctl is-active "$MON" || true)"
    [[ "$estado" == "failed" ]] && break
    pid="$(systemctl show -p MainPID --value "$MON")"
    if (( pid > 0 )); then
      kill -9 "$pid"
      log_info "Queda ${i}: PID ${pid} morto"
    fi
    sleep 6
  done
  sleep 2
  estado="$(systemctl is-active "$MON" || true)"
  log_info "Estado do serviço: ${estado}"
  mostrar_desde "$FALHAS_LOG" "$n"

  local detectou=1
  if [[ "$estado" == "failed" ]] && (( $(linhas "$FALHAS_LOG") > n )); then
    detectou=0
    log_ok "systemd marcou a unidade como failed e o OnFailure= registrou a ocorrência"
  fi

  log_info "Recuperação manual: systemctl reset-failed + start"
  systemctl reset-failed "$MON"
  systemctl start "$MON"
  sleep 3
  if (( detectou == 0 )) && systemctl is-active --quiet "$MON"; then
    resultado 0 "falha definitiva detectada, registrada e serviço recuperado"
  else
    resultado 1 "falha definitiva não detectada ou serviço não recuperado"
  fi
}

teste_pos_reboot() {
  LOG_STEP="pos-reboot"
  local falhas=0 u
  log_info "Sistema ligado desde $(uptime -s)"
  last -x -n 3 reboot 2>/dev/null || true

  for u in nginx "$API" "$MON"; do
    if systemctl is-enabled --quiet "$u" && systemctl is-active --quiet "$u"; then
      log_ok "${u}: habilitado no boot e ativo"
    else
      log_error "${u}: is-enabled=$(systemctl is-enabled "$u" || true) is-active=$(systemctl is-active "$u" || true)"
      falhas=1
    fi
  done

  if [[ "$(hostnamectl --static)" == "$NEW_HOSTNAME" ]]; then
    log_ok "Hostname preservado: ${NEW_HOSTNAME}"
  else
    log_error "Hostname mudou após o reboot: $(hostnamectl --static)"; falhas=1
  fi
  if ip -4 addr show dev "$NET_IFACE" | grep -q "inet ${STATIC_IP}/"; then
    log_ok "IP fixo preservado: ${STATIC_IP}"
  else
    log_error "IP ${STATIC_IP} não está em ${NET_IFACE}"; falhas=1
  fi
  if swapon --show=NAME --noheadings | grep -q /swapfile; then
    log_ok "Swap ativo após o boot"
  else
    log_error "Swap não foi ativado no boot"; falhas=1
  fi
  if curl -fsS -m 5 -o /dev/null "http://127.0.0.1${HEALTH_PATH}"; then
    log_ok "API respondendo em ${HEALTH_PATH}"
  else
    log_error "API não respondeu em ${HEALTH_PATH}"; falhas=1
  fi

  echo "──────── primeiros registros do monitor neste boot ────────"
  journalctl -b -u "$MON" -n 5 --no-pager -o short-iso || true
  resultado "$falhas" "ambiente voltou sozinho após a reinicialização"
}

# ---------------------------------------------------------------- execução
require_root
log_init
enable_error_trap

declare -A TESTES=(
  [servico]=teste_servico [start-stop]=teste_start_stop [api]=teste_api
  [cpu]=teste_cpu [memoria]=teste_memoria [disco]=teste_disco
  [erro]=teste_erro [limite]=teste_limite [pos-reboot]=teste_pos_reboot
)
ORDEM_TODOS=(servico start-stop api cpu memoria disco erro limite)

alvo="${1:-}"
if [[ -z "$alvo" || "$alvo" == "-h" || "$alvo" == "--help" ]]; then uso; exit 0; fi

if [[ "$alvo" == "todos" ]]; then
  reprovados=0
  for t in "${ORDEM_TODOS[@]}"; do
    log_info "=================== TESTE: ${t} ==================="
    "${TESTES[$t]}" || reprovados=$(( reprovados + 1 ))
  done
  LOG_STEP="resumo"
  if (( reprovados == 0 )); then log_ok "Todos os ${#ORDEM_TODOS[@]} testes aprovados"
  else log_error "${reprovados} teste(s) reprovado(s) — veja /var/log/refresca/tests/errors.log"; exit 1; fi
elif [[ -n "${TESTES[$alvo]:-}" ]]; then
  log_info "=================== TESTE: ${alvo} ==================="
  "${TESTES[$alvo]}"
else
  echo "Teste desconhecido: ${alvo}" >&2; uso; exit 2
fi
