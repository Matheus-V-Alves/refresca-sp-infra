# Evidências técnicas

Capturas de tela organizadas por requisito do enunciado. Nomeie os arquivos com o
número da pasta para manter a ordem (ex.: `01-ambiente/01-ssh-boas-vindas.png`).

| Pasta | O que capturar | Comando sugerido |
|---|---|---|
| `01-ambiente/` | VM criada no portal, conexão SSH, SO e systemd como PID 1 | `cat /etc/os-release`, `ps -p 1 -o comm=` |
| `02-provisionamento/` | Execução do `setup.sh` e o resumo final | `sudo bash setup.sh` |
| `03-rede-dns/` | Hostname, IP fixo, rota, DNS e resolução de nomes | `hostnamectl`, `ip -br a`, `ip route`, `resolvectl status`, `getent hosts api.refresca.local` |
| `04-usuarios-permissoes/` | Usuários de serviço, grupo e permissões dos diretórios | `id refresca`, `ls -ld /opt/refresca/* /var/log/refresca/*`, `sudo -l` |
| `05-aplicacao/` | `dotnet test` aprovado, API rodando: Swagger no navegador e chamadas via curl | `curl -s http://api.refresca.local/api/refugios \| jq` |
| `06-servicos-systemd/` | Status, habilitação no boot e start/stop/restart | `systemctl status refresca-api refresca-monitor`, `refresca-status` |
| `07-monitoramento/` | Linhas de verificação e alertas | `tail -f /var/log/refresca/monitor/monitor.log` |
| `08-logs/` | Logs de provisionamento, instalações e erros | `cat /var/log/refresca/provision/install.log` |
| `09-testes-falha/` | Saída de cada teste de `tests/falhas.sh` | `sudo bash tests/falhas.sh <teste>` |
| `10-reboot/` | Ambiente voltando sozinho após reinicialização | `sudo bash tests/falhas.sh pos-reboot` |
