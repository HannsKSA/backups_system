#!/bin/bash

# Este script realiza la compresión final del backup y lo transfiere
# a un servidor remoto mediante SCP, verificando la existencia de la carpeta remota.

# ======================================================================
# 1. CONFIGURACIÓN Y CARGA DE VARIABLES
# ======================================================================

set -e # Detener el script si algún comando falla

# Cargar variables del .env para obtener FINAL_BACKUP_NAME, INSTANCE, etc.
set -a
source /srv/.env # <--- ¡ACTUALIZADO! Fuente de variables de /srv/.env
set +a

# La ruta del directorio de backups es el argumento pasado por el script principal
BACKUP_DIR="$1"

if [ -z "$BACKUP_DIR" ]; then
    echo "❌ ERROR: No se proporcionó el directorio de backups. Terminando."
    exit 1
fi

# ======================================================================
# 2. DEFINICIÓN DE PARÁMETROS DE TRANSFERENCIA
# ======================================================================

# Parámetros remotos
SSH_USER="u502156"
SSH_HOST="u502156.your-storagebox.de"
SSH_PORT="23"
# La clave SSH debe ser absoluta. Se recomienda usar la ruta del usuario root si es cron.
SSH_KEY="/root/.ssh/id_backups" # Ajusta esta ruta si el usuario es diferente

# Ruta base en el servidor remoto
REMOTE_BASE_PATH="/home/vps"
REMOTE_PROJECT_PATH="${REMOTE_BASE_PATH}/${INSTANCE}"

# Archivo local final a enviar (obtenido del .env)
LOCAL_FILE_PATH="${BACKUP_DIR}/${FINAL_BACKUP_NAME}"

# Patrones de archivos intermedios (para limpieza local)
INTERMEDIATE_PATTERNS="${BACKUP_DIR}/db_dump_*.sql.gz ${BACKUP_DIR}/filestore_backup_*.tar.gz ${BACKUP_DIR}/addons_backup_*.tar.gz"


# ======================================================================
# 3. COMPRESIÓN FINAL (Creación del .tar.gz)
# ======================================================================

echo "Comprimiendo archivos en el paquete final: $FINAL_BACKUP_NAME"

# Cambiar al directorio de backups temporalmente
cd "$BACKUP_DIR"

# 'find' obtiene la lista exacta de archivos creados para evitar problemas si no hay addons.
FILES_TO_TAR=$(find . -maxdepth 1 -name "db_dump_*.sql.gz" -o -name "filestore_backup_*.tar.gz" -o -name "addons_backup_*.tar.gz" | sed 's|^./||')

if [ -z "$FILES_TO_TAR" ]; then
    echo "❌ ERROR: No se encontraron archivos intermedios para empaquetar en $BACKUP_DIR."
    exit 1
fi

# Comando tar: crea el archivo final .tar.gz
tar -czf "$FINAL_BACKUP_NAME" $FILES_TO_TAR

# Regresar al directorio anterior
cd - > /dev/null

echo "✅ Paquete final $FINAL_BACKUP_NAME creado exitosamente. Tamaño: $(du -sh "$LOCAL_FILE_PATH" | awk '{print $1}')"


# ======================================================================
# 4. VALIDACIÓN Y CREACIÓN DE CARPETA REMOTA
# ======================================================================

echo "Verificando/Creando carpeta remota: $REMOTE_PROJECT_PATH"

# Comando SSH para ejecutar la creación del directorio
SSH_COMMAND="mkdir -p ${REMOTE_PROJECT_PATH}"

# Ejecutar el comando remoto
ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "$SSH_COMMAND"

if [ $? -ne 0 ]; then
    echo "❌ ERROR: Fallo al conectar o crear el directorio remoto. Terminando."
    exit 1
fi
echo "✅ Directorio remoto verificado/creado."


# ======================================================================
# 5. TRANSFERENCIA DEL ARCHIVO (SCP)
# ======================================================================

echo "Iniciando transferencia de $FINAL_BACKUP_NAME a $SSH_HOST:$REMOTE_PROJECT_PATH"

# Comando SCP. La opción -P es para el puerto.
scp -P "$SSH_PORT" -i "$SSH_KEY" "$LOCAL_FILE_PATH" "$SSH_USER@$SSH_HOST":"${REMOTE_PROJECT_PATH}/"

if [ $? -eq 0 ]; then
    echo "✅ Transferencia SCP completada exitosamente."

    # ======================================================================
    # LIMPIEZA LOCAL
    # ======================================================================
    echo "🗑️ Limpiando archivos intermedios y paquete final de la carpeta local: $BACKUP_DIR"
    
    # Eliminar archivos intermedios y el paquete final .tar.gz
    rm -f $INTERMEDIATE_PATTERNS 
    rm -f "$LOCAL_FILE_PATH"

    if [ $? -eq 0 ]; then
        echo "✅ Archivos intermedios y paquete final vaciados exitosamente."
    else
        echo "⚠️ ADVERTENCIA: Fallo al vaciar la carpeta local. Deberá limpiarse manualmente."
    fi

else
    echo "❌ ERROR: Fallo en la transferencia SCP. No se realizará ninguna limpieza local."
    exit 1
fi

echo "Proceso de transferencia finalizado."