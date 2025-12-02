#!/bin/bash

# --- Configuración Inicial ---
set -e  # Salir inmediatamente si un comando falla

echo "✅ Iniciando la instalación de Docker, Docker Compose V2 y 'tree'..."

# 1. Actualizar el sistema e instalar dependencias necesarias
# -------------------------------------------------------------
echo "➡️  Actualizando lista de paquetes e instalando dependencias..."
sudo apt-get update
sudo apt-get install -y \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    tree # Instalamos 'tree' aquí mismo

# 2. Agregar la clave GPG oficial de Docker
# -----------------------------------------
echo "➡️  Agregando la clave GPG oficial de Docker..."
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# 3. Configurar el repositorio de Docker (Stable)
# ----------------------------------------------
echo "➡️  Configurando el repositorio estable de Docker..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 4. Instalar Docker Engine, CLI y Containerd
# ------------------------------------------
echo "➡️  Instalando Docker Engine (incluye Docker Compose V2)..."
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io

# 5. Agregar usuario actual al grupo docker
# ----------------------------------------
echo "➡️  Agregando el usuario actual ('$USER') al grupo 'docker' para evitar usar sudo..."

# Esta línea solo se ejecuta si el usuario no es root.
if [ "$EUID" -ne 0 ]; then
    sudo usermod -aG docker $USER
fi

echo ""
echo "========================================================================="
echo "🎉 ¡INSTALACIÓN COMPLETA!"
echo "========================================================================="
echo "1. Docker Engine y Docker Compose V2 instalados."
echo "2. El comando 'tree' está disponible."
echo "3. Se ha agregado el usuario '$USER' al grupo 'docker'."
echo ""
echo "⚠️  NOTA IMPORTANTE: Debes cerrar la sesión y volver a iniciarla (o reiniciar tu terminal) para que los cambios del grupo 'docker' surtan efecto."
echo ""

# 6. Verificaciones (para después de la reconexión)
# ------------------------------------------------
echo "Comandos de verificación (ejecutar tras reconectar):"
echo "  - Versión de Docker: docker --version"
echo "  - Versión de Compose: docker compose version"
echo "  - Comando 'tree': tree --version"
echo "  - Prueba de Docker: docker run hello-world"
