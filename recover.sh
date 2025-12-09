#!/bin/bash

# Este script actúa como envoltorio para el script de selección de Python.

# ======================================================================
# 1. CONFIGURACIÓN INICIAL Y PREPARACIÓN DE SSH
# ======================================================================

set -e # Detener el script si algún comando falla

# 1.1 FUNCIÓN ELIMINADA: Ya no se modifica $HOME/.ssh/config

# 1.2 Cargar variables de entorno para obtener INSTANCE
set -a
source /srv/prod/.env  # 👈 Obtiene la variable INSTANCE
set +a

# 1.3 Verificación de INSTANCE y Preparación Local
if [ -z "$INSTANCE" ]; then
    echo "❌ ERROR: La variable 'INSTANCE' no está definida en /srv/prod/.env. Terminando."
    exit 1
fi

LOCAL_RECOVER_PATH="/backups" 
echo "Preparando el entorno de recuperación local..."
mkdir -p "$LOCAL_RECOVER_PATH"
echo "✅ Directorio local de recuperación: $LOCAL_RECOVER_PATH"

# 🚨 EXPORTAR RUTA DE CONFIGURACIÓN SSH TEMPORAL para que Python la use
export SSH_CONFIG_TEMP="/tmp/recover_ssh_config_$(date +%s)_$$"
echo "Ruta de configuración SSH temporal exportada: $SSH_CONFIG_TEMP"

# ======================================================================
# 2. EJECUCIÓN DE PYTHON
# ======================================================================

echo "✅ Instancia de consulta remota cargada: $INSTANCE"

# Exportamos la variable INSTANCE para que sea accesible al script de Python
export INSTANCE

# Ejecutamos el script de Python (Nombre actualizado)
python3 /srv/scripts/backups/selector.py

# El script Bash terminará aquí. El script de Python es responsable de la limpieza.