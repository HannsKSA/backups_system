#!/bin/bash

# =====================================================================
# DESTRUCTIVE DATA WIPE AND RESTART SCRIPT (Docker Compose)
# Author: Gemini (Modified for Safety and web-data handling)
# Purpose: Completely wipe PostgreSQL and Odoo Filestore/Sessions to start fresh.
# =====================================================================

# --- Host Directory Definitions ---
# IMPORTANT: Ensure these paths match your docker-compose volume definitions.
DATA_ROOT_DIR="/srv/prod/data"
PG_DATA_DIR="$DATA_ROOT_DIR/postgres"
ODOO_DATA_DIR="$DATA_ROOT_DIR/odoo"
WEB_DATA_DIR="$ODOO_DATA_DIR/web-data" # Path to the specific web-data directory

# --- 1. Critical Safety Warning and Confirmation ---
echo "========================================================="
echo "!!! ⚠️ CRITICAL DATA LOSS WARNING ⚠️ !!!"
echo "========================================================="
echo "THIS SCRIPT WILL PERMANENTLY AND IRRECOVERABLY DELETE:"
echo "1. ALL DATA FROM YOUR POSTGRESQL DATABASE (Database lost)."
echo "2. ALL ODOO FILESTORE AND SESSION DATA (Attachments/Files lost)."
echo ""
read -r -p "ARE YOU ABSOLUTELY SURE YOU WANT TO WIPE ALL DATA? (Type 'YES' to continue): " confirmation

# Check for explicit confirmation
if [[ "$confirmation" != "YES" ]]; then
    echo ""
    echo "❌ Operation canceled by user. No data was deleted."
    exit 1
fi

echo "✅ Confirmation received. Starting destructive process..."
echo ""

# --- 2. Stop and Remove Containers ---
echo "Stopping and removing running containers and associated volumes..."
# -v removes volumes defined in the compose file, but not bind mounts like /srv/prod/data
docker compose down -v 

# --- 3. Wipe Persistent Data (PG and Odoo Main Data) ---
echo "!!! WIPING ALL POSTGRESQL DATA ($PG_DATA_DIR) !!!"
# rm -R * deletes contents. '2>/dev/null' suppresses 'no such file or directory' errors if the folder is empty.
sudo rm -R "$PG_DATA_DIR"/* 2>/dev/null

echo "!!! WIPING ALL ODOO DATA (Filestore/Sessions) ($ODOO_DATA_DIR) !!!"
# Deleting the entire directory content
sudo rm -R "$ODOO_DATA_DIR" 2>/dev/null

# --- 4. Recreate and Set Base Permissions (Odoo Main Directory) ---
echo "Recreating Odoo main directory and setting owner/permissions..."
# -p ensures directory is created if it doesn't exist.
sudo mkdir -p "$ODOO_DATA_DIR"
# Odoo runs as UID/GID 1000 inside the container.
sudo chown -R 1000:1000 "$ODOO_DATA_DIR"
# General read/write/execute permissions for the owner.
sudo chmod -R 755 "$ODOO_DATA_DIR"

# --- 5. Ensure web-data Directory Exists and Set Permissions (Specific Requirement) ---
echo "Ensuring web-data directory exists and setting specific permissions (755)..."
sudo mkdir -p "$WEB_DATA_DIR"
sudo chown -R 1000:1000 "$WEB_DATA_DIR"
sudo chmod -R 777 "$WEB_DATA_DIR"

# --- 6. Start Docker Compose ---
echo "Starting Docker Compose. This will create a fresh, empty database."
docker compose up -d

echo ""
echo "========================================================="
echo "🚀 Restart and cleanup complete."
echo "Check logs to start database creation: docker compose logs -f"
echo "========================================================="
