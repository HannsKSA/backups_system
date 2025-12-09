import subprocess
import os
import sys

# Nota: POSTGRES_DBNAME se asume cargado desde el entorno de Bash/dotenv.
POSTGRES_DBNAME = os.environ.get("POSTGRES_DBNAME", "ejemplo_default_db")

def create_ssh_config(config_path):
    """Crea el archivo de configuración SSH temporal."""
    # Parámetros remotos hardcodeados, deben coincidir con tranfer_backup.sh
    ssh_host = "u502156.your-storagebox.de"
    ssh_user = "u502156"
    ssh_port = "23"
    ssh_key = "~/.ssh/id_backups"
    
    config_entry = f"""
Host backups
    HostName {ssh_host}
    User {ssh_user}
    Port {ssh_port}
    IdentityFile {ssh_key}
"""
    try:
        with open(config_path, "w") as f:
            f.write(config_entry)
        os.chmod(config_path, 0o600)
        print(f"✅ Configuración SSH temporal creada en: {config_path}")
    except Exception as e:
        print(f"❌ ERROR: No se pudo crear el archivo de configuración SSH temporal. {e}")
        sys.exit(1)

def run_recovery_selector():
    # --- 1. Carga de Variables ---
    instance = os.environ.get("INSTANCE")
    if not instance:
        print("❌ ERROR: La variable de entorno 'INSTANCE' no está definida.")
        sys.exit(1)
        
    # Obtener la ruta del archivo temporal exportada por recover.sh
    ssh_config_temp = os.environ.get("SSH_CONFIG_TEMP")
    if not ssh_config_temp:
        print("❌ ERROR: La variable de entorno 'SSH_CONFIG_TEMP' no está definida.")
        sys.exit(1)

    # Crear el archivo de configuración SSH temporal
    create_ssh_config(ssh_config_temp)

    # Definir variables de conexión
    ssh_alias = "backups"
    remote_base_path = "/home/vps"
    remote_project_path = f"{remote_base_path}/{instance}"
    local_recover_path = "/backups" # Ruta local actualizada
    
    def cleanup():
        """Función de limpieza que se llama antes de cualquier sys.exit() o al finalizar"""
        try:
            os.remove(ssh_config_temp)
            print(f"✅ Archivo SSH temporal eliminado: {ssh_config_temp}")
        except OSError:
            print(f"⚠️ ADVERTENCIA: Fallo al eliminar el archivo SSH temporal: {ssh_config_temp}")

    # --- 2. Consulta Remota (SSH) ---
    print(f"\n--- Buscando Backups en la Carpeta Remota: {remote_project_path} ---")
    
    # *** USAR -F PARA LA CONFIGURACIÓN TEMPORAL ***
    ssh_command = ['ssh', '-F', ssh_config_temp, 
                   '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', 
                   ssh_alias, f"ls -1r {remote_project_path}"]
    
    try:
        result = subprocess.run(ssh_command, capture_output=True, text=True, check=True)
        
    except subprocess.CalledProcessError as e:
        print("❌ ERROR: Fallo al conectar o ejecutar el comando remoto.")
        print(f"Mensaje de error SSH: {e.stderr.strip()}")
        cleanup()
        sys.exit(1)
    except FileNotFoundError:
        print("❌ ERROR: El comando 'ssh' no se encontró. Asegúrese de que SSH esté instalado y en el PATH.")
        cleanup()
        sys.exit(1)
    
    raw_list = result.stdout.strip()
    backups = [line.strip() for line in raw_list.splitlines() if line.strip()]

    if not backups:
        print(f"⚠️ ADVERTENCIA: No se encontraron archivos en la ruta: {remote_project_path}")
        cleanup()
        sys.exit(0)

    # --- 3. Selección del Usuario ---
    print("\nArchivos de Backup Remotos Disponibles (Más recientes primero):")
    for i, backup in enumerate(backups):
        print(f"[{i}] {backup}")
        
    while True:
        try:
            selection = input("\nSeleccione el número del backup a restaurar o 'c' para cancelar: ")
            if selection.lower() == 'c':
                print("❌ Restauración CANCELADA por el usuario.")
                cleanup()
                sys.exit(0)
            
            selection_index = int(selection)
            if 0 <= selection_index < len(backups):
                break
            else:
                print("⚠️ Número fuera del rango. Intente de nuevo.")
        except ValueError:
            print("⚠️ Entrada no válida. Ingrese un número o 'c' para cancelar.")
            
    selected_filename = backups[selection_index]
    remote_file_path = f"{remote_project_path}/{selected_filename}"
    print(f"✅ Archivo a descargar: {selected_filename}")

    # --- 4. Verificación de Espacio en Disco ---
    print(f"\n🔍 Verificando espacio en disco...")
    
    # 4.1 Obtener tamaño del archivo remoto
    size_command = ['ssh', '-F', ssh_config_temp,
                    '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no',
                    ssh_alias, f"stat -c %s {remote_file_path}"]
    
    try:
        result = subprocess.run(size_command, capture_output=True, text=True, check=True)
        remote_file_size = int(result.stdout.strip())
        remote_file_size_gb = remote_file_size / (1024**3)
        print(f"📦 Tamaño del archivo remoto: {remote_file_size_gb:.2f} GB")
    except subprocess.CalledProcessError as e:
        print(f"❌ ERROR: No se pudo obtener el tamaño del archivo remoto.")
        print(f"Mensaje de error: {e.stderr.strip()}")
        cleanup()
        sys.exit(1)
    except ValueError:
        print(f"❌ ERROR: Respuesta inválida al obtener tamaño del archivo.")
        cleanup()
        sys.exit(1)
    
    # 4.2 Obtener espacio disponible en el disco local
    try:
        stat = os.statvfs(local_recover_path)
        available_space = stat.f_bavail * stat.f_frsize  # Espacio disponible en bytes
        available_space_gb = available_space / (1024**3)
        print(f"💾 Espacio disponible en {local_recover_path}: {available_space_gb:.2f} GB")
    except Exception as e:
        print(f"❌ ERROR: No se pudo obtener información del espacio en disco: {e}")
        cleanup()
        sys.exit(1)
    
    # 4.3 Calcular espacio que quedará libre después de la descarga
    MIN_FREE_SPACE = 10 * (1024**3)  # 10 GB en bytes
    MIN_FREE_SPACE_GB = 10
    space_after_download = available_space - remote_file_size
    space_after_download_gb = space_after_download / (1024**3)
    
    print(f"📊 Espacio libre después de descarga: {space_after_download_gb:.2f} GB")
    
    # 4.4 Verificar si hay suficiente espacio
    if space_after_download < MIN_FREE_SPACE:
        print(f"\n❌ ERROR: ESPACIO INSUFICIENTE EN DISCO")
        print(f"   Espacio requerido: {remote_file_size_gb:.2f} GB (archivo)")
        print(f"   Espacio disponible: {available_space_gb:.2f} GB")
        print(f"   Espacio libre después: {space_after_download_gb:.2f} GB")
        print(f"   Mínimo requerido libre: {MIN_FREE_SPACE_GB} GB")
        print(f"\n   Necesitas liberar al menos {(MIN_FREE_SPACE - space_after_download) / (1024**3):.2f} GB")
        print(f"   antes de poder descargar este backup.")
        cleanup()
        sys.exit(1)
    
    print(f"✅ Espacio suficiente verificado (quedarán {space_after_download_gb:.2f} GB libres)")

    # --- 5. Transferencia (SCP) ---
    print(f"\nIniciando transferencia de {selected_filename} a {local_recover_path}...")
    
    # *** USAR -F PARA LA CONFIGURACIÓN TEMPORAL ***
    scp_command = ['scp', '-F', ssh_config_temp, 
                   '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', 
                   f"{ssh_alias}:{remote_file_path}", f"{local_recover_path}/"]

    try:
        subprocess.run(scp_command, check=True)
        print(f"\n✅ Transferencia SCP completada exitosamente. El archivo ha sido copiado a {local_recover_path}.")
    except subprocess.CalledProcessError as e:
        print(f"\n❌ ERROR: Fallo en la transferencia SCP. Detalles: {e}")
        cleanup()
        sys.exit(1)

    # --------------------------------------------------------------------
    # --- 6. Confirmación de Restauración de Base de Datos ---
    # --------------------------------------------------------------------
    
    # 6.1 Pregunta de confirmación inicial
    confirm_restore = input(f"\n⚠️ ADVERTENCIA: ¿Desea proceder a RESTAURAR este backup en la DB '{POSTGRES_DBNAME}'? (si/no): ").lower()
    
    if confirm_restore != "si":
        print("❌ Restauración CANCELADA por el usuario.")
        cleanup()
        sys.exit(0)

    # 6.2 Bucle de Doble Confirmación del Nombre de la DB
    while True:
        user_db_input = input(f"🔒 **CONFIRME** el nombre de la DB '{POSTGRES_DBNAME}' para continuar la restauración: ").strip()
        
        # 6.3 Comprobación del nombre
        if user_db_input == POSTGRES_DBNAME:
            print(f"✅ Nombre de DB confirmado: **{POSTGRES_DBNAME}**")
            
            # --- Ejecución de restore.sh ---
            print("▶️ Iniciando la ejecución de restore.sh...")
            # Usa ruta absoluta para evitar errores de CWD
            restore_command = ['/srv/scripts/backups/restore.sh', f"{local_recover_path}/{selected_filename}"]
            
            try:
                subprocess.run(restore_command, check=True)
                print("\n🎉 ¡ÉXITO! El script 'restore.sh' se ejecutó exitosamente.")
                
            except subprocess.CalledProcessError as e:
                print(f"\n❌ ERROR: Fallo en la ejecución de 'restore.sh'. Código de salida: {e.returncode}")
                print("Revise la salida y los logs de 'restore.sh' para más detalles.")
                
            break
            
        else:
            # 6.4 Si la confirmación del nombre falla
            print("\n❌ Nombre de DB incorrecto o vacío.")
            
            retry_input = input("¿Desea intentar de nuevo? (si/no): ").lower()
            
            if retry_input != "si":
                print("\n❌ Restauración de Base de Datos **CANCELADA** por el usuario después de la verificación fallida.")
                break

    print("\nProceso de recuperación finalizado.")
    cleanup() # Ejecutar limpieza al finalizar la lógica de Python

if __name__ == "__main__":
    run_recovery_selector()