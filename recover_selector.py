import subprocess
import os
import sys

def get_postgres_dbname_from_env_file(env_path="/srv/prod/.env"):
    """
    Intenta leer POSTGRES_DBNAME directamente de un archivo .env estilo Bash.
    """
    db_name = None
    try:
        if os.path.exists(env_path):
            with open(env_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    # Ignorar comentarios y líneas vacías
                    if not line or line.startswith('#'):
                        continue
                    if line.startswith('POSTGRES_DBNAME='):
                        # Extraer el valor después del signo igual
                        parts = line.split('=', 1)
                        if len(parts) == 2:
                            db_name = parts[1].strip().strip('"').strip("'")
                            break
    except Exception as e:
        print(f"⚠️  Advertencia: No se pudo leer el archivo .env en {env_path}: {e}")
    
    return db_name

# Intenta obtener el nombre de la DB primero de las var. de entorno, luego del archivo .env
POSTGRES_DBNAME = os.environ.get("POSTGRES_DBNAME")
if not POSTGRES_DBNAME:
    POSTGRES_DBNAME = get_postgres_dbname_from_env_file()

# Fallback final si no se encuentra
if not POSTGRES_DBNAME:
    POSTGRES_DBNAME = "postgres" # Valor por defecto seguro o "unknown"

def run_recovery_selector():
    # --- 1. Carga de Variables desde el entorno de Bash ---
    instance = os.environ.get("INSTANCE")
    if not instance:
        print("⚠️ La variable de entorno 'INSTANCE' no está definida.")
        instance = input("Por favor, introduce el nombre de la instancia (INSTANCE): ").strip()
        
    if not instance:
        print("❌ ERROR: No se proporcionó ninguna instancia. Terminando.")
        sys.exit(1)

    ssh_alias = "backups"
    remote_base_path = "/home/vps"
    remote_project_path = f"{remote_base_path}/{instance}"
    
    local_recover_path = "/srv/scripts/backups" 

    # --- 2. Consulta Remota (SSH) ---
    print(f"\n--- Buscando Backups en la Carpeta Remota: {remote_project_path} ---")
    
    # Se utiliza 'ls -1t' para listar ordenado por fecha de modificación (más nuevo primero)
    ssh_command = ['ssh', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', 
                   ssh_alias, f"ls -1t {remote_project_path}"]
    
    try:
        result = subprocess.run(ssh_command, capture_output=True, text=True, check=True)
        
    except subprocess.CalledError as e:
        print("❌ ERROR: Fallo al conectar o ejecutar el comando remoto.")
        print(f"Mensaje de error SSH: {e.stderr.strip()}")
        sys.exit(1)
    
    raw_list = result.stdout.strip()
    if not raw_list:
        print(f"⚠️ ADVERTENCIA: No se encontraron archivos en la ruta: {remote_project_path}")
        sys.exit(0)
    
    backups = [line.strip() for line in raw_list.splitlines() if line.strip()]

    # --- 3. Selección del Usuario ---
    # El archivo más reciente ahora estará en el índice [1]
    print("\n--- Archivos de Backup Disponibles (Más reciente primero) ---")
    for i, filename in enumerate(backups, 1):
        print(f"[{i}] {filename}")
    print("-------------------------------------")

    while True:
        try:
            selection = input("¿Qué archivo de backup desea restaurar? (Ingrese el número): ")
            selection_index = int(selection) - 1
            if 0 <= selection_index < len(backups):
                selected_filename = backups[selection_index]
                break
            else:
                print("Selección no válida. Ingrese un número de la lista.")
        except ValueError:
            print("Entrada no válida. Ingrese solo números.")

    remote_file_path = f"{remote_project_path}/{selected_filename}"
    print(f"✅ Archivo a descargar: {selected_filename}")

    # --- 4. Transferencia (SCP) ---
    print(f"\nIniciando transferencia de {selected_filename} a {local_recover_path}...")
    
    scp_command = ['scp', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=no', 
                   f"{ssh_alias}:{remote_file_path}", f"{local_recover_path}/"]

    try:
        subprocess.run(scp_command, check=True)
        print(f"\n✅ Transferencia SCP completada exitosamente. El archivo ha sido copiado a {local_recover_path}.")
    except subprocess.CalledProcessError as e:
        print(f"\n❌ ERROR: Fallo en la transferencia SCP. Detalles: {e}")
        sys.exit(1)

    # --------------------------------------------------------------------
    # --- 5. Confirmación de Restauración de Base de Datos ---
    # --------------------------------------------------------------------
    
    # 5.1 Pregunta de confirmación inicial
    print("\n" + "="*50)
    print("⚠️ ¡ATENCIÓN! Restauración de la Base de Datos.")
    print("Esto **eliminará permanentemente** la base de datos actual. Asegúrese de tener un backup.")
    print("="*50)
    
    confirm_db_restore = input("¿Desea **restaurar** la base de datos? (escriba 'si' para continuar): ").lower()
    
    if confirm_db_restore != "si":
        print("\n❌ Restauración de Base de Datos **CANCELADA** por el usuario.")
        print("El archivo de backup fue descargado, pero NO se continuará con el proceso de restauración.")
        print("\nProceso de recuperación finalizado.")
        sys.exit(0)

    # 5.2 Bucle de Doble Confirmación del Nombre de la DB
    while True:
        print(f"\n--- Verificación de Seguridad ---")
        print(f"Base de datos a restaurar: **{POSTGRES_DBNAME}**")
        
        user_db_input = input(f"Escriba el nombre de la DB '{POSTGRES_DBNAME}' para confirmar la acción destructiva: ").strip()
        
        # 5.3 Comprobación del nombre
        if user_db_input == POSTGRES_DBNAME:
            print(f"\n✅ Nombre de DB confirmado: **{POSTGRES_DBNAME}**")
            
            # --- Ejecución de restore.sh ---
            print("▶️ Iniciando la ejecución de restore.sh...")
            restore_command = ['./restore.sh', f"{local_recover_path}/{selected_filename}"]
            
            try:
                subprocess.run(restore_command, check=True)
                print("\n🎉 ¡ÉXITO! El script 'restore.sh' se ejecutó exitosamente.")
                
            except FileNotFoundError:
                print("\n⚠️ ADVERTENCIA: No se encontró el script 'restore.sh'.")
                print("Asegúrese de que esté en la ruta correcta y tenga permisos de ejecución.")
            
            except subprocess.CalledProcessError as e:
                print(f"\n❌ ERROR: Fallo en la ejecución de 'restore.sh'. Código de salida: {e.returncode}")
                print("Revise la salida y los logs de 'restore.sh' para más detalles.")
                
            break
            
        else:
            # 5.4 Si la confirmación del nombre falla
            print("\n❌ Nombre de DB incorrecto o vacío.")
            
            retry_input = input("¿Desea intentar de nuevo? (si/no): ").lower()
            
            if retry_input != "si":
                print("\n❌ Restauración de Base de Datos **CANCELADA** por el usuario después de la verificación fallida.")
                break

    print("\nProceso de recuperación finalizado.")

if __name__ == "__main__":
    run_recovery_selector()
