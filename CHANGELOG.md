# Changelog

## v2.5.0 (2026-09-29)

### Sugerencia fantasma de comandos (fish-style) + historial
- Historial de comandos por host, persistido en JSON (500 entradas,
  mas reciente primero, sin duplicados).
- Barra bajo el terminal: lo tecleado en blanco y el resto del comando
  previsto en gris difuminado y cursiva (el ultimo comando del historial
  que empieza por lo escrito).
- Aceptar con un toque sobre la barra o con la tecla TAB: envia el resto
  al shell como si lo teclearas.
- Soporta pegados multilinea, backspace y Ctrl-C.

### v2.4.0 (incluido)
- Backup completo hosts+snippets (termxtr_backup.json).
- Túneles guardados con reactivación en un toque.

## v2.3.0 (2026-09-29)

### Túneles SSH (port forwarding local, tipo `ssh -L`)
- Nuevo gestor de túneles (menú de la pantalla de Hosts): cada túnel es un
  ServerSocket local en 127.0.0.1 que reenvía tráfico a cualquier destino
  alcanzable por el servidor SSH (direct-tcpip).
- Puerto local 0 = asignación automática (se muestra el puerto real).
- Conexión SSH propia por túnel con fallback a la identidad Ed25519 de la app
  y keepalive de 15 s.
- Estado en vivo: activo/error, uptime, botón detener.
- Limpieza completa de sockets, canales y suscripciones al detener.

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
