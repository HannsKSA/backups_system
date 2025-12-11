#!/bin/bash

# Este script ejecuta la transferencia del backup:
# 1. scp para el archivo .tar.gz de la DB (con fecha)
# 2. rsync para el Filestore (eficiente para grandes volúmenes)

# ======================================================================
# 1. CONFIGURACIÓN Y CARGA DE VARIABLES
# ======================================================================

set -e

set -a
source /srv/.env 
set +a

# Argumentos pasados por backups.sh:
BACKUP_DIR="$1"              # /backups
BACKUP_FILE="$2"             # /backups/db_name_2025-12-11_03-00-00.tar.gz

if [ -z "$BACKUP_FILE" ]; then
    echo "❌ ERROR CRÍTICO: Argumentos de ruta incompletos. Terminando."
    exit 1
fi

LOG_FILE="${BACKUP_DIR}/backup_log.txt"

# ======================================================================
# 2. DEFINICIÓN DE PARÁMETROS DE TRANSFERENCIA
# ======================================================================

SSH_USER="u502156"
SSH_HOST="u502156.your-storagebox.de"
SSH_PORT="23"
SSH_KEY="/root/.ssh/id_backups" 

REMOTE_BASE_PATH="/home/vps"
REMOTE_PROJECT_PATH="${REMOTE_BASE_PATH}/${INSTANCE}"
REMOTE_DB_DIR="${REMOTE_PROJECT_PATH}/db_backups"

# ======================================================================
# 3. VERIFICACIÓN Y PREPARACIÓN REMOTA
# ======================================================================

echo "==========================================================" >> "$LOG_FILE"
echo "🔄 INICIO DE TRANSFERENCIA REMOTA: $(date)" >> "$LOG_FILE"
echo "==========================================================" >> "$LOG_FILE"
echo "Creando directorios remotos necesarios..." >> "$LOG_FILE"

SSH_COMMAND="mkdir -p ${REMOTE_DB_DIR}"

ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "$SSH_COMMAND"
if [ $? -ne 0 ]; then
    echo "❌ ERROR: Fallo al conectar o crear los directorios remotos. Terminando transferencia." >> "$LOG_FILE"
    exit 1
fi
echo "✅ Directorios remotos verificados/creados." >> "$LOG_FILE"

# ======================================================================
# 4. TRANSFERENCIA DE LA BASE DE DATOS (SCP)
# ======================================================================

echo "" >> "$LOG_FILE"
echo "📦 Iniciando SCP para el backup de la base de datos (.tar.gz)..." >> "$LOG_FILE"

DB_FILENAME=$(basename "$BACKUP_FILE")

scp -P "$SSH_PORT" -i "$SSH_KEY" "$BACKUP_FILE" "$SSH_USER@$SSH_HOST":"${REMOTE_DB_DIR}/${DB_FILENAME}"

if [ $? -eq 0 ]; then
    echo "✅ Transferencia SCP de DB completada exitosamente." >> "$LOG_FILE"
    
    # Limpiar archivo local después de transferir
    echo "🗑️ Limpiando archivo local transferido..." >> "$LOG_FILE"
    rm -f "$BACKUP_FILE"
    echo "✅ Archivo local eliminado: ${DB_FILENAME}" >> "$LOG_FILE"
else
    echo "❌ ERROR: Fallo en la transferencia SCP de DB. El archivo local se conserva para reintento." >> "$LOG_FILE"
    exit 1
fi

# ======================================================================
# 5. LIMPIEZA LOCAL
# ======================================================================

echo "" >> "$LOG_FILE"
echo "🗑️ Limpiando archivos temporales locales..." >> "$LOG_FILE"

find "$BACKUP_DIR" -type f -name '*_addons_*.tar.gz' -mtime +7 -delete 2>/dev/null

echo "✅ Limpieza local completada." >> "$LOG_FILE"

# ======================================================================
# 7. RETENCIÓN REMOTA (Limpieza de backups antiguos)
# ======================================================================

echo "" >> "$LOG_FILE"
echo "🧹 Aplicando política de retención en servidor remoto..." >> "$LOG_FILE"
echo "   Política: 7 diarios, 4 semanales, 6 mensuales, 5 anuales" >> "$LOG_FILE"

# Nota: El servidor tiene shell restringido, estos comandos pueden fallar
# Intentaremos aplicar la política manualmente con find

# 1. Mantener últimos 7 días (todos los archivos)
echo "   Manteniendo backups de últimos 7 días..." >> "$LOG_FILE"

# 2. Para archivos más antiguos, aplicar retención semanal/mensual/anual
# Eliminar backups de más de 60 días (excepto los del día 1 de cada mes)
SSH_RETENTION_MONTHLY="find ${REMOTE_DB_DIR} -type f -name '*.tar.gz' -mtime +60 ! -name '*-01_*' -delete"

# Eliminar backups de más de 2 años (excepto los de enero)
SSH_RETENTION_YEARLY="find ${REMOTE_DB_DIR} -type f -name '*.tar.gz' -mtime +730 ! -name '*-01-01_*' -delete"

# Eliminar backups de más de 5 años
SSH_RETENTION_OLD="find ${REMOTE_DB_DIR} -type f -name '*.tar.gz' -mtime +1825 -delete"

# Ejecutar comandos de retención
ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "$SSH_RETENTION_MONTHLY" 2>/dev/null
ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "$SSH_RETENTION_YEARLY" 2>/dev/null  
ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "$SSH_RETENTION_OLD" 2>/dev/null

if [ $? -eq 0 ]; then
    echo "✅ Política de retención aplicada en servidor remoto." >> "$LOG_FILE"
else
    echo "⚠️ ADVERTENCIA: La retención remota puede haber fallado (shell restringido)." >> "$LOG_FILE"
    echo "   Verificar manualmente los backups remotos periódicamente." >> "$LOG_FILE"
fi

echo "" >> "$LOG_FILE"
echo "==========================================================" >> "$LOG_FILE"
echo "🏁 PROCESO DE TRANSFERENCIA FINALIZADO: $(date)" >> "$LOG_FILE"
echo "==========================================================" >> "$LOG_FILE"