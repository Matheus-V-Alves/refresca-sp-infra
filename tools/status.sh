#!/usr/bin/env bash
# =============================================================================
# refresca-status — painel rápido do servidor Refresca SP
# Instalado em /usr/local/bin/refresca-status. Útil no vídeo e no dia a dia.
# Para ler os logs sem sudo, o usuário precisa estar no grupo refresca-ops.
# =============================================================================
set -uo pipefail

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; N=$'\e[0m'
else B=""; G=""; R=""; Y=""; N=""; fi

secao() { printf '\n%s━━ %s ━━%s\n' "$B" "$1" "$N"; }

secao "Identidade"
# shellcheck disable=SC1091
printf 'Hostname: %s | FQDN: %s | SO: %s | Kernel: %s\n' \
  "$(hostnamectl --static)" "$(hostname -f 2>/dev/null)" "$(. /etc/os-release; echo "$PRETTY_NAME")" "$(uname -r)"
printf 'Ligado desde: %s | Fuso: %s\n' "$(uptime -s)" "$(timedatectl show -p Timezone --value)"

secao "Rede"
ip -br -4 addr show | grep -v '^lo'
ip route show default
resolvectl dns 2>/dev/null | grep -v ':\s*$' || true

secao "Serviços"
for u in nginx refresca-api refresca-monitor; do
  ativo="$(systemctl is-active "$u" 2>/dev/null)"
  boot="$(systemctl is-enabled "$u" 2>/dev/null)"
  desde="$(systemctl show -p ActiveEnterTimestamp --value "$u" 2>/dev/null)"
  reinicios="$(systemctl show -p NRestarts --value "$u" 2>/dev/null)"
  cor="$G"; [[ "$ativo" == "active" ]] || cor="$R"
  printf '%-18s %s%-9s%s boot=%-9s reinícios=%-3s desde %s\n' "$u" "$cor" "$ativo" "$N" "$boot" "${reinicios:-0}" "$desde"
done

secao "Recursos"
free -h | head -n 3
df -h / | tail -n 1

HEALTH_URL="http://127.0.0.1/api/refugios"
# shellcheck disable=SC1091
[[ -r /etc/refresca/monitor.conf ]] && source /etc/refresca/monitor.conf
secao "API (${HEALTH_URL})"
codigo="$(curl -s -o /dev/null -w '%{http_code}' -m 5 "$HEALTH_URL")"
if [[ "$codigo" == "200" ]]; then
  printf '%sHTTP 200 — respondendo%s | refúgios cadastrados: %s\n' "$G" "$N" \
    "$(curl -s -m 5 "$HEALTH_URL" | jq 'length' 2>/dev/null || echo '?')"
else
  printf '%sAPI indisponível (HTTP %s)%s\n' "$R" "${codigo:-000}" "$N"
fi

secao "Monitoramento — últimas 5 verificações"
tail -n 5 /var/log/refresca/monitor/monitor.log 2>/dev/null || echo "(sem permissão: use sudo ou entre no grupo refresca-ops)"

secao "Alertas — últimos 5"
if [[ -s /var/log/refresca/monitor/alerts.log ]]; then
  tail -n 5 /var/log/refresca/monitor/alerts.log 2>/dev/null | sed "s/CRITICO/${R}CRITICO${N}/; s/ALERTA/${Y}ALERTA${N}/; s/NORMALIZADO/${G}NORMALIZADO${N}/"
else
  echo "nenhum alerta registrado (ou sem permissão de leitura)"
fi
