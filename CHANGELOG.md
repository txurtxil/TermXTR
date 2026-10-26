# Changelog


## v2.15.1 (2026-10-26)

### Eliminado todo lo GitHub (decision del usuario tras probarlo)
- "No es util tener github en esta herramienta" (usuario, tras un dia de
  uso real): se elimina COMPLETO el apartado GitHub de TermXTR.
- Fuera: pantalla GitHub - SSH (v2.14.x), consola gh (v2.15.0), entrada
  "GitHub · SSH" del menu ... de Hosts, host auto-creado git@github.com
  (el usuario lo borra manualmente de su lista; el codigo ya no lo crea).
- SE CONSERVA el fix v2.14.2 de IdentityService (checkints openssh-key-v1
  iguales + auto-verificacion): es un bug real del auth por clave para
  TODOS los hosts, no es de GitHub. Destapado gracias al apartado GitHub,
  que cumplio su mision de diagnostico aunque la feature no se quedara.
- Leccion: no todo lo que se construye se queda; el canon guarda el
  recorrido completo (fallo -> diagnostico -> fix real -> feature
  descartada por el usuario).

## v2.15.0 (2026-10-26)

### Consola gh — gestionar GitHub desde la app (opcion B encargada)
- Nueva pantalla "GitHub · Consola gh" (entrada desde GitHub · SSH):
  se conecta por SSH al host elegido (z1 por defecto, donde gh ya esta
  autenticado como txurtxil) y ejecuta comandos gh de SOLO LECTURA.
- Receta de conexion copiada de _auditHost (probadisima): contrasena desde
  SshCredentialsStore con prompt + opcion "Recordar", keyPath del host o
  identidad de la app como fallback, known_hosts accept-new anti-MITM,
  reconexion automatica si el canal cae, cliente cerrado al salir.
- Acciones (todas verificadas en z1, RC=0, no interactivas): Auth
  (gh auth status), Repos (gh repo list), Mis PRs (gh search prs
  --author=@me), Mis issues (gh search issues --assignee=@me), Releases y
  CI runs sobre un campo usuario/repo (gh release list / gh run list).
  gh pr/issue status descartados: exigen estar dentro de un repo git.
- Resultados en tarjeta verde/rojo con texto monoespaciado seleccionable y
  boton copiar. dartssh2 3.3.1: run() devuelve solo stdout; se usa
  runWithResult() para stdout+stderr+exitCode.
- Contexto: el usuario recordaba haber "hecho login por otro camino" — era
  gh CLI (clave githubcli de su cuenta, anadida via personal access token).
  Dispositivo actual: Xiaomi 15 Ultra (Fold 7 retirado, canon ya al dia).

## v2.14.4 (2026-10-26)

### Probar conexion GitHub: la autenticacion ES la prueba (diseno robusto)
- v2.14.3 abrio la shell sin pty pero el parseo del banner seguia fragil:
  se completaba el futuro con el PRIMER chunk de stdout y GitHub puede
  partir el banner en varios mensajes de canal o mandarlo por stderr ->
  "Conectado pero sin banner de GitHub (respuesta inesperada)".
- Redisenado: superar client.authenticated contra git@github.com ya es la
  prueba (GitHub solo autentica claves registradas). El banner "Hi
  usuario!" es bonus: se acumula stdout+stderr hasta regex-match / cierre
  de canal (shell.done) / 6s, y da el nombre de usuario si es legible.
  Sin banner = igualmente verde ("GitHub acepto la clave publica").
- Errores de sintaxis del parche (regex con CR/LF literales por string no
  raw; whenComplete metido en lista de subscriptions) pillados por
  dart analyze en z1 antes de compilar: verificar siempre, no asumir.

## v2.14.3 (2026-10-26)

### Probar conexion contra GitHub: sin pty + UX de sesion corregida
- "Probar conexion" pedia pty (client.shell() con SSHPtyConfig por defecto)
  y GitHub la rechaza SIEMPRE: no hay shell interactivo. El error
  ("SSHChannelRequestError: Failed to start pty") saltaba DESPUES de una
  autenticacion correcta, confundiendo el diagnostico. Ahora shell(pty:
  null), como `ssh -T git@github.com`: GitHub contesta el banner
  "Hi usuario!" y se parsea igual.
- Mapeo robustez: si aun asi llega un SSHChannelRequestError, se informa
  como "autenticacion superada; GitHub no acepta shell" en vez de rojo
  crudo.
