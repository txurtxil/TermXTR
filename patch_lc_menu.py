import os

found = False
# Buscar lc-menu tanto en el rootfs como en el código fuente de Flutter
for root, dirs, files in os.walk('.'):
    if 'lc-menu' in files or 'lc_menu.sh' in files:
        path = os.path.join(root, 'lc-menu') if 'lc-menu' in files else os.path.join(root, 'lc_menu.sh')
        found = True
        print(f"[+] Menú encontrado en: {path}")
        
        with open(path, 'r') as f:
            content = f.read()
        
        # Inyectar la opción de compilación si no está presente
        if 'install_llama' not in content:
            with open(path, 'a') as f:
                f.write('\n# --- Añadido automáticamente ---\n')
                f.write('echo ">> Ejecuta: install_llama para descargar y compilar llama.cpp desde 0."\n')
                f.write('alias compilar-llama="install_llama"\n')
            print(" -> Modificado para incluir el comando 'install_llama' / alias 'compilar-llama'.")
        else:
            print(" -> El menú ya incluye la integración de Llama.")

if not found:
    print("[!] 'lc-menu' no se ha encontrado como fichero de script.")
    print("    Si lc-menu es una pantalla de Flutter, asigna directamente la ejecución")
    print("    del comando bash 'install_llama' a la acción del botón deseado en la UI.")
