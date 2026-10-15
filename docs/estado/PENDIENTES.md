# Pendientes (editable, se incluye en el prompt de estado)

## Siempre abiertos
- Probar cada release en dispositivo real (Fold 7) y en Windows 11.
- Decision de firma de codigo (SmartScreen) pendiente del usuario.

## v2.11.0 (en prueba)
- Icono de energia: verde/rojo segun accesibilidad real; verificar latencia
  del WOL y el re-chequeo a los 10 s tras encender.
- Auditar servicios: con sudo (ss -p muestra procesos) y sin el; parseo de
  netstat en maquinas sin ss.
- Mapa de hosts: lineas router->host, LEDs por servicio y cruce ARP
  "conecta con" con varios hosts auditados.

## Roadmap
- Escritorio remoto Windows integrado (RDP via FreeRDP FFI, spike).
- Mejora de seleccion: arrastre de asas mas fluido (ya con setState+clamp).
- Firmar el exe de Windows (Azure Trusted Signing u OV).
