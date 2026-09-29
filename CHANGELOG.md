# Changelog

## v1.1.0 (2026-09-29)

### Novedades
- **Gestion de hosts SSH**: perfiles con nombre, host, puerto, usuario y autenticacion por password o clave privada PEM (CRUD completo, persistencia local).
- **Terminal SSH real**: conexion remota interactiva (dartssh2) con pty xterm, resize y reconexion.
- **Explorador SFTP**: navegar, descargar, subir, crear/renombrar/eliminar ficheros y carpetas.
- **Editor de texto**: abrir y guardar ficheros locales y remotos (via SFTP), undo/redo, aviso de cambios sin guardar.
- **Archivos locales**: gestion de ficheros en el almacenamiento de la app.
- **Ajustes**: tema claro/oscuro y tamano de fuente del editor.
- Navegacion principal con barra inferior: Terminal / Hosts / Archivos / Ajustes.

### Notas
- El agente SSH acepta cualquier host key (uso domestico).
- Las claves privadas PEM deben estar sin passphrase (pendiente de soporte).
