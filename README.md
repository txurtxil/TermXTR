# XTR Terminal — LinuxContainer

**Un contenedor Debian completo con un agente IA autónomo, corriendo 100% en local en tu Android.**

XTR Terminal es una app Flutter que ejecuta Debian Linux (vía proot) dentro de un dispositivo Android, con un agente de IA autónomo que usa la **GPU del teléfono** como cerebro. Sin nube, sin cuentas, sin límites: tu móvil es el servidor.

![version](https://img.shields.io/badge/version-13.3-blue) ![platform](https://img.shields.io/badge/platform-Android-green) ![license](https://img.shields.io/badge/license-MIT-orange)

---

## ✨ Qué es capaz de hacer

- 🧠 **Agente IA autónomo** — le das un *objetivo* ("escanea mi red y hazme un informe") y él solo planifica, ejecuta comandos, corrige errores y te entrega el resultado. Bucle agentic con hasta 15 pasos y auto-recuperación ante fallos.
- 🐧 **Debian completo en proot** — terminal bash real con root, apt, Python 3, nmap, git… dentro de tu Android.
- ⚡ **LLM local por GPU** — MediaPipe sirve un modelo Gemma 3 en el propio dispositivo. Offline y privado.
- 💾 **Memoria persistente** — el agente recuerda entre sesiones (SQLite): episodios pasados, notas (`remember`/`recall`).
- 🎯 **Modo Objetivo en background** — lanza tareas largas y consulta su progreso en vivo (`/goal`, `/goal/status`).
- 🎨 **UI cuidada** — animaciones (ondas, pulso, shimmer), 11 prompts rápidos por categoría, historial de chats persistente, panel autónomo con progreso en vivo.
- 🌐 **Herramientas de red** — escaneo nmap con topología visual (Graphviz), monitor de cambios de red, informes Markdown.

## 📸 Arquitectura

```
┌─────────────────────────────────────────────┐
│  App Flutter (Android)                      │
│  ┌────────────┐      HTTP :8765             │
│  │ UI / Chat  ├───────────────────┐         │
│  └────────────┘                   ▼         │
│                        ┌──────────────────┐ │
│  Contenedor proot      │ agent_server.py  │ │
│  ┌─────────────────┐   │ (stdlib puro)    │ │
│  │ bash, python,   │◄──┤ bucle agentic    │ │
│  │ nmap, sqlite…   │   │ memoria SQLite   │ │
│  └─────────────────┘   └────────┬─────────┘ │
│                                 │ :8090     │
│                        ┌────────▼─────────┐ │
│                        │ MediaPipe (GPU)  │ │
│                        │ Gemma 3 local    │ │
│                        └──────────────────┘ │
└─────────────────────────────────────────────┘
```

## 🚀 Instalación

1. Descarga el APK para tu arquitectura desde [Releases](https://github.com/txurtxil/LinuxContainer/releases) (la mayoría de móviles: `app-arm64-v8a-release.apk`)
2. Instálala y abre la app → pestaña **Agente**
3. Pulsa ▶ para arrancar el agent-server (punto verde = listo)
4. Escribe una tarea… o pulsa 🧠 para el **Modo Autónomo**

### Herramientas de red (una sola vez)

En la terminal de la app, o pídeselo al propio agente:
> *"Instala iproute2, net-tools, iputils-ping, dnsutils, nmap y jq con apt"*

## 🧠 Modo Autónomo — ejemplos

| Le dices… | El agente… |
|---|---|
| "Escanea mi red y guarda el informe" | `ip route` → `nmap -sn` → fingerprint → mapa Graphviz + informe MD en `/root/` |
| "¿Cuánto espacio libre tengo?" | `df -h` y te resume |
| "Crea una API REST con SQLite" | Escribe el código, lo instala, lo arranca y lo prueba |
| "Recuerda que mi router es el .1" | Lo guarda en memoria persistente para futuras sesiones |

## 📡 API del agente (puerto 8765)

| Endpoint | Descripción |
|---|---|
| `POST /run` | Chat con streaming SSE (`{"task": "..."}`) |
| `POST /goal` | Objetivo autónomo en background |
| `GET /goal/status?goal_id=` | Progreso en vivo |
| `GET /goal/list` | Historial de objetivos |
| `GET /memory` | Memoria persistente |
| `GET /health` | Estado del servidor y del LLM |
| `GET /tools` | Herramientas disponibles |

## 🛠️ Desarrollo

```bash
flutter pub get
flutter build apk --release --split-per-abi
```

Estructura clave:

```
lib/src/agent/        → UI del agente (dashboard, chat, panel autónomo)
assets/agent_server.py → servidor del agente (stdlib Python, cero pip)
assets/rootfs_overlay/ → scripts del contenedor (menú TUI, escaneo de red)
scripts/start_agent.sh → arranque del agente
```

## 📋 Changelog

### v13.3 — Definitiva ✅ (actual)
- Server reescrito en **stdlib pura** (sin pip/fastapi/httpx): funciona siempre
- Contrato SSE exacto con el cliente (`task`, `type: step/final/error`)
- Dashboard v10.0: UI completa (animaciones, prompts, ajustes) + **panel autónomo** 🧠
- Overrides de LLM por petición (base_url / model / api_key)

### v13.x — Agente autónomo
- Bucle agentic (plan → ejecuta → observa → decide), memoria SQLite, modo goal, logs JSONL

### v12.x — Base
- Streaming SSE, system prompt optimizado para Gemma, scripts de red, 11 prompts rápidos

---

**Dispositivo de referencia**: Samsung Galaxy Z Fold 7 · **Licencia**: MIT · **Autor**: [@txurtxil](https://github.com/txurtxil)
