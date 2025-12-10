#!/bin/bash

# Este script realiza un backup de la base de datos y prepara la transferencia
# del filestore mediante rsync, lanzando el proceso de transferencia en segundo plano.

# ======================================================================
# 0. CONFIGURACIÓN DEL CRON / .ENV
# ======================================================================

set -e 
set -a
source /srv/.env 
set +a

# --- CONFIGURACIÓN DE CRON (Se mantiene igual) ---
SCRIPT_PATH="/srv/scripts/backups.sh" 
CRON_JOB="0 3 * * * bash $SCRIPT_PATH >> /var/log/backup_cron.log 2>&1"

# [Sección de verificación CRON omitida por brevedad, se mantiene la lógica anterior]

# ======================================================================
# 1. CONFIGURACIÓN INICIAL
# ======================================================================

# --- 1.1 Rutas y Nomenclatura ---
PROJECT_ROOT="/srv"
DB_CONTAINER="${INSTANCE}_postgres"
DB_NAME="${POSTGRES_DBNAME}" 
DB_USER="${POSTGRES_USER}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# DIRECTORIO DE BACKUPS LOCAL (¡Actualizado a /backups!)
BACKUP_DIR="/backups"
LOG_FILE="${BACKUP_DIR}/backup_log.txt" # <--- Archivo de log para seguimiento

# Rutas ABSOLUTAS de los volúmenes en el Host (usadas para tar/rsync)
ODOO_FILESTORE_ROOT="${PROJECT_ROOT}/data/odoo/web-data/filestore" # <-- Apuntamos directamente a 'filestore'
ODOO_ADDONS_PATH="${PROJECT_ROOT}/data/odoo/web-data/addons"

# Nombres de los archivos intermedios de salida
SQL_FILE="${BACKUP_DIR}/${DB_NAME}_db_${TIMESTAMP}.sql.gz" # <-- Nomenclatura más limpia

echo "Iniciando proceso de respaldo para la DB: $DB_NAME"
mkdir -p "$BACKUP_DIR"

# 🛑 CREAR/REESCRIBIR EL ARCHIVO DE LOG AL INICIO
echo "==========================================================" > "$LOG_FILE"
echo "🚀 INICIO DE BACKUP: $(date)" >> "$LOG_FILE"
echo "==========================================================" >> "$LOG_FILE"


# ======================================================================
# 3. RESPALDO DE LA BASE DE DATOS (POSTGRES) - OPTIMIZADO
# ======================================================================
echo "Respaldando base de datos Odoo: $DB_NAME y comprimiendo en línea en $SQL_FILE" >> "$LOG_FILE"
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" | gzip -c > "$SQL_FILE"

if [ $? -eq 0 ]; then
    echo "✅ Respaldo de la base de datos completado. Tamaño: $(du -sh "$SQL_FILE" | awk '{print $1}')" >> "$LOG_FILE"
else
    echo "❌ ERROR CRÍTICO: Fallo al respaldar la base de datos." >> "$LOG_FILE"
    exit 1
fi

# ======================================================================
# 4. OMISIÓN DE COMPRESIÓN DE FILESTORE (Se usará rsync)
# ======================================================================
echo "📁 El Filestore NO será comprimido localmente. Se usará rsync para la transferencia." >> "$LOG_FILE"
# Nota: La existencia de $ODOO_FILESTORE_ROOT es crucial para rsync.

# ======================================================================
# 5. OPCIONAL: RESPALDO DE ADDONS PERSONALIZADOS (Se mantiene localmente)
# ======================================================================
if [ -d "$ODOO_ADDONS_PATH" ]; then
    ADDONS_TAR="${BACKUP_DIR}/${DB_NAME}_addons_${TIMESTAMP}.tar.gz"
    echo "Comprimiendo addons personalizados en: $ADDONS_TAR" >> "$LOG_FILE"
    
    # Comprime solo la carpeta 'addons'
    tar -czf "$ADDONS_TAR" -C "${ODOO_FILESTORE_ROOT}/.." addons >> "$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        echo "✅ Respaldo de addons completado." >> "$LOG_FILE"
    else
        echo "⚠️ Advertencia: Error al respaldar addons." >> "$LOG_FILE"
    fi
fi


# ======================================================================
# 6. REGISTRO DE ESTADO EN .env (Se mantiene)
# ======================================================================
TIMESTAMP_FINAL=$(date +"%Y-%m-%d_%H-%M-%S") 
FINAL_BACKUP_NAME="${DB_NAME}_full_${TIMESTAMP_FINAL}.tar.gz" # Nombre genérico para el env
CURRENT_TIME_GMT=$(TZ='GMT' date +"%Y-%m-%d %H:%M:%S %Z")
DOT_ENV_PATH="/srv/.env" 
VAR_TIME="LAST_BACKUP_TIME_GMT=\"$CURRENT_TIME_GMT\""
VAR_NAME="FINAL_BACKUP_NAME=\"$FINAL_BACKUP_NAME\""

# [Sección de actualización de .env omitida por brevedad, se mantiene la lógica anterior]


# ======================================================================
# 7. LLAMADA AL SCRIPT DE TRANSFERENCIA EN SEGUNDO PLANO (NOHUP)
# ======================================================================
echo "" >> "$LOG_FILE"
echo "📤 Iniciando transferencia (rsync/scp) en SEGUNDO PLANO..." >> "$LOG_FILE"
echo "   Verifique el archivo de log: $LOG_FILE para el progreso." >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Ejecutamos el script de transferencia con 'nohup' para que continúe
# aunque se cierre la sesión SSH, y redirigimos toda la salida al LOG_FILE.
nohup bash /srv/scripts/transfer.sh "$BACKUP_DIR" "$SQL_FILE" "$ODOO_FILESTORE_ROOT" >> "$LOG_FILE" 2>&1 &

# NOTA: Este script finaliza aquí. La transferencia corre en el fondo.
echo "✅ El proceso de transferencia ha sido iniciado en segundo plano. Saliendo de la sesión SSH del cliente."