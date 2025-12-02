#!/bin/bash

# Este script actúa como envoltorio para el script de selección de Python.

# ======================================================================
# 1. CONFIGURACIÓN INICIAL Y PREPARACIÓN DE SSH
# ======================================================================

set -e # Detener el script si algún comando falla

# Rutas críticas
SSH_CONFIG_FILE="/root/.ssh/config"
SSH_ALIAS="backups"

# 1.1 Función para crear/verificar la configuración SSH (Se mantiene lo que funciona)
ensure_ssh_config() {
    CONFIG_ENTRY="\nHost backups\n    HostName u502156.your-storagebox.de\n    User u502156\n    Port 23\n    IdentityFile ~/.ssh/id_backups\n"
    
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    if [ ! -f "$SSH_CONFIG_FILE" ] || ! grep -q "Host ${SSH_ALIAS}" "$SSH_CONFIG_FILE"; then
        echo "⚠️ ADVERTENCIA: Alias '${SSH_ALIAS}' no encontrado. Creando configuración..."
        echo -e "$CONFIG_ENTRY" >> "$SSH_CONFIG_FILE"
        chmod 600 "$SSH_CONFIG_FILE"
        echo "✅ Configuración SSH para '${SSH_ALIAS}' creada/actualizada."
    else
        echo "✅ Configuración SSH para '${SSH_ALIAS}' ya existente."
    fi
}
ensure_ssh_config

# 1.2 Cargar variables de entorno para obtener INSTANCE
set -a
source /srv/prod/.env  # 👈 Obtiene la variable INSTANCE
set +a

# 1.3 Verificación de INSTANCE y Preparación Local
if [ -z "$INSTANCE" ]; then
    echo "❌ ERROR: La variable 'INSTANCE' no está definida en /srv/prod/.env. Terminando."
    exit 1
fi

LOCAL_RECOVER_PATH="/srv/scripts/backups" 
echo "Preparando el entorno de recuperación local..."
mkdir -p "$LOCAL_RECOVER_PATH"
echo "✅ Directorio local de recuperación: $LOCAL_RECOVER_PATH"

# ======================================================================
# 2. EJECUCIÓN DE PYTHON
# ======================================================================

echo "✅ Instancia de consulta remota cargada: $INSTANCE"

# Exportamos la variable INSTANCE para que sea accesible al script de Python
export INSTANCE

# Ejecutamos el script de Python
python3 /srv/scripts/recover_selector.py

# El script Bash terminará aquí. El resto de la lógica y manejo de errores está en Python.
