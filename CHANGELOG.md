# Changelog

## v2.2.0 (2026-09-29)

### Identidad SSH automatizada (adios a teclear claves)
- Par de claves Ed25519 generado en el dispositivo (formato OpenSSH openssh-key-v1), almacenado en el directorio de claves de la app.
- Pantalla 'Identidad SSH' (icono llave en Hosts): ver/copiar la clave publica, regenerar con confirmacion.
- Menu de 3 puntos en cada host: 'Enviar clave publica' — pide la contrasena UNA vez, instala la clave en authorized_keys (idempotente, sin duplicados) y a partir de entonces ese host no pide contrasena.
- Fallback automatico: los hosts sin clave propia intentan autenticar con la identidad de la app (terminal, multi-exec y snippets).

### Snippets de comandos
- Guarda comandos reutilizables (icono rayo en Hosts), ejecucion con un toque en el host elegido, resultado en dialogo con salida seleccionable.


## v2.1.0 (2026-09-29)

### Editor potente (reescrito)
- Buscar y reemplazar: siguiente, reemplazar uno, reemplazar todos, toggle mayusculas/minusculas, wrap-around.
- Ir a linea N.
- Auto-indent: Intro hereda la indentacion de la linea anterior.
- Undo/redo (200 pasos).
- Barra de estado: Ln/Col, longitud de seleccion, palabras, tamano, codificacion (UTF-8/Latin-1), estado de modificacion.
- Seleccionar todo y copiar seleccion desde la toolbar.
- Confirmacion de cambios al salir (guardar/descartar/seguir).

### Multitarea
- Ejecucion de un comando en multiples hosts a la vez (icono ▶ en la pantalla de hosts): seleccion multiple, ejecucion concurrente, resultados en vivo con estado, duracion y salida seleccionable.
- Reutiliza el keystore cifrado de credenciales, claves PEM y keepalive de la base.


## v2.0.0 (2026-09-29)

TermXTR renace sobre la base madura de LinuxContainer 1.3.0, mejorada por un analista senior.

### Cambios
- **Eliminado el shell local (ghost)**: flutter_pty y el PTY sobre toybox no aportaban funcionalidad real en Android. Toda sesión es ahora SSH a un host gestionado.
- Al arrancar, la app ofrece directamente la lista de hosts (no crea una sesion vacia).
- Cerrar la ultima pestana reabre la lista de hosts; el boton + conecta a un host.
- Pantalla de estado vacio con acceso rapido a conectar.
- Branding: TermXTR (titulo, label Android, splash de arranque).

### Mejoras sobre la base LinuxContainer
- **Editor SFTP potente**: busqueda con salto al siguiente resultado (wrap-around), toggle de ajuste de linea.
- Conservado todo lo bueno de la base: known_hosts con politica accept-new y rechazo de huella cambiada, keystore cifrado de credenciales, pool de conexiones SFTP, favoritos SFTP, grabadora de terminal, vault de portapapeles, keybar configurable, seleccion con handles.

### Notas
- Las claves PEM sin passphrase siguen siendo requisito (heredado de la base).
