#!/bin/bash

# Este script ejecuta la transferencia del backup:
# 1. rsync para el Filestore (eficiente para grandes volúmenes y reanudación)
# 2. scp para el volcado de la DB (archivo único).
# Se espera que este script sea llamado con 'nohup' para evitar caídas.

# ======================================================================
# 1. CONFIGURACIÓN Y CARGA DE VARIABLES
# ======================================================================

set -e # Detener el script si algún comando falla

# Cargar variables del .env para obtener INSTANCE, etc.
set -a
source /srv/.env 
set +a

# Argumentos pasados por backups.sh:
BACKUP_DIR="$1"         # /backups
SQL_FILE_PATH="$2"      # /backups/db_name_db_timestamp.sql.gz
FILESTORE_LOCAL_PATH="$3" # /srv/data/odoo/web-data/filestore

# Si algún argumento falta, salir
if [ -z "$FILESTORE_LOCAL_PATH" ]; then
    echo "❌ ERROR CRÍTICO: Argumentos de ruta incompletos. Terminando."
    exit 1
fi

LOG_FILE="${BACKUP_DIR}/backup_log.txt"

# ======================================================================
# 2. DEFINICIÓN DE PARÁMETROS DE TRANSFERENCIA
# ======================================================================

# Parámetros remotos
SSH_USER="u502156"
SSH_HOST="u502156.your-storagebox.de"
SSH_PORT="23"
SSH_KEY="/root/.ssh/id_backups" 

# Ruta base en el servidor remoto
REMOTE_BASE_PATH="/home/vps"
REMOTE_PROJECT_PATH="${REMOTE_BASE_PATH}/${INSTANCE}"

# Rutas de destino remotas específicas
REMOTE_FILESTORE_PATH="${REMOTE_PROJECT_PATH}/filestore" # Carpeta para el filestore
REMOTE_DB_DIR="${REMOTE_PROJECT_PATH}/db_dumps" # Carpeta para las bases de datos

# ======================================================================
# 3. VERIFICACIÓN Y PREPARACIÓN REMOTA
# ======================================================================

echo "==========================================================" >> "$LOG_FILE"
echo "🔄 INICIO DE TRANSFERENCIA REMOTA: $(date)" >> "$LOG_FILE"
echo "==========================================================" >> "$LOG_FILE"
echo "Creando directorios remotos necesarios..." >> "$LOG_FILE"

# Comando SSH para ejecutar la creación de directorios
SSH_COMMAND="mkdir -p ${REMOTE_FILESTORE_PATH} ${REMOTE_DB_DIR}"

ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "$SSH_COMMAND"
if [ $? -ne 0 ]; then
    echo "❌ ERROR: Fallo al conectar o crear los directorios remotos. Terminando transferencia." >> "$LOG_FILE"
    exit 1
fi
echo "✅ Directorios remotos verificados/creados." >> "$LOG_FILE"


# ======================================================================
# 4. TRANSFERENCIA DEL FILESTORE (RSYNC)
# ======================================================================

echo "" >> "$LOG_FILE"
echo "📁 Iniciando RSYNC para Filestore (Solo transferirá archivos nuevos o modificados)..." >> "$LOG_FILE"

# Opciones de rsync:
# -a: modo archivo (preserva permisos, fechas, es recursivo)
# -z: compresión de datos durante la transferencia (reduce ancho de banda)
# -v: verbose (para ver progreso en el log)
# --delete: Elimina archivos en el destino que ya no existen en el origen (Sincronización total)
rsync -azv --delete -e "ssh -p $SSH_PORT -i $SSH_KEY" \
    "${FILESTORE_LOCAL_PATH}/" \
    "${SSH_USER}@${SSH_HOST}:${REMOTE_FILESTORE_PATH}/"

if [ $? -eq 0 ]; then
    echo "✅ RSYNC del Filestore completado exitosamente." >> "$LOG_FILE"
else
    echo "❌ ERROR: Fallo en la transferencia RSYNC. Continuará con la transferencia de DB." >> "$LOG_FILE"
fi


# ======================================================================
# 5. TRANSFERENCIA DE LA BASE DE DATOS (SCP)
# ======================================================================

echo "" >> "$LOG_FILE"
echo "📦 Iniciando SCP para el volcado de la base de datos (.sql.gz)..." >> "$LOG_FILE"

DB_FILENAME=$(basename "$SQL_FILE_PATH")

scp -P "$SSH_PORT" -i "$SSH_KEY" "$SQL_FILE_PATH" "$SSH_USER@$SSH_HOST":"${REMOTE_DB_DIR}/${DB_FILENAME}"

if [ $? -eq 0 ]; then
    echo "✅ Transferencia SCP de DB completada exitosamente." >> "$LOG_FILE"
    
    # ======================================================================
    # LIMPIEZA LOCAL
    # ======================================================================
    # Solo necesitamos limpiar los archivos únicos (.sql.gz y addons.tar.gz si existe)
    echo "🗑️ Limpiando archivos intermedios locales..." >> "$LOG_FILE"
    
    # Eliminamos el archivo SQL y cualquier archivo de addons.
    find "$BACKUP_DIR" -type f -name '*_db_*.sql.gz' -mtime -1 -delete
    find "$BACKUP_DIR" -type f -name '*_addons_*.tar.gz' -mtime -1 -delete

    echo "✅ Limpieza local completada." >> "$LOG_FILE"

else
    echo "❌ ERROR: Fallo en la transferencia SCP de DB. Los archivos locales se conservan para reintento." >> "$LOG_FILE"
    exit 1
fi

# ======================================================================
# 6. RETENCIÓN REMOTA (Limpieza de dumps de DB antiguos)
# ======================================================================

echo "" >> "$LOG_FILE"
echo "🧹 Aplicando política de retención (últimos 14 días) a los dumps de DB remotos..." >> "$LOG_FILE"

# Eliminar dumps antiguos en la carpeta de DB remota
SSH_RETENTION_COMMAND="find ${REMOTE_DB_DIR} -type f -name '*_db_*.sql.gz' -mtime +14 -delete"

ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "$SSH_RETENTION_COMMAND" 2>/dev/null

if [ $? -eq 0 ]; then
    echo "✅ Limpieza de dumps remotos completada." >> "$LOG_FILE"
else
    echo "⚠️ ADVERTENCIA: La limpieza remota falló (restricción de shell o error). Limpiar manualmente." >> "$LOG_FILE"
fi


echo "==========================================================" >> "$LOG_FILE"
echo "🏁 PROCESO DE TRANSFERENCIA FINALIZADO: $(date)" >> "$LOG_FILE"
echo "==========================================================" >> "$LOG_FILE"