#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/.env"

BACKUP_DIR="${SCRIPT_DIR}/backups"
DATE=$(date +%F_%H-%M-%S)
RETENTION_DAYS=7
LOG_FILE="${BACKUP_DIR}/backup.log"
TIMEOUT_SECONDS=300

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "${LOG_FILE}"
}

mkdir -p "${BACKUP_DIR}"

# Dispara o snapshot em background e espera terminar (sem bloquear o Redis,
# ao contrário de SAVE). rdb_bgsave_in_progress volta a 0 quando o fork termina.
docker exec redis redis-cli BGSAVE > /dev/null

ELAPSED=0
while [ "$(docker exec redis redis-cli INFO persistence | grep -c 'rdb_bgsave_in_progress:1')" -ne 0 ]; do
  if [ "${ELAPSED}" -ge "${TIMEOUT_SECONDS}" ]; then
    log "ERRO: BGSAVE não terminou em ${TIMEOUT_SECONDS}s, abortando backup"
    exit 1
  fi
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done

if [ "$(docker exec redis redis-cli LASTSAVE)" = "" ]; then
  log "ERRO: BGSAVE falhou (LASTSAVE vazio)"
  exit 1
fi

FILE="${BACKUP_DIR}/redis-${DATE}.rdb.gz"
if ! gzip -c "${SCRIPT_DIR}/data/dump.rdb" > "${FILE}"; then
  log "ERRO: falha ao comprimir dump.rdb"
  rm -f "${FILE}"
  exit 1
fi

if ! gzip -t "${FILE}" 2>/dev/null; then
  log "ERRO: backup corrompido (falhou gzip -t), removido: $(basename "${FILE}")"
  rm -f "${FILE}"
  exit 1
fi

log "Backup criado: $(basename "${FILE}") ($(du -h "${FILE}" | cut -f1))"

# Retenção: remove backups com mais de RETENTION_DAYS dias.
find "${BACKUP_DIR}" -name "*.rdb.gz" -mtime "+${RETENTION_DAYS}" -delete
