# Refresca SP — Infraestrutura Linux ☀️💧

**Global Solution 2026 · Operating Systems (Linux) · Tema: CitizenTech**

Infraestrutura automatizada para hospedar a **API de Pontos de Refúgio** do Refresca SP, desenvolvida em C#/.NET na disciplina de C# Software Development ([repositório](https://github.com/NicolasABorges/RefrescaSP)). O Refresca SP é um ecossistema que alerta idosos e trabalhadores de rua sobre ondas de calor e indica pontos de hidratação e sombra.

Todo o ambiente é provisionado por scripts Bash, sem configuração manual no sistema operacional: hostname, rede, DNS, pacotes, usuários, permissões, firewall, aplicação, serviços systemd, monitoramento, logs e testes de falha.

## Integrantes

| Nome | RM |
|---|---|
| Gustavo Atanazio | RM559098 |
| Nicolas Aquino | RM556617 |
| Matheus Vinicius | RM555177 |
| Igor Soos | RM556010 |
| Gustavo Coelho | RM556289 |

**Vídeo demonstrativo:** _link do vídeo_

---

## Arquitetura

```mermaid
flowchart LR
    U[Navegador / curl] -->|HTTP :80| FW[ufw<br/>22 e 80 liberadas]
    FW --> NG[nginx<br/>proxy reverso]
    NG -->|127.0.0.1:5000| API[refresca-api.service<br/>ASP.NET Core .NET 10<br/>usuário: refresca]
    API --> DB[(SQLite<br/>/var/lib/refresca)]
    GH[GitHub<br/>repositório C#] -.git clone + dotnet test + publish.-> API
    MON[refresca-monitor.service<br/>monitor.sh --daemon<br/>usuário: refresca-mon] -->|/proc| SO[CPU · RAM · Disco]
    MON -->|/api/refugios| NG
    MON --> LOGS[/var/log/refresca/]
    API -.falha definitiva.-> FAIL[refresca-failure@.service<br/>OnFailure=]
    MON -.falha definitiva.-> FAIL
    FAIL --> LOGS
```

| Item | Valor |
|---|---|
| Plataforma | Azure for Students — VM Linux com 8 GiB de RAM (região Brazil South) |
| Sistema | Ubuntu Server 24.04 LTS |
| Hostname / FQDN | `refresca-srv01` / `refresca-srv01.refresca.local` |
| Rede | `eth0` — IP fixo `172.16.0.4/24`, gateway `172.16.0.1` |
| DNS | `168.63.129.16` (Azure) e `1.1.1.1` (reserva), domínio de busca `refresca.local` |
| Aplicação | API REST de Pontos de Refúgio (ASP.NET Core .NET 10 + EF Core + SQLite), exposta pelo nginx na porta 80 |

## Estrutura do repositório

```
refresca-sp-infra/
├── setup.sh                     # orquestrador: executa todas as etapas em ordem, com log
├── config/refresca.conf         # configuração central (rede, usuários, limites)
├── lib/
│   ├── logging.sh               # log padronizado: quando | onde | script | nível | etapa | resultado
│   └── common.sh                # carrega configuração e biblioteca em todos os scripts
├── provision/
│   ├── 01-hostname.sh           # hostname, FQDN, /etc/hosts, fuso horário, cloud-init
│   ├── 02-network.sh            # IP fixo, gateway e DNS via netplan (com rollback automático)
│   ├── 03-packages.sh           # atualização do sistema e dependências (registradas em install.log)
│   ├── 04-users-dirs.sh         # usuários de serviço, grupo, diretórios, sudo restrito, logrotate
│   ├── 05-swap.sh               # memória de troca (proteção contra o OOM killer)
│   └── 06-firewall.sh           # ufw: nega entrada, libera 22 e 80
├── app/
│   ├── nginx-refresca.conf      # proxy reverso
│   └── deploy-app.sh            # .NET, git clone, testes, publish, variáveis, nginx e serviço
├── systemd/
│   ├── refresca-api.service     # serviço da aplicação
│   ├── refresca-monitor.service # serviço de monitoramento
│   └── refresca-failure@.service# registro de falha definitiva (OnFailure=)
├── monitor/
│   ├── monitor.sh               # coleta de CPU, RAM, disco e saúde da API, com alertas
│   └── install-monitor.sh       # instala o monitor como serviço
├── tools/
│   ├── status.sh                # painel "refresca-status"
│   └── registrar-falha.sh       # chamado pelo systemd quando uma unidade falha
├── tests/falhas.sh              # simulações de falha e verificação da recuperação
└── evidencias/                  # capturas de tela organizadas por requisito
```

---

## Como reproduzir o ambiente

### 1. Pré-requisitos (feitos uma vez, no portal do Azure)

Estes ajustes são na plataforma de nuvem, fora do sistema operacional:

