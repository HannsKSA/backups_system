#!/bin/bash

# Este script realiza un backup de la base de datos y el filestore de Odoo
# en un entorno Docker Compose y los guarda en /backups
# ======================================================================
# 0. CONFIGURACIÓN DEL CRON (Hora definida por TIME_GMT en el .env)
# ======================================================================

set -e # Detener el script inmediatamente si algún comando falla
set -a
# 🛑 ATENCIÓN: Solo se LEE de /srv/prod/.env (TIME_GMT, credenciales, INSTANCE), NUNCA se ESCRIBE en él.
source /srv/.env 
set +a

# Define la ruta ABSOLUTA del script.
SCRIPT_PATH="$(readlink -f "$0")"

# --- CÁLCULO DINÁMICO DE LA HORA CRON LOCAL BASADO EN TIME_GMT ---
if [ -z "$TIME_GMT" ]; then
    # Default to 03:00 local if not set
    CRON_HOUR="3"
    CRON_MINUTE="0"
else
    # Convierte la hora GMT deseada (Ej: "03:00:00 GMT+4") a la hora local del servidor.
    LOCAL_DATE_TIME=$(date -d "$TIME_GMT" +"%H:%M")
    CRON_HOUR=$(echo $LOCAL_DATE_TIME | cut -d: -f1)
    CRON_MINUTE=$(echo $LOCAL_DATE_TIME | cut -d: -f2)
fi

# Define la línea de CRON deseada
CRON_JOB="$CRON_MINUTE $CRON_HOUR * * * bash $SCRIPT_PATH >> /var/log/backup_cron.log 2>&1"

# Búsqueda y actualización de la línea CRON
if ! crontab -l 2>/dev/null | grep -Fq "$SCRIPT_PATH" ; then
    echo "⚠️ Actualizando tarea cron: $CRON_JOB"
    (crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" || true) | crontab - 2>/dev/null
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
fi

# ======================================================================
# 1. CONFIGURACIÓN INICIAL
# ======================================================================

PROJECT_ROOT="/srv"
DB_CONTAINER="${INSTANCE}_postgres"
OD_CONTAINER="${INSTANCE}_odoo"
DB_NAME="${POSTGRES_DBNAME}" 
DB_USER="${POSTGRES_USER}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S") 
BACKUP_DIR="/backups"

# Rutas ABSOLUTAS de los volúmenes en el Host
ODOO_FILESTORE_ROOT="${PROJECT_ROOT}/data/odoo/web-data" 
ODOO_ADDONS_PATH="${ODOO_FILESTORE_ROOT}/addons" 
SQL_FILE="${BACKUP_DIR}/${DB_NAME}_${TIMESTAMP}.sql"
FILESTORE_TAR="${BACKUP_DIR}/${DB_NAME}_filestore_${TIMESTAMP}.tar.gz"
FINAL_BACKUP_TAR="${BACKUP_DIR}/${DB_NAME}_full_${TIMESTAMP}.tar.gz"

echo "Iniciando proceso de respaldo para la DB: $DB_NAME en $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# ======================================================================
# 2. RESPALDO DE LA BASE DE DATOS (POSTGRES)
# ======================================================================
echo "Respaldando base de datos Odoo..."
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" > "$SQL_FILE"

# ======================================================================
# 3. RESPALDO DEL FILESTORE
# ======================================================================
echo "Comprimiendo el filestore..."
tar -czf "$FILESTORE_TAR" -C "$ODOO_FILESTORE_ROOT" filestore

# ======================================================================
# 4. EMPAQUETADO FINAL (SQL + FILESTORE)
# ======================================================================
echo "Creando archivo de respaldo final unificado: $FINAL_BACKUP_TAR"
tar -czf "$FINAL_BACKUP_TAR" -C "$BACKUP_DIR" "$(basename "$SQL_FILE")" "$(basename "$FILESTORE_TAR")"

# Limpieza de archivos temporales
rm -f "$SQL_FILE" "$FILESTORE_TAR"

# ======================================================================
# 5. RETENCIÓN Y LIMPIEZA LOCAL
# ======================================================================
# Mantener últimos 14 días
find "$BACKUP_DIR" -type f -name "*_full_*.tar.gz" -mtime +14 -delete
echo "✅ Respaldo completado: $FINAL_BACKUP_TAR"

# ======================================================================
# 6. TRANSFERENCIA
# ======================================================================

# Creando archivo temporal para pasar variables (compatibilidad)
TEMP_VAR_FILE="${BACKUP_DIR}/transfer_vars.tmp"
cat << EOF > "$TEMP_VAR_FILE"
BACKUP_DIR="$BACKUP_DIR"
FINAL_BACKUP_NAME="$(basename "$FINAL_BACKUP_TAR")"
EOF

echo "Iniciando proceso de transferencia..."
# Usamos ruta absoluta y la corrección del nombre
TRANSFER_SCRIPT="/srv/scripts/backups/transfer.sh"

if [ -f "$TRANSFER_SCRIPT" ]; then
    bash "$TRANSFER_SCRIPT" "$TEMP_VAR_FILE"
    TRANSFER_STATUS=$?
    
    if [ $TRANSFER_STATUS -eq 0 ]; then
        echo "✅ Proceso de transferencia completado exitosamente."
    else
        echo "❌ ADVERTENCIA: El script de transferencia falló ($TRANSFER_STATUS)."
    fi
else
    echo "⚠️ Script de transferencia no encontrado en $TRANSFER_SCRIPT. Saltando upload."
fi

rm -f "$TEMP_VAR_FILE"
