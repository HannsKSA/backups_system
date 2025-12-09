#!/bin/bash

# Este script realiza un backup de la base de datos y el filestore de Odoo
# en un entorno Docker Compose, optimizado para bases de datos muy grandes.
# La base de datos es COMPRIMIDA en línea (on-the-fly) para ahorrar espacio y tiempo de E/S.
# ======================================================================
# 0. CONFIGURACIÓN DEL CRON (Verificar y añadir si es necesario)
# ======================================================================

set -e # Detener el script inmediatamente si algún comando falla
set -a
source /srv/.env # <--- ¡ACTUALIZADO! Fuente de variables de /srv/.env
set +a

# --- CONFIGURACIÓN DE CRON ---
SCRIPT_PATH="/srv/scripts/backups.sh" 
CRON_JOB="0 3 * * * bash $SCRIPT_PATH >> /var/log/backup_cron.log 2>&1"

echo "Verificando la existencia de la tarea cron para el backup diario..."
if ! crontab -l 2>/dev/null | grep -Fq "$CRON_JOB" ; then
    echo "⚠️ La tarea cron no existe. Creándola: $CRON_JOB"
    (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
    if [ $? -eq 0 ]; then
        echo "✅ Tarea cron añadida exitosamente. Se ejecutará diariamente a las 3:00 AM."
    else
        echo "❌ ERROR: Fallo al añadir la tarea cron. Revise permisos de usuario."
    fi
else
    echo "✅ La tarea cron ya existe. No se requiere acción."
fi

# ======================================================================
# 1. CONFIGURACIÓN INICIAL
# ======================================================================

# --- 1.1 Rutas y Nomenclatura ---
PROJECT_ROOT="/srv" # Asumimos que la raíz del proyecto ahora es /srv
DB_CONTAINER="${INSTANCE}_postgres"
DB_NAME="${POSTGRES_DBNAME}" 
DB_USER="${POSTGRES_USER}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# DIRECTORIO DE BACKUPS (Relativo al lugar de ejecución: /srv/scripts/backups)
BACKUP_DIR="./backups"

# Rutas ABSOLUTAS de los volúmenes en el Host (usadas para tar)
# Ajuste de ruta: Asumimos que data/odoo/web-data ahora está en /srv/data/...
ODOO_FILESTORE_ROOT="${PROJECT_ROOT}/data/odoo/web-data" 
ODOO_ADDONS_PATH="${ODOO_FILESTORE_ROOT}/addons"

# Nombres de los archivos intermedios de salida
SQL_FILE="${BACKUP_DIR}/db_dump_${TIMESTAMP}.sql.gz" 
FILESTORE_TAR="${BACKUP_DIR}/filestore_backup_${TIMESTAMP}.tar.gz"

echo "Iniciando proceso de respaldo para la DB: $DB_NAME"
mkdir -p "$BACKUP_DIR"

# ======================================================================
# 3. RESPALDO DE LA BASE DE DATOS (POSTGRES) - OPTIMIZADO
# ======================================================================
echo "Respaldando base de datos Odoo: $DB_NAME y comprimiendo en línea en $SQL_FILE"
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" | gzip -c > "$SQL_FILE"

if [ $? -eq 0 ]; then
    echo "✅ Respaldo de la base de datos completado. Tamaño: $(du -sh "$SQL_FILE" | awk '{print $1}')"
else
    echo "❌ Error al respaldar la base de datos. Terminando."
    exit 1
fi

# ======================================================================
# 4. RESPALDO DEL FILESTORE (ARCHIVOS ADJUNTOS)
# ======================================================================
echo "Comprimiendo el filestore de Odoo en: $FILESTORE_TAR"
tar -czf "$FILESTORE_TAR" -C "$ODOO_FILESTORE_ROOT" filestore

if [ $? -eq 0 ]; then
    echo "✅ Respaldo del filestore completado. Tamaño: $(du -sh "$FILESTORE_TAR" | awk '{print $1}')"
else
    echo "❌ Error al respaldar el filestore. Terminando."
    exit 1
fi

# ======================================================================
# 5. OPCIONAL: RESPALDO DE ADDONS PERSONALIZADOS
# ======================================================================
if [ -d "$ODOO_ADDONS_PATH" ]; then
    ADDONS_TAR="${BACKUP_DIR}/addons_backup_${TIMESTAMP}.tar.gz"
    echo "Comprimiendo addons personalizados en: $ADDONS_TAR"
    tar -czf "$ADDONS_TAR" -C "${ODOO_FILESTORE_ROOT}" addons
    if [ $? -eq 0 ]; then
        echo "✅ Respaldo de addons completado. Tamaño: $(du -sh "$ADDONS_TAR" | awk '{print $1}')"
    else
        echo "⚠️ Advertencia: Error al respaldar addons."
    fi
fi


# ======================================================================
# 6. REGISTRO DE ESTADO EN .env
# ======================================================================
TIMESTAMP_FINAL=$(date +"%Y-%m-%d_%H-%M-%S") 
FINAL_BACKUP_NAME="${DB_NAME}_${TIMESTAMP_FINAL}.tar.gz" 
CURRENT_TIME_GMT=$(TZ='GMT' date +"%Y-%m-%d %H:%M:%S %Z")
DOT_ENV_PATH="/srv/.env" # <--- ¡ACTUALIZADO! Ruta de registro
VAR_TIME="LAST_BACKUP_TIME_GMT=\"$CURRENT_TIME_GMT\""
VAR_NAME="FINAL_BACKUP_NAME=\"$FINAL_BACKUP_NAME\""

echo "Registrando variables de estado en $DOT_ENV_PATH..."
update_or_add_var() {
    local var_line="$1"; local var_name="${var_line%%=*}"
    if grep -q "$var_name" "$DOT_ENV_PATH"; then
        sed -i "/^$var_name=/c\\$var_line" "$DOT_ENV_PATH"
    else
        echo "$var_line" >> "$DOT_ENV_PATH"
    fi
}
update_or_add_var "$VAR_TIME"
update_or_add_var "$VAR_NAME"
if [ $? -eq 0 ]; then
    echo "✅ Variables de estado registradas."
fi

# ======================================================================
# 7. LLAMADA AL SCRIPT DE COMPRESIÓN Y TRANSFERENCIA
# ======================================================================

echo "Iniciando proceso de compresión y transferencia..."

# Llama al script de transferencia y le pasa la ubicación de la carpeta de backups como argumento
bash ./transfer.sh "$BACKUP_DIR"

if [ $? -eq 0 ]; then
    echo "✅ Proceso de transferencia completado exitosamente."
else
    echo "❌ ADVERTENCIA: El script de transferencia falló. El backup está guardado localmente en $BACKUP_DIR"
fi

# Final
echo "Fin de la ejecución del script de Backups."