1. Criar a VM Ubuntu Server 24.04 com acesso SSH por chave (usuário `azureuser`).
2. **Fixar o IP privado:** VM → Rede → placa de rede → Configurações de IP → `ipconfig1` → Alocação **Estática** (`172.16.0.4`).
3. **Liberar a porta 80 no NSG:** VM → Rede → Adicionar regra de porta de entrada → TCP 80.

> Em outra VM ou no VirtualBox, ajuste o bloco de **rede** em `config/refresca.conf` com os valores de `ip -br a` e `ip route`.

### 2. Copiar o repositório para a VM

```bash
# opção A — pelo GitHub (dentro da VM)
git clone https://github.com/<usuario>/refresca-sp-infra.git
cd refresca-sp-infra

# opção B — do Windows, pelo PowerShell
scp -i $HOME\.ssh\vm-refresca-sp.pem -r .\refresca-sp-infra azureuser@<IP_PUBLICO>:~/
```

### 3. Executar o provisionamento

```bash
sudo bash setup.sh
```

O script executa as 8 etapas em ordem, registra cada uma e termina com um resumo. Cada etapa é idempotente: rodar de novo não quebra nada. Também é possível executar etapas isoladas:

```bash
sudo bash setup.sh --list         # lista as etapas
sudo bash setup.sh 03 app         # executa só pacotes e aplicação
```

Ao final, **saia e entre de novo no SSH** para que o `azureuser` passe a fazer parte do grupo `refresca-ops`.

### 4. Validar

```bash
refresca-status                                     # painel geral
curl -s http://api.refresca.local/api/refugios | jq                 # pelo nome local
curl -s "http://api.refresca.local/api/refugios?disponivel=true" | jq
```

No navegador: `http://<IP_PUBLICO>/swagger` (Swagger da API).

---

## Detalhes da solução

### Rede e DNS

O `02-network.sh` gera um netplan com IP fixo, rota padrão e DNS. Para não perder o acesso SSH, ele:

1. só aplica se o IP atual for igual ao configurado;
2. faz backup em `/var/backups/refresca/`;
3. valida a sintaxe (`netplan generate`) antes de aplicar;
4. testa IP, rota, resolução DNS, saída para a internet e resolução local;
5. faz **rollback automático** se qualquer teste falhar.

No Azure, a interface é identificada por MAC e driver (`hv_netvsc`), para não afetar a interface auxiliar da Accelerated Networking (`enP*`), que tem o mesmo MAC. O cloud-init é instruído a não sobrescrever hostname, `/etc/hosts` e rede no boot.

### Implantação da aplicação

O `deploy-app.sh` monta a aplicação a partir do código-fonte, sem nenhum binário copiado à mão:

1. instala o SDK do .NET 10 em `/opt/dotnet` pelo instalador oficial da Microsoft;
2. clona o repositório da API C# em `/opt/refresca/src` (ou atualiza, se já existir) e registra o commit implantado no `install.log`;
3. roda os testes unitários do projeto (`dotnet test`) — se algum falhar, a implantação é interrompida e a versão anterior continua no ar;
4. publica em modo Release em `/opt/refresca/api`;
5. configura a aplicação por variáveis de ambiente (`/etc/refresca/refresca.env`), sem alterar o código: ambiente `Production`, endereço `127.0.0.1:5000` e banco em `/var/lib/refresca/refresca-sp.db`.

Para implantar uma nova versão depois de um `git push` no repositório da API: `sudo bash setup.sh app`.

### Usuários e permissões

| Usuário / grupo | Função | Acesso |
|---|---|---|
| `refresca` | executa a API | sem shell; lê o código, escreve só no banco e no próprio log |
| `refresca-mon` | executa o monitoramento | sem shell; escreve só nos logs de monitoramento |
| `refresca-ops` | operadores (inclui `azureuser`) | lê os logs; inicia/para/reinicia os serviços `refresca-*` via sudo restrito |

| Caminho | Dono | Modo | Conteúdo |
|---|---|---|---|
| `/opt/dotnet` | `root:root` | 755 | SDK e runtime do .NET |
| `/opt/refresca/src` | `root:root` | 755 | código-fonte clonado do GitHub |
| `/opt/refresca/api` | `root:refresca` | 750 | aplicação publicada (somente leitura para o serviço) |
| `/var/lib/refresca` | `refresca:refresca` | 750 | banco SQLite |
| `/etc/refresca/refresca.env` | `root:refresca` | 640 | variáveis de ambiente da API |
| `/var/log/refresca/*` | por componente, grupo `refresca-ops` | 2750 | logs |

As units systemd também usam endurecimento (`ProtectSystem=strict`, `NoNewPrivileges`, `PrivateTmp`), então cada serviço só consegue escrever nos caminhos que precisa.