- Seccion "Sesion": GitHub no da shell interactivo, asi que el boton
  "Abrir sesion GitHub (banner de auth)" era un callejon sin salida
  garantizado (la terminal siempre pediria pty). Sustituido por texto
  explicativo; GithubScreen ya no recibe onOpenTerminal.
- Confirmado en dispositivo (Fold 7): tras regenerar la identidad (v2.14.2)
  la autenticacion contra git@github.com ya pasa; el error era solo el pty.

## v2.14.2 (2026-10-26)

### FIX CRITICO: identidad SSH invalida desde v2.2.0 (BUG REAL ENCONTRADO EN DIAGNOSTICO)
- Sintoma en cadena: (1) sesion GitHub -> SSHAuthFailError; (2) pantalla
  GitHub -> "Probar conexion" -> "Sin identidad SSH en la app".
- Causa raiz (verificada en z1 con la pila dartssh2 pinneada + ssh-keygen
  real): el escritor openssh-key-v1 de IdentityService.ensureIdentity()
  generaba los DOS checkints con valores aleatorios DISTINTOS. El formato
  exige que sean IGUALES (verificacion de integridad), asi que la clave
  privada quedaba estructuralmente invalida: fromPem lanzaba
  SSHKeyDecryptError y loadIdentity() devolvia null. La publica se
  construia aparte (valida) -> la UI mostraba una clave "buena" que GitHub
  aceptaba, pero la app nunca pudo firmar con ella. El password de los
  hosts tapo el fallo en silencio desde v2.2.0: la identidad como auth nunca
  funciono en dispositivo.
- Fix: checkints iguales + auto-verificacion (fromPem tras generar; si
  falla, borra los ficheros y lanza StateError en vez de romper en
  silencio).
- Consecuencia para el usuario: la identidad existente en el telefono es
  invalida e IRREPARABLE -> hay que REGENERAR en la pantalla Identidad SSH.
  La clave publica cambia: reemplazar la entrada en GitHub y reinstalar
  la identidad en cualquier host donde se hubiera instalado
  (authorized_keys).
- Leccion canonica: un componente que "parece funcionar" (pub visible)
  puede estar roto silenciosamente detras (priv no parseable). Verificar
  con la misma pila que consume el componente.

## v2.14.1 (2026-10-26)

### Diagnostico de clave GitHub (autoinstalable)
- La tarjeta Identidad de la pantalla GitHub ahora muestra la HUELLA
  SHA256:... de la clave de la app (mismo formato que GitHub -> Settings ->
  SSH keys) para comparar con la entrada registrada en GitHub.
- Mapeo especifico de SSHAuthFailError: "GitHub rechazo la clave publica"
  con instruccion de comparar huellas y reemplazar la entrada en GitHub si
  difieren (causa tipica: regenerar la identidad en la pantalla Identidad
  DESPUES de anadir la clave a GitHub).
- Motivacion: primer uso real en dispositivo dio SSHAuthFailError con la
  clave en GitHub marcada "Never used" = la clave presentada no era la
  registrada. Con la huella visible el diagnostico es inmediato.

## v2.14.0 (2026-10-26)

### Apartado GitHub (nueva pantalla)
- Entrada: menu ... de Hosts -> "GitHub · SSH".
- Identidad: estado de la clave Ed25519 de la app + boton "Copiar clave
  publica" (linea OpenSSH lista para pegar en github.com/settings/keys).
- Conexion: "Probar conexion" abre un SSH real en segundo plano a
  git@github.com:22 con la misma pila dartssh2 de las sesiones y parsea el
  banner "Hi usuario!". Resultado verde/rojo con la causa probable mapeada:
  clave no registrada, huella cambiada (anti-MITM via known_hosts),
  timeout (con consejo de ssh.github.com:443 para redes que bloquean el
  22), sin red.
- Snippets: escribe usuario/repo y toca Clonar/Pull/Push/Fetch -> comando
  completo con la URL SSH montada, copiado al portapapeles.
- "Abrir sesion GitHub": terminal normal al host; GitHub imprime el banner
  de autenticacion y corta (la comprobacion "a ojo" clasica).
- El host git@github.com se crea solo la primera vez (id fijo
  'gh-github', grupo 'GitHub') y convive con la lista de hosts: SFTP,
  terminal, backup y widget lo tratan sin codigo especial.

## v2.13.12 (2026-10-26)

