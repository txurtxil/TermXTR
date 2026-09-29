import os

pubspec_path = "pubspec.yaml"
if os.path.exists(pubspec_path):
    with open(pubspec_path, "r") as f:
        lines = f.readlines()

    assets_idx = -1
    for i, line in enumerate(lines):
        if line.strip() == "assets:":
            assets_idx = i
            break

    if assets_idx != -1:
        existing_content = "".join(lines)
        # Rutas estrictas que Flutter necesita conocer
        to_add = [
            "    - assets/rootfs_overlay/root/agent/\n",
            "    - assets/rootfs_overlay/usr/local/bin/\n"
        ]
        
        insert_idx = assets_idx + 1
        added_something = False
        for line_to_add in to_add:
            if line_to_add.strip() not in existing_content:
                lines.insert(insert_idx, line_to_add)
                insert_idx += 1
                added_something = True
                
        if added_something:
            with open(pubspec_path, "w") as f:
                f.writelines(lines)
            print("[OK] pubspec.yaml parcheado correctamente con las nuevas carpetas.")
        else:
            print("[OK] Las carpetas ya estaban en pubspec.yaml.")
else:
    print("[ERROR] pubspec.yaml no encontrado.")
