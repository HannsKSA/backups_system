#!/bin/bash

# Este script realiza la compresión final del backup y lo transfiere
# a un servidor remoto mediante SCP, verificando la existencia de la carpeta remota.

# ======================================================================
# 1. CONFIGURACIÓN Y CARGA DE VARIABLES
# ======================================================================

set -e # Detener el script si algún comando falla

# 🚨 Cargar variables del .env para obtener FINAL_BACKUP_NAME, INSTANCE, etc.
set -a
source /srv/prod/.env
set +a

# 🚨 El script principal (backups.sh) pasa la ruta del directorio de backups como argumento
BACKUP_DIR="$1"

if [ -z "$BACKUP_DIR" ]; then
    echo "❌ ERROR: No se proporcionó el directorio de backups. Terminando."
    exit 1
fi

# ======================================================================
# 2. DEFINICIÓN DE PARÁMETROS DE TRANSFERENCIA
# ======================================================================

# Parámetros remotos proporcionados
SSH_USER="u502156"
SSH_HOST="u502156.your-storagebox.de"
SSH_PORT="23"
SSH_KEY="~/.ssh/id_backups"

# Ruta base en el servidor remoto
REMOTE_BASE_PATH="/home/vps"

# Ruta remota final, usando la variable INSTANCE (Ej: /home/backups/pipesport-odoo-prod)
REMOTE_PROJECT_PATH="${REMOTE_BASE_PATH}/${INSTANCE}"

# 🚨 Archivo local a enviar (obtenido del .env)
LOCAL_FILE="${BACKUP_DIR}/${FINAL_BACKUP_NAME}"

# Archivos intermedios a incluir en la compresión final
INTERMEDIATE_FILES="${BACKUP_DIR}/db_dump_*.sql ${BACKUP_DIR}/filestore_backup_*.tar.gz ${BACKUP_DIR}/addons_backup_*.tar.gz"


# ======================================================================
# 3. COMPRESIÓN FINAL (Creación del .tar.gz)
# ======================================================================

echo "Comprimiendo componentes en el archivo final: $FINAL_BACKUP_NAME"

# Cambiar al directorio de backups temporalmente
cd "$BACKUP_DIR"

# Comando tar: crea el archivo final (usamos la ruta relativa aquí)
# El archivo final se llamará pipesport_...tar.gz y estará en ./backups
tar -czf "$FINAL_BACKUP_NAME" db_dump_*.sql filestore_backup_*.tar.gz addons_backup_*.tar.gz

# Regresar al directorio anterior
cd - > /dev/null

if [ $? -eq 0 ]; then
    # ... (el resto de la lógica de limpieza y verificación de tamaño) ...
    echo "✅ Paquete final $FINAL_BACKUP_NAME creado exitosamente. Tamaño: $(du -sh "$LOCAL_FILE" | awk '{print $1}')"

    # Eliminar archivos intermedios después de la compresión final (usando ruta absoluta)
    echo "Limpiando archivos intermedios..."
    rm -f $INTERMEDIATE_FILES
else
    echo "❌ ERROR: Fallo al crear el paquete final. No se realizará la transferencia."
    exit 1
fi
# ======================================================================
# 4. VALIDACIÓN Y CREACIÓN DE CARPETA REMOTA
# ======================================================================

echo "Verificando/Creando carpeta remota: $REMOTE_PROJECT_PATH"

# Comando SSH para ejecutar la creación del directorio (-p: crea si no existe)
SSH_COMMAND="mkdir -p ${REMOTE_PROJECT_PATH}"

# Ejecutar el comando remoto
ssh -p "$SSH_PORT" -i "$SSH_KEY" "$SSH_USER@$SSH_HOST" "$SSH_COMMAND"

if [ $? -eq 0 ]; then
    echo "✅ Directorio remoto verificado/creado."
else
    echo "❌ ERROR: Fallo al conectar o crear el directorio remoto. Terminando."
    exit 1
fi

# 5. TRANSFERENCIA DEL ARCHIVO (SCP)
# ======================================================================

echo "Iniciando transferencia de $FINAL_BACKUP_NAME a $SSH_HOST:$REMOTE_PROJECT_PATH"

# Comando SCP
scp -P "$SSH_PORT" -i "$SSH_KEY" "$LOCAL_FILE" "$SSH_USER@$SSH_HOST":"${REMOTE_PROJECT_PATH}/"

if [ $? -eq 0 ]; then
    echo "✅ Transferencia SCP completada exitosamente."

    # ======================================================================
    # NUEVA LÓGICA: VACIAR COMPLETAMENTE LA CARPETA DE BACKUPS LOCAL
    # ======================================================================
    echo "Limpiando completamente la carpeta de backups local: $BACKUP_DIR"
    
    # Borra de forma recursiva (r) y sin preguntar (f) todo el contenido de la carpeta.
    # **IMPORTANTE:** Esto asume que $BACKUP_DIR es un directorio temporal o dedicado.
    rm -rf "$BACKUP_DIR"/*
    
    # *Se quita el IF interno para simplificar y evitar el error de sintaxis*

    if [ $? -eq 0 ]; then # <--- EL ERROR ESTABA AQUÍ
        echo "✅ Carpeta de backups local ($BACKUP_DIR) vaciada exitosamente."
    else
        echo "⚠️ ADVERTENCIA: Fallo al vaciar la carpeta local. Deberá limpiarse manualmente."
    fi

else
    echo "❌ ERROR: Fallo en la transferencia SCP. No se realizará ninguna limpieza local."
    exit 1
fi

echo "Proceso de transferencia finalizado."
