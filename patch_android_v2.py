#!/usr/bin/env python3
# patch_android_v2.py — Dos correcciones sobre la tarjeta Android SDK / Dev:
#
#   1. Las cifras eran inventadas. Medido en un Z Fold7:
#        624 MB SDK + 145 MB Gradle + 474 MB cache Maven = ~1,3 GB
#        ~5 min, no 20-40.
#   2. El "aapt2 aarch64" de la tarjeta era texto fijo: se mostraba siempre,
#      sin comprobar nada. Ahora ejecuta `aapt2 version` de verdad y enseña
#      la version real — o avisa en rojo si no responde.
#
#   python3 patch_android_v2.py           aplica
#   python3 patch_android_v2.py --dry     solo enseña
#   python3 patch_android_v2.py --revert  deshace
#
# Idempotente. Backups en .bak_v2

import os
import shutil
import sys

PROJ = os.environ.get("PROJ", os.path.expanduser("~/linux_container_build"))
DRY = "--dry" in sys.argv
REVERT = "--revert" in sys.argv

G, Y, R, C, D, B, X = (
    "\033[1;32m", "\033[1;33m", "\033[1;31m",
    "\033[1;36m", "\033[2m", "\033[1m", "\033[0m",
)

def ok(m):   print(f"{G}✓{X} {m}")
def warn(m): print(f"{Y}!{X} {m}")
def die(m):  print(f"{R}✗{X} {m}"); sys.exit(1)

CARD   = os.path.join(PROJ, "lib/src/dev/android_sdk_card.dart")
SCRIPT = os.path.join(PROJ, "assets/scripts/install_android_sdk.sh")
README = os.path.join(PROJ, "README.md")

# ══════════════════════════════════════════════════════════════
#  (viejo, nuevo, etiqueta, obligatorio)
# ══════════════════════════════════════════════════════════════

CARD_EDITS = [
    # ── 1. Estado + comprobación real de aapt2 ────────────────
    (
"""class _AndroidSdkCardState extends State<AndroidSdkCard> {
  final _svc = AndroidSdkService();

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) => _svc.refresh());
  }""",
"""class _AndroidSdkCardState extends State<AndroidSdkCard> {
  final _svc = AndroidSdkService();

  // Versión real de aapt2, obtenida ejecutándolo. No damos nada por hecho:
  // que exista /opt/android-sdk/build-tools no significa que el binario
  // arranque, y eso es justo lo que puede fallar en aarch64.
  String? _aapt2;
  bool _aapt2Checked = false;
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    _svc.addListener(_onChange);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _svc.refresh();
      _maybeProbe();
    });
  }

  Future<void> _probeAapt2() async {
    _probing = true;
    final v = await _svc.aapt2Version();
    if (!mounted) return;
    setState(() {
      _probing = false;
      _aapt2Checked = true;
      if (v == null) {
        _aapt2 = null;
      } else {
        // "Android Asset Packaging Tool (aapt) 2.19-F966BXXUABZF1" → "aapt2 2.19"
        final m = RegExp(r'(\\d+\\.\\d+)').firstMatch(v);
        _aapt2 = m != null ? 'aapt2 ${m.group(1)}' : v;
      }
    });
  }

  void _maybeProbe() {
    if (_svc.phase == SdkPhase.ready &&
        !_aapt2Checked &&
        !_probing &&
        !_svc.busy) {
      _probeAapt2();
    } else if (_svc.phase != SdkPhase.ready && _aapt2Checked) {
      _aapt2Checked = false;
      _aapt2 = null;
    }
  }""",
        "tarjeta · comprobación real de aapt2", True,
    ),

    # ── 2. _onChange dispara la comprobación ──────────────────
    (
"""  void _onChange() {
    if (mounted) setState(() {});
  }""",
"""  void _onChange() {
    if (!mounted) return;
    setState(() {});
    _maybeProbe();
  }""",
        "tarjeta · _onChange", True,
    ),

    # ── 3. Estado 'ready' deja de mentir ──────────────────────
    (
"""      case SdkPhase.ready:
        return 'Instalado · SDK 35 · aapt2 aarch64';""",
"""      case SdkPhase.ready:
        if (!_aapt2Checked) return 'Instalado · comprobando aapt2…';
        if (_aapt2 == null) return 'Instalado · aapt2 NO responde';
        return 'Instalado · SDK 35 · $_aapt2 aarch64';""",
        "tarjeta · estado 'instalado'", True,
    ),

    # ── 4. Cifras reales ──────────────────────────────────────
    (
"""      case SdkPhase.absent:
        return 'No instalado · ~4 GB, 20-40 min';""",
"""      case SdkPhase.absent:
        return 'No instalado · ~1,3 GB, 5-15 min';""",
        "tarjeta · tamaño y tiempo reales", True,
    ),

    # ── 5. Rojo también si aapt2 no responde ──────────────────
    (
"""                        style: TextStyle(
                            color: _svc.phase == SdkPhase.failed
                                ? _C.err
                                : _C.textLo,
                            fontSize: 11.5)),""",
"""                        style: TextStyle(
                            color: (_svc.phase == SdkPhase.failed ||
                                    (_svc.phase == SdkPhase.ready &&
                                        _aapt2Checked &&
                                        _aapt2 == null))
                                ? _C.err
                                : _C.textLo,
                            fontSize: 11.5)),""",
        "tarjeta · color de aviso", True,
    ),

    # ── 6. El diálogo también mentía ──────────────────────────
    (
"""                'JDK 17, Gradle 8.9, SDK 35 y los binarios aarch64 que Google '
                'no publica. Unos 4 GB y 20-40 minutos con WiFi decente.\\n\\n'""",
"""                'JDK 17, Gradle 8.9, SDK 35 y los binarios aarch64 que Google '
                'no publica. Unos 1,3 GB y 5-15 minutos con WiFi decente.\\n\\n'""",
        "tarjeta · texto del diálogo", True,
    ),
]

