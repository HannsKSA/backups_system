#!/bin/bash

# Este script realiza un backup de la base de datos usando BORG BACKUP
# y prepara la transferencia del filestore mediante rsync.
# BORG ofrece: deduplicación, compresión, encriptación y backups incrementales.

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

# DIRECTORIO DE BACKUPS LOCAL (Ruta absoluta)
BACKUP_DIR="/backups"
LOG_FILE="${BACKUP_DIR}/backup_log.txt"

# Repositorio BORG local para la base de datos
BORG_REPO="${BACKUP_DIR}/borg-repo"
BORG_ARCHIVE_NAME="${DB_NAME}_${TIMESTAMP}"

# Rutas ABSOLUTAS de los volúmenes en el Host
ODOO_FILESTORE_ROOT="${PROJECT_ROOT}/data/odoo/web-data/filestore"
ODOO_ADDONS_PATH="${PROJECT_ROOT}/data/odoo/web-data/addons"

echo "Iniciando proceso de respaldo BORG para la DB: $DB_NAME"
mkdir -p "$BACKUP_DIR"

# 🛑 CREAR/REESCRIBIR EL ARCHIVO DE LOG AL INICIO
echo "==========================================================" > "$LOG_FILE"
echo "🚀 INICIO DE BACKUP CON BORG: $(date)" >> "$LOG_FILE"
echo "==========================================================" >> "$LOG_FILE"

# ======================================================================
# 2. INICIALIZACIÓN DEL REPOSITORIO BORG (si no existe)
# ======================================================================

# Desactivar la passphrase para automatización (puedes usar encriptación si lo prefieres)
export BORG_PASSPHRASE=""
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

if [ ! -d "$BORG_REPO" ]; then
    echo "📦 Inicializando repositorio BORG en: $BORG_REPO" >> "$LOG_FILE"
    borg init --encryption=none "$BORG_REPO" >> "$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        echo "✅ Repositorio BORG inicializado exitosamente." >> "$LOG_FILE"
    else
        echo "❌ ERROR: Fallo al inicializar repositorio BORG." >> "$LOG_FILE"
        exit 1
    fi
else
    echo "✅ Repositorio BORG ya existe: $BORG_REPO" >> "$LOG_FILE"
fi

# ======================================================================
# 3. RESPALDO DE LA BASE DE DATOS CON BORG (OPTIMIZADO)
# ======================================================================

echo "" >> "$LOG_FILE"
echo "🗄️ Respaldando base de datos con BORG (deduplicación + compresión)..." >> "$LOG_FILE"

# Crear directorio temporal para el dump
TEMP_DB_DIR="${BACKUP_DIR}/temp_db_dump"
mkdir -p "$TEMP_DB_DIR"

# Realizar pg_dump sin compresión (BORG se encargará de comprimir)
TEMP_SQL_FILE="${TEMP_DB_DIR}/${DB_NAME}.sql"
echo "   Generando dump SQL temporal..." >> "$LOG_FILE"
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" > "$TEMP_SQL_FILE"

if [ $? -ne 0 ]; then
    echo "❌ ERROR CRÍTICO: Fallo al generar dump de la base de datos." >> "$LOG_FILE"
    rm -rf "$TEMP_DB_DIR"
    exit 1
fi

DB_SIZE=$(du -sh "$TEMP_SQL_FILE" | awk '{print $1}')
echo "   Tamaño del dump SQL: $DB_SIZE" >> "$LOG_FILE"

# Copiar filestore al directorio temporal para incluirlo en el backup
if [ -d "$ODOO_FILESTORE_ROOT" ]; then
    echo "   Copiando filestore al backup..." >> "$LOG_FILE"
    cp -r "$ODOO_FILESTORE_ROOT" "$TEMP_DB_DIR/filestore"
    FILESTORE_SIZE=$(du -sh "$TEMP_DB_DIR/filestore" | awk '{print $1}')
    echo "   Tamaño del filestore: $FILESTORE_SIZE" >> "$LOG_FILE"
else
    echo "   ⚠️ Filestore no encontrado, solo se respaldará la DB" >> "$LOG_FILE"
fi

# Crear backup con BORG (usa compresión zstd,3 que es rápida y eficiente)
echo "   Creando archivo BORG con compresión zstd..." >> "$LOG_FILE"
borg create \
    --compression zstd,3 \
    --stats \
    --progress \
    "${BORG_REPO}::${BORG_ARCHIVE_NAME}" \
    "$TEMP_DB_DIR" >> "$LOG_FILE" 2>&1

if [ $? -eq 0 ]; then
    echo "✅ Backup BORG de la base de datos completado exitosamente." >> "$LOG_FILE"
    
    # Mostrar estadísticas del repositorio
    echo "" >> "$LOG_FILE"
    echo "📊 Estadísticas del repositorio BORG:" >> "$LOG_FILE"
    borg info "${BORG_REPO}::${BORG_ARCHIVE_NAME}" >> "$LOG_FILE" 2>&1
else
    echo "❌ ERROR CRÍTICO: Fallo al crear backup BORG." >> "$LOG_FILE"
    rm -rf "$TEMP_DB_DIR"
    exit 1
fi

# Limpiar dump temporal
rm -rf "$TEMP_DB_DIR"
echo "🗑️ Dump temporal eliminado." >> "$LOG_FILE"

# ======================================================================
# 4. EXPORTAR BACKUP COMO .TAR.GZ CON FECHA
# ======================================================================

echo "" >> "$LOG_FILE"
echo "📦 Exportando backup desde Borg como archivo .tar.gz..." >> "$LOG_FILE"

