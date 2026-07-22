# docker-redis

Container Redis 8.6 para produção, configurado para servir múltiplos projetos Laravel (cache, sessions, queues) em um servidor compartilhado.

## Estrutura

```
docker-redis/
├── data/                  # dados do Redis — dump.rdb + appendonlydir/ (gerado automaticamente, não versionado)
├── backups/               # snapshots diários (gerado automaticamente, não versionado)
├── compose.yml
├── compose.dev.yml        # override opcional p/ dev em Windows/WSL2 (ver seção abaixo)
├── redis.conf
├── backup.sh              # gera snapshot via BGSAVE, comprime e verifica integridade
└── restore.sh             # restaura um backup
```

## Requisitos

- Docker e Docker Compose instalados
- Rede externa `infra` criada:
  ```bash
  docker network create infra
  ```

## Instalação

**1. Copiar o arquivo de variáveis de ambiente:**
```bash
cp .env.example .env
```

**2. Definir a senha no `.env`:**
```
REDIS_PASSWORD=senha_forte_aqui
REDIS_MAXMEMORY=512mb
```

**3. Subir o container:**
```bash
docker compose up -d
```

## Persistência

O `redis.conf` habilita RDB (snapshots periódicos, `save 3600 1` / `300 100` / `60 10000`) e AOF (`appendonly yes`, `appendfsync everysec`) simultaneamente:

- **RDB** cobre disaster recovery rápido (arquivo único, restore instantâneo).
- **AOF** cobre durabilidade fina para sessions e queues (no máximo 1s de escrita perdida em caso de crash).

Na inicialização, se o AOF existir, ele tem prioridade sobre o RDB — é por isso que o `restore.sh` move o AOF para o lado antes de aplicar um `.rdb` restaurado (ver seção Backup).

## Backup

**Executar manualmente:**
```bash
./backup.sh
```

Dispara um `BGSAVE` (snapshot em background, não bloqueia o Redis), espera o fork terminar e comprime o `dump.rdb` resultante, com integridade verificada (`gzip -t`) antes de ser aceito:

- `backups/redis-YYYY-MM-DD_HH-MM-SS.rdb.gz`

O resultado é registrado em `backups/backup.log`. Backups com mais de 7 dias são removidos automaticamente. Se o `BGSAVE` não terminar em 5 minutos ou o dump sair corrompido, o backup é descartado e o erro fica registrado no log.

> O AOF não entra no backup: ele é um durabilidade de curtíssimo prazo (append contínuo), não um artefato de disaster recovery. O RDB do `BGSAVE` já reflete o dataset completo no momento do snapshot.

**Agendar via cron (recomendado — diariamente às 3h):**
```bash
crontab -e
```
```
0 3 * * * /caminho/para/docker-redis/backup.sh
```

**Restaurar um backup:**
```bash
./restore.sh backups/redis-2026-01-01_03-00-00.rdb.gz
```

O script valida o `.gz`, pede confirmação explícita (`sim`), para o container, move o AOF existente para o lado (`appendonlydir.bak-<data>`, não apaga), aplica o `dump.rdb` restaurado, reinicia o container e reconstrói o AOF a partir do dataset restaurado (`BGREWRITEAOF`) para RDB e AOF ficarem consistentes de novo.

## Logs

Não há arquivos de log em disco (sem bind mount, sem logrotate, sem depender de permissão/UID do host):

- **Log do Redis** → vai para stderr do container, veja com `docker logs redis` (ou `docker logs -f redis` para acompanhar em tempo real). A rotação é feita pelo próprio Docker (`compose.yml`, driver `json-file`, `max-size: 20m`, `max-file: 10` → até 200MB, sem exigir passo nenhum no host).
- **Slow log** → grava em memória (`slowlog-log-slower-than 10000` = 10ms, `slowlog-max-len 128` no `redis.conf`), consulte com:
  ```bash
  docker exec redis redis-cli SLOWLOG GET
  ```
- **Latency monitor** → `latency-monitor-threshold 100` (eventos ≥100ms), consulte com:
  ```bash
  docker exec redis redis-cli LATENCY HISTORY event
  ```

## Acesso remoto

A porta 6379 não é exposta publicamente. Para conectar via RedisInsight, TablePlus ou `redis-cli` a partir da sua máquina local, use um túnel SSH:

```bash
ssh -L 6379:127.0.0.1:6379 usuario@ip-do-servidor
```

Em seguida conecte na ferramenta apontando para `127.0.0.1:6379` (algumas ferramentas têm suporte nativo a túnel SSH na própria tela de conexão, sem precisar rodar o comando acima manualmente).

## Ambiente de desenvolvimento (Windows/WSL2)

Em Windows com Docker Engine nativo dentro do WSL2 (sem Docker Desktop), a publicação em `127.0.0.1:6379:6379` do `compose.yml` — pensada para produção — impede o acesso a partir do Windows (ex: RedisInsight rodando no host). Isso acontece porque o "localhost forwarding" automático do WSL2 é pouco confiável quando o processo escuta estritamente em `127.0.0.1` dentro da distro, em vez de `0.0.0.0`.

A correção fica isolada em `compose.dev.yml` (publica em todas as interfaces) e só é aplicada se você ativar explicitamente — nunca em produção. No `.env` da máquina de desenvolvimento:

```
COMPOSE_FILE=compose.yml:compose.dev.yml
```

Com isso, `docker compose up -d` já mescla os dois arquivos automaticamente, e o RedisInsight no Windows conecta direto em `localhost:6379`, sem túnel SSH (mesma máquina).

Não é risco de segurança: a rede NAT padrão do WSL2 só é alcançável a partir da própria máquina Windows, então o efeito prático é equivalente ao loopback usado em produção.

## Configuração

### Limites de recursos (`compose.yml`)

| Parâmetro | Valor | Critério |
|---|---|---|
| `memory` | `1G` | `REDIS_MAXMEMORY` (512mb) + margem para o copy-on-write do fork durante `BGSAVE`/AOF rewrite |
| `cpus` | `1` | Redis é single-threaded para comandos; 1 core cobre o processo principal + I/O threads em background |

Ajuste `REDIS_MAXMEMORY` no `.env` conforme o hardware disponível e o que mais divide a RAM do host — se aumentar o `REDIS_MAXMEMORY`, aumente também o `memory` do `compose.yml` na mesma proporção (regra prática: ~2x o `REDIS_MAXMEMORY`).

### Segurança (`redis.conf`)

Comandos desabilitados via `rename-command`:

| Comando | Motivo |
|---|---|
| `FLUSHALL` | Apagaria todos os bancos (cache + sessions + queues) de uma vez |
| `DEBUG` | Expõe internals do processo |
| `KEYS` | O(N) sem limite; use `SCAN` em produção |
| `SHUTDOWN` | O container é encerrado pelo Docker |

`FLUSHDB` continua habilitado — age apenas no banco selecionado pela conexão. Configure o Laravel com bancos separados (ex: DB 1 para cache) para que `php artisan cache:clear` nunca toque sessions (DB 0) ou queues (DB 2).

### Eviction (`redis.conf`)

`maxmemory-policy noeviction` — ao atingir `REDIS_MAXMEMORY`, o Redis rejeita novas escritas em vez de descartar chaves silenciosamente. Adequado quando sessions/queues não podem ser perdidas; se o uso for majoritariamente cache, considere `allkeys-lru`.

## Rede

Todos os containers dos projetos Laravel devem estar na rede `infra` para se comunicar com o Redis pelo nome `redis`.
