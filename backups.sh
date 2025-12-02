#!/bin/bash

# Este script realiza un backup de la base de datos y el filestore de Odoo
# en un entorno Docker Compose, asumiendo que el proyecto reside en /srv/prod.
# ======================================================================
# 0. CONFIGURACIÓN DEL CRON (Verificar y añadir si es necesario)
# ======================================================================
# 0 3 * * * /ruta/absoluta/a/backups.sh

# Define la ruta ABSOLUTA del script. Asegúrate de que esta sea la ruta real donde estará el script.
SCRIPT_PATH="/srv/scripts/backups.sh" 

# Define la línea de CRON deseada: 3:00 AM (0 minutos, 3 horas, cualquier día del mes/mes/día de la semana)
CRON_JOB="0 3 * * * bash $SCRIPT_PATH >> /var/log/backup_cron.log 2>&1"

echo "Verificando la existencia de la tarea cron para el backup diario..."

# 1. Lista el crontab actual.
# 2. Busca la línea que contiene la hora y el nombre del script.
# 3. Si 'grep' no encuentra la línea ($? es diferente de 0):
if ! crontab -l | grep -F "$CRON_JOB" ; then
    echo "⚠️ La tarea cron no existe. Creándola: $CRON_JOB"
    
    # Añade la nueva línea al crontab existente (o crea uno si no hay).
    # La salida se redirige a un archivo de log para registro de cron.
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

set -e # Detener el script inmediatamente si algún comando falla
set -a
source /srv/prod/.env # Carga variables desde la ruta ABSOLUTA
set +a

# --- 1.1 Rutas y Nomenclatura ---

# Define la ruta ABSOLUTA de la raíz del proyecto (donde está 'data')
PROJECT_ROOT="/srv/prod"

# Nombres de contenedores y variables clave
DB_CONTAINER="${INSTANCE}_postgres"
OD_CONTAINER="${INSTANCE}_odoo"
DB_NAME="${POSTGRES_DBNAME}" # Usamos POSTGRES_DBNAME=pipesport, ya que POSTGRES_DB=postgres puede ser la base por defecto.
DB_USER="${POSTGRES_USER}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# DIRECTORIO DE BACKUPS (Relativo al lugar de ejecución: /srv/scripts/backups)
BACKUP_DIR="./backups"

# Rutas ABSOLUTAS de los volúmenes en el Host (usadas para tar)
# La raíz de la carpeta 'data' de Odoo
ODOO_FILESTORE_ROOT="${PROJECT_ROOT}/data/odoo/web-data" 
ODOO_ADDONS_PATH="${ODOO_FILESTORE_ROOT}/addons" # Si los addons personalizados son críticos

# Nombres de los archivos de salida
SQL_FILE="${BACKUP_DIR}/db_dump_${TIMESTAMP}.sql"
FILESTORE_TAR="${BACKUP_DIR}/filestore_backup_${TIMESTAMP}.tar.gz"


# ======================================================================
# 2. PREPARACIÓN
# ======================================================================
echo "Iniciando proceso de respaldo para la DB: $DB_NAME"

# Crea el directorio de backups si no existe
mkdir -p "$BACKUP_DIR"

# ======================================================================
# 3. RESPALDO DE LA BASE DE DATOS (POSTGRES)
# ======================================================================
echo "Respaldando base de datos Odoo: $DB_NAME en $SQL_FILE"

# Para mayor seguridad y evitar problemas con contraseñas con caracteres especiales,
# se define PGPASSWORD justo antes del comando.
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" > "$SQL_FILE"

if [ $? -eq 0 ]; then
    echo "✅ Respaldo de la base de datos completado exitosamente. Tamaño: $(du -sh "$SQL_FILE" | awk '{print $1}')"
else
    echo "❌ Error al respaldar la base de datos. Terminando."
    exit 1
fi

# ======================================================================
# 4. RESPALDO DEL FILESTORE (ARCHIVOS ADJUNTOS)
# ======================================================================
echo "Comprimiendo el filestore de Odoo en: $FILESTORE_TAR"

# Comando tar CORREGIDO:
# -C $ODOO_FILESTORE_ROOT: Cambia el directorio de trabajo a /srv/prod/data/odoo/ (RUTA ABSOLUTA)
# web-data: Comprime la carpeta 'web-data' que está dentro.
tar -czf "$FILESTORE_TAR" -C "$ODOO_FILESTORE_ROOT" filestore