### Monitoramento

O `monitor.sh` lê as métricas diretamente do kernel (`/proc/stat`, `/proc/meminfo`) e do `df`, e verifica se a API responde em `/api/refugios`.

| Recurso | Alerta | Crítico |
|---|---|---|
| CPU | 80% | 95% |
| Memória RAM | 80% | 95% |
| Disco `/` | 85% | 95% |
| API | — | serviço parado ou sem resposta HTTP |

Cada verificação gera uma linha em `monitor.log`. Quando um limite é ultrapassado, o alerta vai para `alerts.log`; quando o recurso volta ao normal, é registrado um evento **NORMALIZADO**. Os limites ficam em `config/refresca.conf`.

O serviço `refresca-monitor.service`:

- inicia com o sistema (`WantedBy=multi-user.target`);
- executa a verificação a cada 15 segundos;
- registra início, parada e cada ciclo;
- **se for interrompido, o systemd o reinicia em 5s** (`Restart=always`);
- se cair mais de 5 vezes em 5 minutos, entra em `failed` e o `OnFailure=` registra a falha em `servicos-falhas.log`.

```bash
sudo systemctl start|stop|restart|status refresca-monitor
journalctl -u refresca-monitor -f
```

### Logs e auditoria

Todas as linhas seguem o formato `QUANDO | HOST | SCRIPT | NÍVEL | ETAPA | O QUÊ e RESULTADO`.

| Arquivo | Conteúdo |
|---|---|
| `/var/log/refresca/provision/provision.log` | cada etapa do provisionamento: início, saída completa, duração e resultado |
| `/var/log/refresca/provision/install.log` | pacotes e bibliotecas instalados, com versão |
| `/var/log/refresca/provision/errors.log` | falhas do provisionamento |
| `/var/log/refresca/monitor/monitor.log` | cada verificação de recursos, início e parada do serviço |
| `/var/log/refresca/monitor/alerts.log` | alertas de consumo elevado e normalizações |
| `/var/log/refresca/monitor/errors.log` | erros do próprio monitor |
| `/var/log/refresca/app/api.log` | log da API (inicialização, banco, requisições e erros do ASP.NET Core) |
| `/var/log/refresca/servicos-falhas.log` | unidades que entraram em `failed`, com trecho do journal |
| `/var/log/refresca/tests/tests.log` | resultado de cada teste de falha |

Os logs são rotacionados semanalmente pelo `logrotate`, mantendo 4 semanas.

---

## Testes de falha

```bash
sudo bash tests/falhas.sh <teste>
```

| Teste | O que simula | Resultado esperado |
|---|---|---|
| `servico` | `kill -9` no processo do monitor | systemd reinicia em 5s com novo PID |
| `start-stop` | parar, iniciar e reiniciar o serviço | serviço obedece e registra cada evento |
| `api` | parada da aplicação | monitor registra CRITICO e depois NORMALIZADO |
| `cpu` | 100% de CPU com `stress-ng` | ALERTA/CRITICO e depois NORMALIZADO |
| `memoria` | alocação de ~90% da memória | ALERTA e depois NORMALIZADO |
| `disco` | arquivo temporário até ~88% do disco | ALERTA e depois NORMALIZADO (arquivo removido) |
| `erro` | falha controlada no `monitor.sh` | sai com erro e registra linha e comando em `errors.log` |
| `limite` | quedas repetidas até esgotar as tentativas | unidade em `failed`, registro via `OnFailure=`, recuperação |
| `pos-reboot` | rodar após `sudo reboot` | serviços, hostname, IP e swap voltam sozinhos |
| `todos` | todos acima, exceto `pos-reboot` | resumo de aprovados e reprovados |

---

## Referência: API de Pontos de Refúgio (Contrato 3)

| Método | Rota | Descrição |
|---|---|---|
| GET | `/api/refugios?tipo=AguaESombra&disponivel=true` | lista os pontos, com filtros opcionais |
| GET | `/api/refugios/{id}` | busca um ponto |
| POST | `/api/refugios` | cadastra um ponto |
| PUT | `/api/refugios/{id}` | atualiza um ponto |
| DELETE | `/api/refugios/{id}` | remove um ponto |

```json
{
  "name": "Bebedouro do Parque Trianon",
  "type": "AguaESombra",
  "address": { "cep": "01310-100", "streetName": "Rua Peixoto Gomide", "number": 949 },
  "distanceMeters": 200,
  "isOpen": true,
  "description": "Bebedouro próximo à área arborizada do parque."
}
```

Tipos aceitos: `Agua`, `Sombra`, `AguaESombra` e `TendaApoio`. O banco é criado e populado com pontos de exemplo na primeira inicialização. Detalhes no [repositório da API](https://github.com/NicolasABorges/RefrescaSP).