# Crear nombre de archivo con fecha específica
TIMESTAMP_FINAL=$(date +"%Y-%m-%d_%H-%M-%S")
FINAL_BACKUP_NAME="${DB_NAME}_${TIMESTAMP_FINAL}.tar.gz"
EXPORT_PATH="${BACKUP_DIR}/${FINAL_BACKUP_NAME}"

# Crear directorio temporal para exportar
TEMP_EXPORT_DIR="${BACKUP_DIR}/temp_export_$(date +%s)"
mkdir -p "$TEMP_EXPORT_DIR"

# Extraer el backup desde Borg
echo "   Extrayendo desde Borg: ${BORG_ARCHIVE_NAME}" >> "$LOG_FILE"
borg extract "${BORG_REPO}::${BORG_ARCHIVE_NAME}" -C "$TEMP_EXPORT_DIR" >> "$LOG_FILE" 2>&1

if [ $? -eq 0 ]; then
    # Comprimir como .tar.gz
    echo "   Comprimiendo como: ${FINAL_BACKUP_NAME}" >> "$LOG_FILE"
    tar -czf "$EXPORT_PATH" -C "$TEMP_EXPORT_DIR" . >> "$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        EXPORT_SIZE=$(du -sh "$EXPORT_PATH" | awk '{print $1}')
        echo "✅ Backup exportado exitosamente: ${FINAL_BACKUP_NAME} (${EXPORT_SIZE})" >> "$LOG_FILE"
    else
        echo "❌ ERROR: Fallo al comprimir el backup exportado." >> "$LOG_FILE"
    fi
    
    # Limpiar directorio temporal de exportación
    rm -rf "$TEMP_EXPORT_DIR"
else
    echo "❌ ERROR: Fallo al extraer backup desde Borg." >> "$LOG_FILE"
    rm -rf "$TEMP_EXPORT_DIR"
fi

# ======================================================================
# 5. LIMPIEZA DEL REPOSITORIO BORG LOCAL
# ======================================================================

echo "" >> "$LOG_FILE"
echo "🗑️ Limpiando repositorio Borg local (solo se usa como herramienta temporal)..." >> "$LOG_FILE"

# Eliminar el repositorio Borg completo - ya exportamos el .tar.gz
rm -rf "$BORG_REPO"

if [ $? -eq 0 ]; then
    echo "✅ Repositorio Borg local eliminado." >> "$LOG_FILE"
else
    echo "⚠️ Advertencia: No se pudo eliminar el repositorio Borg local." >> "$LOG_FILE"
fi

# ======================================================================
# 5. OMISIÓN DE COMPRESIÓN DE FILESTORE (Se usará rsync)
# ======================================================================
echo "" >> "$LOG_FILE"
echo "📁 El Filestore NO será comprimido localmente. Se usará rsync para la transferencia." >> "$LOG_FILE"

# ======================================================================
# 6. OPCIONAL: RESPALDO DE ADDONS PERSONALIZADOS (Se mantiene localmente)
# ======================================================================
if [ -d "$ODOO_ADDONS_PATH" ]; then
    ADDONS_TAR="${BACKUP_DIR}/${DB_NAME}_addons_${TIMESTAMP}.tar.gz"
    echo "" >> "$LOG_FILE"
    echo "📦 Comprimiendo addons personalizados en: $ADDONS_TAR" >> "$LOG_FILE"
    
    tar -czf "$ADDONS_TAR" -C "${PROJECT_ROOT}/data/odoo/web-data" addons >> "$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        echo "✅ Respaldo de addons completado." >> "$LOG_FILE"
    else
        echo "⚠️ Advertencia: Error al respaldar addons." >> "$LOG_FILE"
    fi
fi

# ======================================================================
# 7. REGISTRO DE ESTADO EN .env (Se mantiene)
# ======================================================================
TIMESTAMP_FINAL=$(date +"%Y-%m-%d_%H-%M-%S") 
CURRENT_TIME_GMT=$(TZ='GMT' date +"%Y-%m-%d %H:%M:%S %Z")
DOT_ENV_PATH="/srv/.env" 
VAR_TIME="LAST_BACKUP_TIME_GMT=\"$CURRENT_TIME_GMT\""
VAR_NAME="LAST_BORG_ARCHIVE=\"$BORG_ARCHIVE_NAME\""

# Actualizar variables en .env
if grep -q "^LAST_BACKUP_TIME_GMT=" "$DOT_ENV_PATH"; then
    sed -i "s|^LAST_BACKUP_TIME_GMT=.*|$VAR_TIME|" "$DOT_ENV_PATH"
else
    echo "$VAR_TIME" >> "$DOT_ENV_PATH"
fi

if grep -q "^LAST_BORG_ARCHIVE=" "$DOT_ENV_PATH"; then
    sed -i "s|^LAST_BORG_ARCHIVE=.*|$VAR_NAME|" "$DOT_ENV_PATH"
else
    echo "$VAR_NAME" >> "$DOT_ENV_PATH"
fi

echo "" >> "$LOG_FILE"
echo "✅ Variables de entorno actualizadas en $DOT_ENV_PATH" >> "$LOG_FILE"

# ======================================================================
# 8. LLAMADA AL SCRIPT DE TRANSFERENCIA EN SEGUNDO PLANO (NOHUP)
# ======================================================================
echo "" >> "$LOG_FILE"
echo "📤 Iniciando transferencia en SEGUNDO PLANO..." >> "$LOG_FILE"
echo "   Verifique el archivo de log: $LOG_FILE para el progreso." >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Pasar el archivo .tar.gz exportado al script de transferencia
nohup bash ./transfer.sh "$BACKUP_DIR" "$EXPORT_PATH" >> "$LOG_FILE" 2>&1 &

echo "✅ El proceso de transferencia ha sido iniciado en segundo plano."
echo "==========================================================" >> "$LOG_FILE"