if [ $? -eq 0 ]; then
    echo "✅ Respaldo del filestore completado exitosamente. Tamaño: $(du -sh "$FILESTORE_TAR" | awk '{print $1}')"
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
    
    # Se usa la ruta padre del addons y se comprime la carpeta 'addons'
    tar -czf "$ADDONS_TAR" -C "${ODOO_FILESTORE_ROOT}" addons
    
    if [ $? -eq 0 ]; then
        echo "✅ Respaldo de addons completado exitosamente. Tamaño: $(du -sh "$ADDONS_TAR" | awk '{print $1}')"
    else
        echo "⚠️ Advertencia: Error al respaldar addons."
    fi
fi


# ======================================================================
# 6. AJUSTE DE NOMENCLATURA Y REGISTRO DE ESTADO EN .env
# ======================================================================

# 6.1. Re-definición del TIMESTAMP para que coincida con el formato Odoo solicitado: AAAA-MM-DD_HH-MM-SS
# Reemplaza la variable TIMESTAMP original que era "%Y%m%d_%H%M%S"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S") 

# 6.2. Definición del Nombre Final del Archivo (para el script de transferencia)
# Ejemplo: pipesport_2025-10-26_15-14-47.tar.gz
FINAL_BACKUP_NAME="${DB_NAME}_${TIMESTAMP}.tar.gz" 

# 6.3. Obtener Hora GMT (para el registro)
if command -v gdate > /dev/null; then
    # Para sistemas macOS/Homebrew
    CURRENT_TIME_GMT=$(gdate -u +"%Y-%m-%d %H:%M:%S %Z")
else
    # Para sistemas Linux
    CURRENT_TIME_GMT=$(TZ='GMT' date +"%Y-%m-%d %H:%M:%S %Z")
fi

# 6.4. Definir variables a insertar/actualizar en el .env
DOT_ENV_PATH="/srv/prod/.env" 
VAR_TIME="LAST_BACKUP_TIME_GMT=\"$CURRENT_TIME_GMT\""
VAR_NAME="FINAL_BACKUP_NAME=\"$FINAL_BACKUP_NAME\""

echo "Registrando variables de estado en $DOT_ENV_PATH para el script de transferencia..."

# Función para actualizar/añadir la variable en el .env
update_or_add_var() {
    local var_line="$1"
    local var_name="${var_line%%=*}"
    
    if grep -q "$var_name" "$DOT_ENV_PATH"; then
        # Actualiza la variable usando sed
        # El patrón /c\ reemplaza toda la línea que comienza con el nombre de la variable
        sed -i "/^$var_name=/c\\$var_line" "$DOT_ENV_PATH"
    else
        # Añade la variable al final
        echo "$var_line" >> "$DOT_ENV_PATH"
    fi


# 6.5. Ejecutar la actualización para ambas variables
update_or_add_var "$VAR_TIME"
update_or_add_var "$VAR_NAME"

if [ $? -eq 0 ]; then
    echo "✅ Variables de estado (Hora GMT y Nombre Final) registradas exitosamente."
else
    echo "❌ ERROR: Fallo al registrar las variables en $DOT_ENV_PATH. Revisar permisos."
fi

# ======================================================================
# 7. LLAMADA AL SCRIPT DE COMPRESIÓN Y TRANSFERENCIA
# ======================================================================

echo "Iniciando proceso de compresión y transferencia..."

# El script de transferencia (transferencia_backup.sh) DEBE:
# 1. Hacer 'source /srv/prod/.env' para obtener FINAL_BACKUP_NAME.
# 2. Comprimir los archivos intermedios (*.sql, *.tar.gz) en la carpeta "$BACKUP_DIR" con el nombre $FINAL_BACKUP_NAME.
# 3. Transferir el archivo resultante al servidor remoto.

# Le pasamos la ubicación de la carpeta de backups como argumento
bash ./tranfer_backup.sh "$BACKUP_DIR"

if [ $? -eq 0 ]; then
    echo "✅ Proceso de transferencia completado exitosamente."
else
    echo "❌ ADVERTENCIA: El script de transferencia falló. El backup está guardado localmente."
fi

# Final
echo "Fin de la ejecución del script de Backups."
