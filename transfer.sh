#!/bin/bash

# ⚠️ NOTA: Este script es LEGACY y ya NO se usa con el nuevo sistema de backups
# El nuevo backups.sh hace streaming directo al servidor remoto sin almacenamiento local
# Este script se mantiene solo por compatibilidad con versiones antiguas
#
# Script para transferir backups a almacenamiento remoto via SCP
# Se invoca desde backups.sh (versión antigua)

set -e

# 1. Recibir variables
VARIABLES_FILE="$1"
if [ -z "$VARIABLES_FILE" ]; then
    echo "❌ Error: No se proporcionó el archivo de variables."
    exit 1
fi

if [ ! -f "$VARIABLES_FILE" ]; then
    echo "❌ Error: El archivo de variables no existe: $VARIABLES_FILE"
    exit 1
fi

# Cargar variables del archivo temporal (BACKUP_DIR, FINAL_BACKUP_NAME)
source "$VARIABLES_FILE"

# Validar variables necesarias pasadas por entorno o archivo
if [ -z "$INSTANCE" ]; then
    echo "❌ Error: La variable INSTANCE no está definida (debe venir del entorno)."
    exit 1
fi

# 2. Configuración Remota (Hardcoded based on selector.py)
SSH_HOST="u502156.your-storagebox.de"
SSH_USER="u502156"
SSH_PORT="23"
SSH_KEY="$HOME/.ssh/id_backups"

# Ruta remota base (ajustar si es necesario)
REMOTE_BASE_PATH="/home/vps" 
REMOTE_DEST_DIR="${REMOTE_BASE_PATH}/${INSTANCE}"

FILE_PATH="${BACKUP_DIR}/${FINAL_BACKUP_NAME}"

if [ ! -f "$FILE_PATH" ]; then
    echo "❌ Error: El archivo de backup a transferir no existe: $FILE_PATH"
    exit 1
fi

echo "--- Iniciando Transferencia Remota ---"
echo "Archivo: $FINAL_BACKUP_NAME"
echo "Destino: $SSH_USER@$SSH_HOST:$REMOTE_DEST_DIR"

# 3. Asegurar directorio remoto
# Nota: ssh -p para puerto
ssh -p "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_USER@$SSH_HOST" "mkdir -p $REMOTE_DEST_DIR" || {
    echo "❌ Error al crear directorio remoto. Verifica conexión SSH."
    exit 1
}

# 4. Transferir archivo
scp -P "$SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "$FILE_PATH" "$SSH_USER@$SSH_HOST:$REMOTE_DEST_DIR/"

if [ $? -eq 0 ]; then
    echo "✅ Transferencia exitosa."
else
    echo "❌ Falló la transferencia SCP."
    exit 1
fi
