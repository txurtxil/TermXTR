# Changelog

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