### Fix seleccion desplazada: ejes X/Y rotos al usar el portapapeles (BUG REAL)
- Sintoma (reportado por el usuario): la seleccion funcionaba perfecto pero
  con el uso se descuadraba; clic arriba seleccionaba abajo. Solo se curaba
  cerrando la sesion y entrando de nuevo, y cada vez fallaba antes.
- Causa: _focusNodes y _viewKeys en terminal_view.dart estaban indexados por
  POSICION de pestana (putIfAbsent(i)) y _closeSession nunca los limpiaba.
  Al cerrar una pestana intermedia, las sesiones supervivientes heredaban el
  FocusNode y el GlobalKey de OTRA sesion: el overlay de seleccion
  (selection_overlay_termux.dart) hablaba con el renderTerminal equivocado
  y mapeaba celda<->pixel con la geometria de otra pestana. Cada ciclo
  cerrar/reconectar mezclaba mas estado (por eso fallaba cada vez antes).
- Fix: los dos mapas pasan a clavarse por IDENTIDAD de sesion
  (Map<TerminalSession, ...>), con limpieza real en _closeSession y el
  requestFocus del ciclo de vida apuntando a la sesion activa.
- Nota: la geometria base del overlay (getOffset/getCellOffset/localToGlobal)
  se verifico contra el fuente de xterm 4.0.0 pinneado (sha256 del
  pub-cache) y es consistente; no era un problema de calibracion.
- Matiz conocido que NO se toca en esta version: xterm pinta cada linea en
  posicion Y truncada a entero mientras el mapeo de toques usa pizeles
  fraccionales; con offsets de scroll fraccionales puede dar un error de
  +-1 linea. Se vigila; si el drift persiste tras esta version se
  instrumenta (log de cellSize/scrollOffset en el recorder).

### Pendiente de probar en dispositivo
- Seleccionar/copiar con varias pestanas abiertas: cerrar una intermedia y
  comprobar que la seleccion sigue fiel en las que quedan (Fold 7).
## v2.11.3 (2026-10-16)

### Fix Wake-on-LAN definitivo: faltaba SO_BROADCAST (BUG REAL)
- Diagnostico con tcpdump en z1: el paquete del movil NUNCA llegaba a la
  red aunque la app dijera "Magic packet enviado".
- Causa: RawDatagramSocket de Dart no activaba el flag de broadcast
  (SO_BROADCAST). En Linux/Android, enviar a una direccion broadcast sin
  ese flag NO lanza excepcion: send() devuelve 0 y el datagrama muere en
  silencio dentro del telefono. El wol.py de z1 si ponia el flag; por
  eso funcionaba desde z1 y no desde la app.
- Fix: udp.broadcastEnabled = true + se comprueba el retorno de send()
  (3 intentos). Si el sistema rechaza el envio, la app lo dice de verdad.
- Nota: los fixes anteriores de v2.11.1/2.11.2 (broadcast de subred +
  255.255.255.255) siguen aplicando; este era el fallo que los tapaba.

### Pendiente de probar en dispositivo
- Encender un host de la LAN desde el movil con la v2.11.3 (misma Wi-Fi).


## v2.11.2 (2026-10-16)

### Apagado/reinicio mas seguros
- La confirmacion de apagar/reiniciar (icono de energia o menu) ahora es
  explicita: icono de advertencia y texto que recuerda que APAGAR no tiene
  vuelta atras (solo WOL o fisicamente). Antes el dialogo era facil de
  aceptar sin leer.

### Nota Wake-on-LAN desde movil
- El fix de v2.11.1 (magic packet por broadcast) es imprescindible para
  que funcione desde el movil: las APKs anteriores enviaban dirigido a la
  IP, que falla con la maquina apagada.


## v2.11.1 (2026-10-16)

### Fix Wake-on-LAN (fallaba con la maquina apagada)
- BUG REAL: el magic packet se enviaba DIRIGIDO A LA IP del host. Con la
  maquina apagada la ARP no resuelve y el paquete se descarta: nunca
  llegaba. Ahora se envia por BROADCAST: al broadcast dirigido de la
  subred /24 deducido del hostname (p.ej. 192.168.10.255 para un host
  192.168.10.x) y ademas al broadcast general 255.255.255.255, para
  cubrir routers que filtran el general.

