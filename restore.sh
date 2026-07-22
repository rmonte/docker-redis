#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/.env"

usage() {
  echo "Uso: ./restore.sh <arquivo.rdb.gz>"
  echo
  echo "Exemplo:"
  echo "  ./restore.sh backups/redis-2026-07-21_03-00-00.rdb.gz"
  exit 1
}

[ -z "${1:-}" ] && usage
FILE="$1"

[ -f "${FILE}" ] || { echo "Erro: arquivo não encontrado: ${FILE}"; exit 1; }

if ! gzip -t "${FILE}" 2>/dev/null; then
  echo "Erro: arquivo corrompido ou não é um .gz válido: ${FILE}"
  exit 1
fi

echo "Este backup vai SOBRESCREVER todos os dados atuais do Redis com o conteúdo de:"
echo "  ${FILE}"
read -rp "Confirma? Digite 'sim' para continuar: " CONFIRM
[ "${CONFIRM}" = "sim" ] || { echo "Cancelado."; exit 1; }

DATA_DIR="${SCRIPT_DIR}/data"

echo "Parando o container..."
docker compose -f "${SCRIPT_DIR}/compose.yml" stop redis

# Com appendonly=yes, o Redis carrega o dataset a partir do appendonlydir/
# (base + incr conforme o manifest) e ignora um dump.rdb solto em /data — por
# isso o backup precisa entrar como o "base file" de um AOF novo, com o
# formato exato que o próprio Redis usa (visto em appendonlydir/*.manifest).
if [ -d "${DATA_DIR}/appendonlydir" ]; then
  mv "${DATA_DIR}/appendonlydir" "${DATA_DIR}/appendonlydir.bak-$(date +%F_%H-%M-%S)"
fi

mkdir -p "${DATA_DIR}/appendonlydir"
gunzip < "${FILE}" > "${DATA_DIR}/appendonlydir/appendonly.aof.1.base.rdb"
: > "${DATA_DIR}/appendonlydir/appendonly.aof.1.incr.aof"
cat > "${DATA_DIR}/appendonlydir/appendonly.aof.manifest" <<'EOF'
file appendonly.aof.1.base.rdb seq 1 type b
file appendonly.aof.1.incr.aof seq 1 type i startoffset 0
EOF

echo "Iniciando o container com os dados restaurados..."
docker compose -f "${SCRIPT_DIR}/compose.yml" start redis

echo "Aguardando o Redis ficar saudável..."
until [ "$(docker inspect -f '{{.State.Health.Status}}' redis 2>/dev/null)" = "healthy" ]; do
  sleep 1
done

# Compacta o AOF criado manualmente no formato padrão gerenciado pelo Redis
# (nova seq, base + incr consistentes) e atualiza o dump.rdb para o mesmo estado.
docker exec redis redis-cli BGREWRITEAOF > /dev/null
docker exec redis redis-cli BGSAVE > /dev/null

echo "Restauração concluída."
