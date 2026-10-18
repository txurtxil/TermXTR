# Pendientes (editable, se incluye en el prompt de estado)

## Siempre abiertos
- Probar cada release en dispositivo real (Fold 7) y en Windows 11.
- Decision de firma de codigo (SmartScreen) pendiente del usuario.
- CAMBIAR la contrasena historica de z1 (quedo expuesta en un chat
  antiguo). La nueva vive solo en el gestor de credenciales.

## v2.11.x (parcialmente probado)
- WOL: CONFIRMADO funcionando desde el Samsung (fix v2.11.3).
- Pendiente: auditoria "servicios" en host con sudo (ss -p muestra
  procesos) y sin el; parseo netstat; mapa con varios hosts auditados.
- Pendiente: colores del icono energia en encendido/apagado real
  (latencia WOL + re-chequeo a los 10 s).
- Pendiente: copiar/pegar nuevo (seleccion permanece, feedback) en
  terminal real.
- Pendiente: backup v3 con snippets reales (fix escapes v2.10.0) en
  dispositivo.
- Pendiente: import v3 con duplicados (3 estrategias) + backup v2 viejo.

## Hardware bc250
- Entra a BIOS tras forzosos/cortes (boot failure guard; sin opcion
  Restore AC en AMI 2.18.1263). Si se repite: kdump en Kubuntu para
  cazar colgones; UPS para cortes de luz. NO apagar z1 por WOL: ninguna
  NIC lo soporta.

## Roadmap
- Escritorio remoto Windows integrado (RDP via FreeRDP FFI, spike).
- VNC descartado por ahora (decision del usuario).
- Firmar exe de Windows (Azure Trusted Signing u OV).
- Mejora seleccion: arrastre de asas mas fluido.
- Opcional: CI que dispare gen_prompt_estado.sh en cada tag.
