#!/bin/bash

# Este script realiza un backup de la base de datos y el filestore de Odoo
# DIRECTAMENTE en el servidor remoto mediante SSH streaming (sin almacenamiento local)
# Optimizado para bases de datos de 90GB+ que colapsan el servidor local
# ======================================================================
# 0. CONFIGURACIÓN DEL CRON (Hora definida por TIME_GMT en el .env)
# ======================================================================

set -e # Detener el script inmediatamente si algún comando falla
set -a
# 🛑 ATENCIÓN: Solo se LEE de /srv/.env (TIME_GMT, credenciales, INSTANCE), NUNCA se ESCRIBE en él.
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

# Rutas ABSOLUTAS de los volúmenes en el Host
ODOO_FILESTORE_ROOT="${PROJECT_ROOT}/data/odoo/web-data" 

# ======================================================================
# 2. CONFIGURACIÓN SSH REMOTA (desde transfer.sh)
# ======================================================================
SSH_HOST="u502156.your-storagebox.de"
SSH_USER="u502156"
SSH_PORT="23"
SSH_KEY="$HOME/.ssh/id_backups"
REMOTE_BASE_PATH="/home/vps"
REMOTE_DEST_DIR="${REMOTE_BASE_PATH}/${INSTANCE}"

# Nombres de archivos remotos
REMOTE_SQL_FILE="${DB_NAME}_${TIMESTAMP}.sql.gz"
REMOTE_FILESTORE_TAR="${DB_NAME}_filestore_${TIMESTAMP}.tar.gz"
REMOTE_FINAL_BACKUP="${DB_NAME}_full_${TIMESTAMP}.tar.gz"

echo "=========================================="
echo "🚀 INICIO DE BACKUP REMOTO DIRECTO"
echo "=========================================="
echo "Instancia: $INSTANCE"
echo "Base de datos: $DB_NAME"
echo "Destino: $SSH_USER@$SSH_HOST:$REMOTE_DEST_DIR"
echo "Timestamp: $TIMESTAMP"
echo "=========================================="

# ======================================================================
# 3. VERIFICAR CONEXIÓN SSH Y CREAR DIRECTORIO REMOTO
# ======================================================================
echo "📡 Verificando conexión SSH..."
if ! ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 "$SSH_USER@$SSH_HOST" "mkdir -p $REMOTE_DEST_DIR" 2>/dev/null; then
    echo "❌ ERROR: No se pudo conectar al servidor remoto o crear el directorio."
    echo "   Verifica:"
    echo "   - Conectividad de red"
    echo "   - Clave SSH en $SSH_KEY"
    echo "   - Permisos en el servidor remoto"
    exit 1
fi
echo "✅ Conexión SSH establecida correctamente"

# ======================================================================
# 4. BACKUP DE LA BASE DE DATOS (STREAMING DIRECTO)
# ======================================================================
echo ""
echo "📦 Iniciando backup de base de datos (streaming directo al servidor remoto)..."
echo "   Esto puede tardar varios minutos dependiendo del tamaño de la DB..."

# Hacer pg_dump, comprimir con gzip, y enviar directamente por SSH sin guardar localmente
PGPASSWORD="${POSTGRES_PASSWORD}" docker exec "$DB_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" | \
    gzip -c | \
    ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_USER@$SSH_HOST" \
    "cat > ${REMOTE_DEST_DIR}/${REMOTE_SQL_FILE}"

if [ $? -eq 0 ]; then
    echo "✅ Base de datos respaldada exitosamente: $REMOTE_SQL_FILE"
else
    echo "❌ ERROR: Falló el backup de la base de datos"
    exit 1
fi

# ======================================================================
# 5. BACKUP DEL FILESTORE (STREAMING DIRECTO)
# ======================================================================
echo ""
echo "📁 Iniciando backup del filestore (streaming directo al servidor remoto)..."
echo "   Comprimiendo y transfiriendo filestore..."

# Comprimir el filestore y enviarlo directamente por SSH sin guardar localmente
tar -czf - -C "$ODOO_FILESTORE_ROOT" filestore 2>/dev/null | \
    ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_USER@$SSH_HOST" \
    "cat > ${REMOTE_DEST_DIR}/${REMOTE_FILESTORE_TAR}"

if [ $? -eq 0 ]; then
    echo "✅ Filestore respaldado exitosamente: $REMOTE_FILESTORE_TAR"
else
    echo "❌ ERROR: Falló el backup del filestore"
    exit 1
fi

# ======================================================================
# 6. CREAR ARCHIVO FINAL UNIFICADO EN EL SERVIDOR REMOTO
# ======================================================================
echo ""
echo "📦 Creando archivo de backup unificado en el servidor remoto..."

# Ejecutar tar en el servidor remoto para combinar ambos archivos
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_USER@$SSH_HOST" \
    "cd ${REMOTE_DEST_DIR} && tar -czf ${REMOTE_FINAL_BACKUP} ${REMOTE_SQL_FILE} ${REMOTE_FILESTORE_TAR} && rm -f ${REMOTE_SQL_FILE} ${REMOTE_FILESTORE_TAR}"

if [ $? -eq 0 ]; then
    echo "✅ Backup unificado creado exitosamente: $REMOTE_FINAL_BACKUP"
else
    echo "❌ ERROR: Falló la creación del archivo unificado"
    exit 1
fi

# ======================================================================
# 7. RETENCIÓN Y LIMPIEZA REMOTA
# ======================================================================
echo ""
echo "🧹 Aplicando política de retención (últimos 14 días)..."

# Eliminar backups antiguos en el servidor remoto
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_USER@$SSH_HOST" \
    "find ${REMOTE_DEST_DIR} -type f -name '*_full_*.tar.gz' -mtime +14 -delete"

if [ $? -eq 0 ]; then
    echo "✅ Limpieza de backups antiguos completada"
else
    echo "⚠️  ADVERTENCIA: No se pudo completar la limpieza de backups antiguos"
fi

# ======================================================================
# 8. RESUMEN FINAL
# ======================================================================
echo ""
echo "=========================================="
echo "✅ BACKUP COMPLETADO EXITOSAMENTE"
echo "=========================================="
echo "Archivo final: $REMOTE_FINAL_BACKUP"
echo "Ubicación: $SSH_USER@$SSH_HOST:$REMOTE_DEST_DIR/"
echo ""
echo "📊 Verificar tamaño del backup:"
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_USER@$SSH_HOST" \
    "ls -lh ${REMOTE_DEST_DIR}/${REMOTE_FINAL_BACKUP}" 2>/dev/null || echo "   (No se pudo obtener información del archivo)"
echo "=========================================="
