#!/bin/bash

# Este script restaura completamente un backup de Odoo comprimido en .tar.gz.
# - Busca automáticamente el archivo .tar.gz más reciente en la ruta predefinida.
# - Descomprime el .tar.gz.
# - Elimina y Carga la DB desde el archivo .sql.
# - Reemplaza el filestore.
# - ¡NUEVO! Pregunta si desea vaciar la carpeta de backups al finalizar.

# ======================================================================
# 1. CONFIGURACIÓN INICIAL Y VALIDACIÓN
# ======================================================================

set -e # Detener el script inmediatamente si algún comando falla

# --- 1.1 Carga de Variables de Entorno ---
PROJECT_ROOT="/srv/prod"
DOT_ENV_PATH="${PROJECT_ROOT}/.env"

if [ ! -f "$DOT_ENV_PATH" ]; then
    echo "❌ ERROR: Archivo .env no encontrado en $DOT_ENV_PATH. Terminando."
    exit 1
fi

set -a
source "$DOT_ENV_PATH" # Carga variables desde /srv/prod/.env
set +a

# --- 1.2 Definición de Variables de Restauración ---
# Nombres de los CONTENEDORES (Usados para docker exec/cp)
DB_CONTAINER="${INSTANCE}_postgres"
OD_CONTAINER="${INSTANCE}_odoo"

# Nombres de los SERVICIOS en el docker-compose.yml (Usados para docker compose stop/start)
DB_SERVICE="postgres"
OD_SERVICE="odoo"

DB_NAME="${POSTGRES_DBNAME}"
DB_USER="${POSTGRES_USER}"

# Directorio de búsqueda (Ruta fija y predefinida para encontrar el .tar.gz)
BACKUP_SEARCH_DIR="/backups"

# Rutas ABSOLUTAS de los volúmenes en el Host (¡CORRECCIÓN DE RUTAS!)
HOST_FILESTORE_ROOT="${PROJECT_ROOT}/data/odoo/web-data" # Ruta padre del filestore
HOST_FILESTORE_PATH="${HOST_FILESTORE_ROOT}/filestore"   # Ruta completa del filestore

# Directorio temporal para la descompresión
TMP_RESTORE_DIR="/tmp/odoo_restore_temp_$(date +%s)"


# ======================================================================
# 2. SELECCIÓN AUTOMÁTICA DEL ARCHIVO DE BACKUP
# ======================================================================

echo "Buscando el archivo de backup .tar.gz más reciente en $BACKUP_SEARCH_DIR..."

