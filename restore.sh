#!/bin/bash

# Este script restaura un backup de Odoo desde un archivo .tar.gz
# Puede recibir el archivo como argumento o buscar el más reciente

# ======================================================================
# 1. CONFIGURACIÓN INICIAL Y VALIDACIÓN
# ======================================================================

set -e

PROJECT_ROOT="/srv/prod"
DOT_ENV_PATH="${PROJECT_ROOT}/.env"

if [ ! -f "$DOT_ENV_PATH" ]; then
    echo "❌ ERROR: Archivo .env no encontrado en $DOT_ENV_PATH. Terminando."
    exit 1
fi

set -a
source "$DOT_ENV_PATH"
set +a

# Nombres de los CONTENEDORES
DB_CONTAINER="${INSTANCE}_postgres"
OD_CONTAINER="${INSTANCE}_odoo"

# Nombres de los SERVICIOS
DB_SERVICE="postgres"
OD_SERVICE="odoo"

DB_NAME="${POSTGRES_DBNAME}"
DB_USER="${POSTGRES_USER}"

# Directorio de backups
BACKUP_SEARCH_DIR="/backups"

# Rutas del filestore
HOST_FILESTORE_ROOT="${PROJECT_ROOT}/data/odoo/web-data"
HOST_FILESTORE_PATH="${HOST_FILESTORE_ROOT}/filestore"

# Directorio temporal
TMP_RESTORE_DIR="/tmp/odoo_restore_temp_$(date +%s)"

# ======================================================================
# 2. SELECCIÓN DEL ARCHIVO DE BACKUP
# ======================================================================

if [ -n "$1" ]; then
    # Archivo especificado como argumento
    BACKUP_TAR_FILE="$1"
    echo "📦 Usando backup especificado: $(basename "$BACKUP_TAR_FILE")"
else
    # Buscar el más reciente
    echo "🔍 Buscando el archivo de backup .tar.gz más reciente en $BACKUP_SEARCH_DIR..."
    BACKUP_TAR_FILE=$(ls -t "$BACKUP_SEARCH_DIR"/*.tar.gz 2>/dev/null | head -n 1)
fi

if [ -z "$BACKUP_TAR_FILE" ] || [ ! -f "$BACKUP_TAR_FILE" ]; then
    echo "❌ ERROR: No se encontró ningún archivo .tar.gz."
    exit 1
fi

echo "✅ Archivo a restaurar: $(basename "$BACKUP_TAR_FILE")"

# ======================================================================
# 3. DESCOMPRESIÓN Y PREPARACIÓN
# ======================================================================

echo ""
echo "📦 Descomprimiendo backup..."
mkdir -p "$TMP_RESTORE_DIR"

tar -xzf "$BACKUP_TAR_FILE" -C "$TMP_RESTORE_DIR"

if [ $? -ne 0 ]; then
    echo "❌ ERROR: Fallo al descomprimir el backup."
    rm -rf "$TMP_RESTORE_DIR"
    exit 1
fi

# Buscar el archivo SQL
SQL_FILE=$(find "$TMP_RESTORE_DIR" -type f -name "*.sql" | head -n 1)

if [ -z "$SQL_FILE" ] || [ ! -f "$SQL_FILE" ]; then
    echo "❌ ERROR: No se encontró ningún archivo .sql en el backup."
    rm -rf "$TMP_RESTORE_DIR"
    exit 1
fi

echo "✅ Archivo SQL encontrado: $(basename "$SQL_FILE")"

# ======================================================================
# 4. CONFIRMACIÓN DE RESTAURACIÓN
# ======================================================================

echo ""
echo "⚠️  ADVERTENCIA: Esta operación eliminará la base de datos actual '$DB_NAME'"
echo "   y la reemplazará con el backup seleccionado."
echo ""
read -p "¿Desea continuar? (si/no): " CONFIRM

if [ "$CONFIRM" != "si" ]; then
    echo "❌ Restauración cancelada por el usuario."
    rm -rf "$TMP_RESTORE_DIR"
    exit 0
fi

# ======================================================================
# 5. DETENCIÓN DE SERVICIOS
# ======================================================================

echo ""
echo "🛑 Deteniendo contenedores..."
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" stop "$OD_SERVICE" "$DB_SERVICE"

echo "🔄 Reiniciando Postgres..."
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" start "$DB_SERVICE"

echo "⏳ Esperando a que Postgres esté listo..."
sleep 5

# ======================================================================
# 6. RESTAURACIÓN DE LA BASE DE DATOS
# ======================================================================

echo ""
echo "🗄️  Restaurando base de datos: $DB_NAME"

CONTAINER_SQL_PATH="/tmp/restore.sql"
docker cp "$SQL_FILE" "$DB_CONTAINER:$CONTAINER_SQL_PATH"

echo "   Terminando conexiones activas..."
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME';" > /dev/null 2>&1

echo "   Eliminando base de datos antigua..."
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" dropdb -U "$DB_USER" "$DB_NAME" 2>/dev/null || \
    echo "   (La base de datos no existía)"

echo "   Creando nueva base de datos..."
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" createdb -U "$DB_USER" -O "$DB_USER" "$DB_NAME"

if [ $? -ne 0 ]; then
    echo "❌ ERROR: Fallo al crear la nueva base de datos."
    rm -rf "$TMP_RESTORE_DIR"
    exit 1
fi

echo "   Cargando datos desde el backup..."
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -f "$CONTAINER_SQL_PATH" > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo "✅ Restauración de la base de datos completada exitosamente."
else
    echo "❌ ERROR: Fallo al restaurar la base de datos."
    docker exec "$DB_CONTAINER" rm "$CONTAINER_SQL_PATH"
    rm -rf "$TMP_RESTORE_DIR"
    exit 1
fi

docker exec "$DB_CONTAINER" rm "$CONTAINER_SQL_PATH"

# ======================================================================
# 7. RESTAURACIÓN DEL FILESTORE (SI EXISTE)
# ======================================================================

echo ""
echo "📁 Verificando si hay filestore para restaurar..."

FILESTORE_TAR=$(find "$TMP_RESTORE_DIR" -type f -name "filestore_backup_*.tar.gz" | head -n 1)

if [ -f "$FILESTORE_TAR" ]; then
    echo "   Restaurando filestore..."
    mkdir -p "$HOST_FILESTORE_ROOT"
    rm -rf "$HOST_FILESTORE_PATH"
    tar -xzf "$FILESTORE_TAR" -C "$HOST_FILESTORE_ROOT"
    
    if [ $? -eq 0 ]; then
        echo "✅ Restauración del filestore completada."
    else
        echo "⚠️  Advertencia: Fallo al restaurar el filestore."
    fi
else
    echo "ℹ️  No se encontró filestore en el backup (solo DB)."
fi

# ======================================================================
# 8. LIMPIEZA Y FINALIZACIÓN
# ======================================================================

echo ""
echo "🗑️  Limpiando archivos temporales..."
rm -rf "$TMP_RESTORE_DIR"

echo "🚀 Iniciando contenedor de Odoo..."
docker compose -f "${PROJECT_ROOT}/docker-compose.yml" start "$OD_SERVICE"

echo ""
echo "=========================================="
echo "✅ RESTAURACIÓN COMPLETADA EXITOSAMENTE"
echo "=========================================="
echo ""
echo "Archivo restaurado: $(basename "$BACKUP_TAR_FILE")"
echo "Base de datos: $DB_NAME"
echo ""

exit 0