### Checklist si el WOL sigue sin funcionar (nada en la app lo arregla)
- El equipo debe estar por CABLE (el Wi-Fi del equipo no despierta).
- BIOS/UEFI: "Wake on LAN" / "Power on by PCIe" activo; si no despierta
  desde apagado (S5), desactivar ErP/EuP.
- SO: ethtool eth0 | grep Wake-on  -> debe decir "g". Si dice "d":
  sudo ethtool -s eth0 wol g  (y persistirlo: se resetea al reiniciar).
- El telefono debe estar en la misma red (sin VLAN, sin red de invitados,
  y el AP sin "aislamiento de clientes" que bloquee el broadcast).

### Pendiente de probar en dispositivo
- Encender un equipo real apagado desde la app (misma Wi-Fi/LAN).


## v2.11.0 (2026-10-16)

### Icono de energia con estado real (encender/apagar)
- El icono de la fila del host ahora refleja accesibilidad: VERDE = el
  equipo responde (tocarlo APAGA, con la confirmacion existente),
  ROJO = no responde (tocarlo ENCIENDE por Wake-on-LAN), gris = aun
  sin comprobar. Se rechequea solo cada 30 s (TCP-check de 2 s al
  puerto del host) y tras encender/apagar.

### Auditar servicios (menu de 3 puntos de cada host)
- Conecta por SSH con las mismas credenciales/claves que la terminal
  (politica known_hosts igual: accept-new; huella cambiada = error
  explicito) y ejecuta ip route + ip addr + ip neigh + ss -tulpn.
- Guarda gateway, IP LAN, vecinos ARP y servicios escuchando en el
  perfil del host (campo audit, incluido en el backup/export).

### Mapa de hosts (Hosts -> ... -> Mapa de hosts)
- Routers arriba, tarjetas de host abajo, lineas de conexion medidas en
  el layout real. Cada tarjeta: nombre, IP, franja de color de grupo,
  un LED por servicio (color segun tipo de puerto: 22 verde, web azul,
  BD morado...), gateway y "Conecta con: ..." cruzando ARP entre hosts.
- Tocar una tarjeta abre el detalle completo (servicios y tabla ARP).
- Las tarjetas se rellenan con "Auditar servicios"; sin auditar se ven
  en gris con el consejo.

### Interno
- loadKnownHosts/saveKnownHosts pasan a ser publicos y estaticos
  (los comparten terminal, auditoria y futuras piezas).

### Pendiente de probar en dispositivo
- Colores del icono al encender/apagar de verdad (latencia del WOL).
- Auditoria en un host con sudo (ss -p muestra procesos) y sin el.
- Mapa con varios hosts auditados: lineas, LEDs y "conecta con".


## v2.10.2 (2026-10-16)

### Wake-on-LAN visible
- Icono de encendido directo en la fila del host (verde) cuando el host
  tiene MAC guardada. Ya no hace falta abrir el menu de 3 puntos; el menu
  conserva la opcion igualmente.

### Copiar / pegar en terminal
- Copiar YA NO borra la seleccion (igual que Termux): permite re-copiar o
  ampliar y copiar de nuevo; se limpia tocando fuera o con la X de la
  barra.
- Feedback al copiar: "Copiado (N caracteres)" + vibracion corta.
- Feedback al pegar: "Pegado (N caracteres)"; si el portapapeles esta
  vacio avisa en vez de hacerlo en silencio.

### Pendiente de probar en dispositivo
- Boton de encendido en la fila (con MAC guardada) y apagado/reinicio.
- Copiar (seleccion permanece) y pegar con/sin contenido en portapapeles.


## v2.10.1 (2026-10-11)

### Diagnostico de conexiones: huella cambiada vs error generico
- Cuando la huella SSH del servidor cambia respecto a la guardada, la
  terminal ahora dice exactamente eso (host:puerto) y como arreglarlo,
  en vez del enganoso "Connection closed before authentication".
- Menu Hosts -> ... -> "Hosts conocidos (SSH)": lista las huellas
  guardadas (accept-new), permite ver la huella completa (tocar), copiarla
  (mantener) y borrarla. Al reconectar, la entrada se acepta y regenera
  sola.
- Contexto: el rechazo ante huella cambiada es intencional (anti-MITM);
  lo que faltaba era el mensaje claro y la forma de limpiar sin
  reinstalar la app.

### Pendiente de probar en dispositivo
- Reproducir el caso real (huella cambiada) y confirmar el mensaje nuevo.
- Borrar una entrada desde la nueva pantalla y reconectar (accept-new).


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
