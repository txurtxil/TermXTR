# Changelog

## v2.10.0 (2026-10-09)

### Grupos de hosts
- Los hosts se organizan en grupos libres ("Desarrollo", "Produccion"...).
  Los grupos son un campo del host: cero migracion, los hosts existentes
  quedan en "Sin grupo".
- Pantalla de hosts: secciones colapsables por grupo con contador y color.
  Mantener pulsada una cabecera: renombrar, cambiar color, exportar solo
  ese grupo o eliminarlo (sus hosts pasan a "Sin grupo").
- Menú del host: "Mover a grupo..." (existente o nuevo). El editor de host
  tiene desplegable de grupo + boton para crear uno nuevo al vuelo.
- Boton de carpeta en la AppBar: gestor de grupos (conteo, color, renombre,
  borrado).
- Colores por grupo persistentes en ssh_groups.json; si no hay color
  guardado, se deriva uno determinista del nombre (mismo nombre = mismo
  color en cualquier dispositivo). El buscador tambien filtra por grupo.

### Backup/export mejorado (esquema v3)
- Exportar todo o un solo grupo (termxtr_hosts_<grupo>.json).
- Import con preview: clasifica cada host como nuevo / actualizable (mismo
  id) / duplicado (misma maquina, otro id) y deja elegir: omitir
  duplicados, actualizarlos o importar todo como nuevos. Antes de escribir
  nada.
- El backup incluye groupMeta (colores) y sigue leyendo backups v2 (sin
  grupos). Formato versionado: "version": 3.

### Fixes
- BUG REAL heredado: 5 strings con el escape \$ en el fuente hacian que
  la interpolacion no ocurriera. El backup v2.4.0 NUNCA exportaba ni
  restauraba snippets (la ruta '${AppPaths.base}' no interpolaba) y 3
  textos mostraban '${h.name}' literal. Corregido en hosts_screen.dart;
  mismo patron corregido en transfer_engine.dart, multi_exec_screen.dart
  y snippets_screen.dart (mensajes de error).

### Pendiente de probar en dispositivo
- Crear/mover/renombrar/borrar grupos; colapsar secciones.
- Exportar por grupo; import de backup v3 con duplicados (las 3
  estrategias); import de backup v2 antiguo.
- Backup de snippets de verdad (antes salia vacio siempre).


## v2.9.0 (2026-10-07)

### Versión Windows de escritorio
- La app compila y corre en Windows: mismo gestor de hosts SSH/SFTP,
  pestañas, editor SFTP, grabadora, portapapeles, keybar, sugerencia
  fantasma, ProxyJump, historial por host, transferencias y backup.
- Ajustes de Android (keepalive, optimización de batería) y widget de
  escritorio ocultos automáticamente fuera de Android; los canales
  nativos no se tocan en Windows (sin MissingPluginException).
- Build del binario Windows vía GitHub Actions (runner windows-latest):
  al etiquetar v* se genera `termxtr-windows-<tag>.zip` y se adjunta a
  la release. Descomprimir y ejecutar `linux_container.exe` (SmartScreen:
  «Más información → Ejecutar de todas formas», binario sin firmar).
- Los datos viven en `%APPDATA%\com.example\linux_container\xtr`; los
  JSON de backup de hosts de Android se importan igual.


## v2.8.0 (2026-09-30)

### Gestión de energía remota
- Menú de cada host: "Apagar equipo" y "Reiniciar equipo" (con
  confirmación) vía SSH + sudo.
- "Preparar apagado sin contraseña (una vez)": instala la regla sudoers
  NOPASSWD (/etc/sudoers.d/termxtr-power) usando la contraseña una sola
  vez; después apagar/reiniciar no pide nada.
- Detección de éxito: si la conexión se corta, el comando se aplicó.

### Wake-on-LAN (preparado para usar)
- Guardar la MAC del equipo en su perfil (menú del host, validada).
- "Encender (Wake-on-LAN)": magic packet UDP (x2) por broadcast o IP
  dirigida. Requiere estar en la LAN del equipo (o reenvío de puertos).

### v2.7.0 (incluido en este release)
- ProxyJump: "Conectar a través de..." en el menú del host; el transporte
  es un canal direct-tcpip por el host salto. Solo en terminal por ahora
  (los otros motores avisan con mensaje claro).


## v2.6.0 (2026-09-29)

### Transferencias entre equipos con telemetría en vivo
- En el explorador SFTP: menú de cada fichero → "Enviar a otro equipo...":
  eliges host destino y carpeta, y la app transfiere el fichero en
  streaming (store-and-forward por chunks de 256 KB, sin cargarlo entero
  en memoria) usando tu identidad Ed25519.
- Cola de transferencias (icono ⇄ en la pantalla de Hosts): barra de
  progreso, velocidad actual (ventana móvil) y media, %, bytes
  transferidos/totales, tiempo transcurrido y ETA en vivo.
- Cancelar entre chunks y limpiar terminadas.


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