SCRIPT_EDITS = [
    # 8 GB de minimo era excesivo: el entorno entero ocupa 1,3 GB.
    # 4 GB deja margen de sobra para caches y builds.
    ('MIN_FREE_GB=8', 'MIN_FREE_GB=4', "script · espacio mínimo 8→4 GB", True),
]

README_EDITS = [
    ("Unos **4 GB** de descarga y **20-40 minutos** con WiFi decente.",
     "Unos **1,3 GB** y **5-15 minutos** con WiFi decente.\n"
     "(Medido en un Galaxy Z Fold7: 624 MB de SDK, 145 MB de Gradle,\n"
     "474 MB de caché de Maven.)",
     "README · cifras", False),
]


def read(p):
    with open(p, "r", encoding="utf-8") as f:
        return f.read()


def apply(path, edits, label):
    if not os.path.exists(path):
        warn(f"{label}: no existe {os.path.relpath(path, PROJ)} — saltando")
        return
    src = read(path)
    orig = src
    done = 0

    for old, new, name, required in edits:
        if new in src:
            ok(f"{name} — ya aplicado")
            done += 1
            continue
        if old not in src:
            if required:
                die(f"{name} — no encuentro el texto original.\n"
                    f"  ¿Editaste el fichero a mano? Hazlo tú entonces.")
            warn(f"{name} — no encontrado, saltando")
            continue
        if src.count(old) > 1:
            die(f"{name} — aparece {src.count(old)} veces. Ambiguo, no toco.")
        src = src.replace(old, new, 1)
        ok(name)
        done += 1

    if src != orig and not DRY:
        b = path + ".bak_v2"
        if not os.path.exists(b):
            shutil.copy2(path, b)
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)


def main():
    print(f"{C}{B}▸ Android SDK / Dev — correcciones v2{X}")
    print(f"  {D}proyecto: {PROJ}{X}")
    if DRY:
        warn("DRY-RUN — no se escribe nada")
    print()

    if not os.path.isdir(PROJ):
        die(f"No existe: {PROJ}  (exporta PROJ=/ruta)")

    if REVERT:
        n = 0
        for p in (CARD, SCRIPT, README):
            b = p + ".bak_v2"
            if os.path.exists(b):
                shutil.copy2(b, p)
                os.remove(b)
                ok(f"restaurado {os.path.relpath(p, PROJ)}")
                n += 1
        if n == 0:
            warn("No hay backups .bak_v2")
        return

    apply(CARD, CARD_EDITS, "tarjeta")
    apply(SCRIPT, SCRIPT_EDITS, "script")
    apply(README, README_EDITS, "README")

    if DRY:
        print()
        warn("Dry-run. Relanza sin --dry para aplicar.")
        return

    print()
    print(f"{C}Ahora:{X}")
    print(f"  cd {PROJ}")
    print( "  flutter analyze lib/")
    print( "  git add -A && git commit -m \"fix(dev): la tarjeta verifica aapt2 en vez de asumirlo; cifras reales\"")
    print( "  git push origin main && ./build_and_deploy.sh")
    print()
    print(f"{D}  Tras compilar bien:  find {PROJ} -name '*.bak_v2' -delete{X}")


if __name__ == "__main__":
    main()
