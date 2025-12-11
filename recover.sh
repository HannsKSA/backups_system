#!/bin/bash

# Este script descarga los backups .tar.gz desde el servidor remoto
# y permite seleccionar cuál restaurar

# ======================================================================
# 1. CONFIGURACIÓN INICIAL
# ======================================================================

set -e

set -a
source /srv/prod/.env
set +a

if [ -z "$INSTANCE" ]; then
    echo "❌ ERROR: La variable 'INSTANCE' no está definida en /srv/prod/.env. Terminando."
    exit 1
fi

LOCAL_RECOVER_PATH="/backups" 
mkdir -p "$LOCAL_RECOVER_PATH"

echo "✅ Directorio local de recuperación: $LOCAL_RECOVER_PATH"

# ======================================================================
# 2. PARÁMETROS DE CONEXIÓN REMOTA
# ======================================================================

SSH_USER="u502156"
SSH_HOST="u502156.your-storagebox.de"
SSH_PORT="23"
SSH_KEY="/root/.ssh/id_backups"

REMOTE_BASE_PATH="/home/vps"
REMOTE_PROJECT_PATH="${REMOTE_BASE_PATH}/${INSTANCE}"
REMOTE_DB_DIR="${REMOTE_PROJECT_PATH}/db_backups"

echo "✅ Instancia: $INSTANCE"

# ======================================================================
# 3. LISTAR BACKUPS DISPONIBLES
# ======================================================================

echo ""
echo "📋 Listando backups disponibles en el servidor remoto..."
echo ""

BACKUPS=$(ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "ls -1t ${REMOTE_DB_DIR}/*.tar.gz 2>/dev/null" | xargs -n 1 basename)

if [ -z "$BACKUPS" ]; then
    echo "❌ ERROR: No se encontraron backups en el servidor remoto."
    exit 1
fi

# Convertir a array
mapfile -t BACKUP_ARRAY <<< "$BACKUPS"

# Mostrar backups disponibles
echo "Backups disponibles (más recientes primero):"
for i in "${!BACKUP_ARRAY[@]}"; do
    echo "[$i] ${BACKUP_ARRAY[$i]}"
done

# ======================================================================
# 4. SELECCIÓN DEL BACKUP
# ======================================================================

echo ""
read -p "Seleccione el número del backup a restaurar [0-$((${#BACKUP_ARRAY[@]}-1))]: " SELECTION

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 0 ] || [ "$SELECTION" -ge "${#BACKUP_ARRAY[@]}" ]; then
    echo "❌ ERROR: Selección inválida."
    exit 1
fi

SELECTED_BACKUP="${BACKUP_ARRAY[$SELECTION]}"
echo "✅ Seleccionado: $SELECTED_BACKUP"

# ======================================================================
# 5. DESCARGAR BACKUP
# ======================================================================

echo ""
echo "📥 Descargando backup desde el servidor remoto..."

scp -P "$SSH_PORT" -i "$SSH_KEY" \
    "$SSH_USER@$SSH_HOST":"${REMOTE_DB_DIR}/${SELECTED_BACKUP}" \
    "${LOCAL_RECOVER_PATH}/"

if [ $? -eq 0 ]; then
    echo "✅ Backup descargado exitosamente: $SELECTED_BACKUP"
else
    echo "❌ ERROR: Fallo al descargar el backup."
    exit 1
fi

# ======================================================================
# 6. EJECUTAR RESTAURACIÓN
# ======================================================================

echo ""
echo "▶️  Iniciando proceso de restauración..."
echo ""

# Ejecutar restore.sh con el archivo descargado
/srv/scripts/backups/restore.sh "${LOCAL_RECOVER_PATH}/${SELECTED_BACKUP}"

echo ""
echo "🎉 Proceso de recuperación finalizado."