# Usamos 'ls -t' para seleccionar el último archivo.
BACKUP_TAR_FILE=$(ls -t "$BACKUP_SEARCH_DIR"/*.tar.gz 2>/dev/null | head -n 1)

if [ -z "$BACKUP_TAR_FILE" ] || [ ! -f "$BACKUP_TAR_FILE" ]; then
    echo "❌ ERROR: No se encontró ningún archivo .tar.gz en el directorio $BACKUP_SEARCH_DIR. Terminando."
    exit 1
fi

echo "✅ Usando el backup más reciente: $(basename "$BACKUP_TAR_FILE")"

# ======================================================================
# 3. PREPARACIÓN: DESCOMPRESIÓN Y DETENCIÓN DE SERVICIOS
# ======================================================================

echo "Creando directorio temporal: $TMP_RESTORE_DIR"
mkdir -p "$TMP_RESTORE_DIR"

echo "Descomprimiendo el backup en el directorio temporal..."
tar -xzf "$BACKUP_TAR_FILE" -C "$TMP_RESTORE_DIR"

# Intentar encontrar el archivo .sql dentro de la descompresión
SQL_FILE=$(find "$TMP_RESTORE_DIR" -type f -name "*.sql" | head -n 1)

if [ -z "$SQL_FILE" ] || [ ! -f "$SQL_FILE" ]; then
    echo "❌ ERROR: No se encontró ningún archivo .sql dentro del backup. Terminando."
    rm -rf "$TMP_RESTORE_DIR"
    exit 1
fi

echo "✅ Archivo SQL encontrado y listo para restaurar: $(basename "$SQL_FILE")"

# --- Detener Contenedores ---
echo "Deteniendo contenedores de Odoo ($OD_SERVICE) y Postgres ($DB_SERVICE)..."
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" stop "$OD_SERVICE" "$DB_SERVICE"

# Reiniciar Postgres para liberar cualquier conexión zombie
echo "Reiniciando Postgres para asegurar conexiones limpias..."
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" start "$DB_SERVICE"

# ======================================================================
# 4. RESTAURACIÓN DE LA BASE DE DATOS
# ======================================================================

echo "Copiando archivo SQL temporal al contenedor de PostgreSQL..."
CONTAINER_SQL_PATH="/tmp/restore.sql"
docker cp "$SQL_FILE" "$DB_CONTAINER:$CONTAINER_SQL_PATH"

echo "Eliminando y creando base de datos: $DB_NAME"

# 4.1. Eliminar conexiones a la DB objetivo
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME';"

# 4.2. Eliminar la base de datos
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" dropdb -U "$DB_USER" "$DB_NAME" || echo "Advertencia: La base de datos no pudo ser eliminada (podría no existir). Continuamos."

# 4.3. Crear la base de datos
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" createdb -U "$DB_USER" -O "$DB_USER" "$DB_NAME"

if [ $? -ne 0 ]; then
    echo "❌ ERROR: Fallo al crear la nueva base de datos. Terminando."
    rm -rf "$TMP_RESTORE_DIR"
    exit 1
fi

echo "Iniciando restauración de la base de datos..."
# 4.4. Restaurar la base de datos
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -f "$CONTAINER_SQL_PATH"

if [ $? -eq 0 ]; then
    echo "✅ Restauración de la base de datos completada exitosamente."
else
    echo "❌ ERROR: Fallo al restaurar la base de datos. Revisar logs de Postgres."
fi

# 4.5. Limpieza del SQL en el contenedor
docker exec "$DB_CONTAINER" rm "$CONTAINER_SQL_PATH"

# ======================================================================
# 5. RESTAURACIÓN DEL FILESTORE (CORREGIDA)
# ======================================================================

# Busca el archivo del filestore dentro de la descompresión.
FILESTORE_TAR=$(find "$TMP_RESTORE_DIR" -type f -name "filestore_backup_*.tar.gz" | head -n 1)

if [ -f "$FILESTORE_TAR" ]; then
    echo "Iniciando restauración del Filestore..."
    
    # 5.1. Asegurar que el directorio padre existe y eliminar la carpeta filestore antigua
    echo "Asegurando la existencia del directorio base: $HOST_FILESTORE_ROOT"
    mkdir -p "$HOST_FILESTORE_ROOT" # CORRECCIÓN 1: Asegura la existencia de la carpeta padre
    
    echo "Eliminando carpeta filestore antigua en $HOST_FILESTORE_PATH..."
    rm -rf "$HOST_FILESTORE_PATH" # CORRECCIÓN 2: Eliminar la carpeta completa, no solo su contenido
    
    # 5.2. Descomprimir el filestore.
    echo "Extrayendo filestore desde el archivo comprimido temporal..."
    # Al extraer en HOST_FILESTORE_ROOT, se recreará la carpeta /filestore/ dentro.
    tar -xzf "$FILESTORE_TAR" -C "$HOST_FILESTORE_ROOT" 

    if [ $? -eq 0 ]; then
        echo "✅ Restauración del filestore completada exitosamente."
    else
        echo "❌ ERROR: Fallo al restaurar el filestore. El archivo interno del backup podría no llamarse 'filestore'."
    fi
else
    echo "⚠️ Advertencia: No se encontró el archivo de filestore dentro del backup. Se omitió la restauración del filestore."
fi

# ======================================================================
# 6. LIMPIEZA Y FINALIZACIÓN
# ======================================================================

echo "Eliminando directorio temporal de restauración: $TMP_RESTORE_DIR"
rm -rf "$TMP_RESTORE_DIR"

echo "Iniciando contenedor de Odoo ($OD_SERVICE)..."
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" start "$OD_SERVICE"

echo "Proceso de restauración completa finalizado."

# ======================================================================
# 7. GESTIÓN DE BACKUPS ANTIGUOS
# ======================================================================

echo ""
read -r -p "¿Desea **vaciar completamente** la carpeta de backups ($BACKUP_SEARCH_DIR)? [s/N]: " RESPUESTA

if [[ "$RESPUESTA" =~ ^([sS])$ ]]; then
    echo "⚠️ ATENCIÓN: Eliminando todos los archivos dentro de $BACKUP_SEARCH_DIR..."
    
    # Usamos 'find' y 'rm' para eliminar solo los contenidos, no la carpeta en sí.
    # Esto evita problemas si el script está ubicado dentro de esa misma carpeta.
    find "$BACKUP_SEARCH_DIR" -mindepth 1 -delete
    
    if [ $? -eq 0 ]; then
        echo "✅ Carpeta de backups vaciada exitosamente."
    else
        echo "❌ ERROR: Fallo al intentar vaciar la carpeta de backups."
    fi
else
    echo "▶️ Terminando el programa. Se conservaron los backups en $BACKUP_SEARCH_DIR."
fi

exit 0 # Terminación exitosa del script