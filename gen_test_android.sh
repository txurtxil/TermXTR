#!/bin/bash
# XTR Terminal — Genera una app Android de verdad para probar el entorno.
#
# A diferencia del test de humo del instalador (un manifest pelado, 8 KB, con
# javac en NO-SOURCE), esta app ejerce toda la cadena:
#
#   · aapt2 compile  → recursos de verdad (layouts, strings, colores, tema)
#   · aapt2 link     → genera R.java
#   · javac          → compila código Java real
#   · d8             → dexa clases de verdad + AndroidX
#   · apksigner      → firma con la debug keystore
#   · Maven          → se baja AndroidX appcompat
#
# Uso:
#   ./gen_test_android.sh              genera y compila
#   ./gen_test_android.sh --install    + instala en el dispositivo por adb
#   ./gen_test_android.sh --clean      borra el proyecto y sale

set -o pipefail

PROJECT_DIR="/root/xtr-testapp"
APP_ID="com.xtr.testapp"
ANDROID_HOME="${ANDROID_HOME:-/opt/android-sdk}"
BUILD_TOOLS_VER="35.0.0"
AGP_VER="8.7.3"
GRADLE_VER="8.9"
APPCOMPAT_VER="1.7.0"
# appcompat arrastra kotlin-stdlib 1.8.22 y, por vía transitiva,
# kotlin-stdlib-jdk8 1.6.21. Desde Kotlin 1.8 los artefactos jdk7/jdk8 están
# fusionados dentro de kotlin-stdlib: las mismas clases en dos jars → d8 aborta
# con "Duplicate class". Forzamos una única versión y excluimos los viejos.
KOTLIN_STDLIB_VER="1.9.24"

C_RESET='\e[0m'; C_B='\e[1m'; C_DIM='\e[2m'
C_GRN='\e[1;32m'; C_YEL='\e[1;33m'; C_RED='\e[1;31m'; C_CYN='\e[1;36m'
ok()   { echo -e "${C_GRN}✓${C_RESET} $1"; }
warn() { echo -e "${C_YEL}!${C_RESET} $1"; }
die()  { echo -e "${C_RED}✗${C_RESET} $1"; exit 1; }
info() { echo -e "  ${C_DIM}$1${C_RESET}"; }
hr()   { echo -e "${C_DIM}──────────────────────────────────────────${C_RESET}"; }

DO_INSTALL=0
for a in "$@"; do
  case "$a" in
    --install) DO_INSTALL=1 ;;
    --clean)   rm -rf "$PROJECT_DIR"; ok "borrado $PROJECT_DIR"; exit 0 ;;
    *) die "Flag desconocido: $a" ;;
  esac
done

echo -e "${C_GRN}╔════════════════════════════════════════╗${C_RESET}"
echo -e "${C_GRN}║${C_RESET}  ${C_B}${C_GRN}XTR${C_RESET} ${C_DIM}·${C_RESET} ${C_B}App de prueba real${C_RESET}            ${C_GRN}║${C_RESET}"
echo -e "${C_GRN}╚════════════════════════════════════════╝${C_RESET}"
echo ""

# ── Entorno ───────────────────────────────────────────────────
[ -f /etc/profile.d/android-sdk.sh ] && . /etc/profile.d/android-sdk.sh
export ANDROID_HOME ANDROID_SDK_ROOT="$ANDROID_HOME"
export GRADLE_OPTS="-Dorg.gradle.native=false"

BT="$ANDROID_HOME/build-tools/$BUILD_TOOLS_VER"
[ -x "$BT/aapt2" ] || die "No hay SDK. Instala primero el entorno Android."
command -v gradle >/dev/null || die "gradle no está en el PATH. Abre una terminal nueva."
ok "SDK en $ANDROID_HOME"

# ── Estructura ────────────────────────────────────────────────
echo -e "${C_CYN}▸ Generando proyecto en $PROJECT_DIR${C_RESET}"
rm -rf "$PROJECT_DIR"
PKG_PATH="${APP_ID//./\/}"
mkdir -p "$PROJECT_DIR/app/src/main/java/$PKG_PATH"
mkdir -p "$PROJECT_DIR/app/src/main/res/layout"
mkdir -p "$PROJECT_DIR/app/src/main/res/values"

cat > "$PROJECT_DIR/settings.gradle" <<EOF
pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}
rootProject.name = "xtr-testapp"
include ":app"
EOF

cat > "$PROJECT_DIR/build.gradle" <<EOF
plugins {
    id "com.android.application" version "$AGP_VER" apply false
}
EOF

cat > "$PROJECT_DIR/gradle.properties" <<EOF
android.aapt2FromMavenOverride=$BT/aapt2
org.gradle.jvmargs=-Xmx3g -XX:MaxMetaspaceSize=1g
org.gradle.daemon=false
org.gradle.parallel=true
android.useAndroidX=true
android.nonTransitiveRClass=true
EOF

cat > "$PROJECT_DIR/local.properties" <<EOF
sdk.dir=$ANDROID_HOME
EOF

cat > "$PROJECT_DIR/app/build.gradle" <<EOF
plugins { id "com.android.application" }

android {
    namespace "$APP_ID"
    compileSdk 35

    defaultConfig {
        applicationId "$APP_ID"
        minSdk 24
        targetSdk 35
        versionCode 1
        versionName "1.0"
    }

    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }

    buildFeatures { buildConfig true }

    buildTypes {
        debug { applicationIdSuffix "" }
    }
}

configurations.all {
    // Los jdk7/jdk8 de Kotlin estan fusionados en kotlin-stdlib desde 1.8.
    // Sin esto: "Duplicate class kotlin.streams.jdk8.StreamsKt".
    exclude group: "org.jetbrains.kotlin", module: "kotlin-stdlib-jdk8"
    exclude group: "org.jetbrains.kotlin", module: "kotlin-stdlib-jdk7"
    resolutionStrategy {
        force "org.jetbrains.kotlin:kotlin-stdlib:$KOTLIN_STDLIB_VER"
    }
}

dependencies {
    implementation "androidx.appcompat:appcompat:$APPCOMPAT_VER"
}
EOF

# ── Manifest ──────────────────────────────────────────────────
cat > "$PROJECT_DIR/app/src/main/AndroidManifest.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <application
        android:allowBackup="true"
        android:label="@string/app_name"
        android:supportsRtl="true"
        android:theme="@style/Theme.XtrTest">

        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
EOF

# ── Recursos — esto es lo que hace trabajar a aapt2 ────────────
cat > "$PROJECT_DIR/app/src/main/res/values/strings.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <string name="app_name">XTR Test</string>
    <string name="built_here">Compilada en este mismo teléfono</string>
    <string name="tap_me">Púlsame</string>
    <string name="taps">Pulsaciones: %1$d</string>
</resources>
EOF

cat > "$PROJECT_DIR/app/src/main/res/values/colors.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="bg">#FF1C1C1E</color>
    <color name="card">#FF2C2C2E</color>
    <color name="text_hi">#FFEAEAEC</color>
    <color name="text_lo">#FF9A9AA0</color>
    <color name="accent">#FF34C759</color>
</resources>
EOF

cat > "$PROJECT_DIR/app/src/main/res/values/themes.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <style name="Theme.XtrTest" parent="Theme.AppCompat.DayNight.NoActionBar">
        <item name="colorPrimary">@color/accent</item>
        <item name="android:windowBackground">@color/bg</item>
    </style>
</resources>
EOF

cat > "$PROJECT_DIR/app/src/main/res/layout/activity_main.xml" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical"
    android:gravity="center"
    android:padding="24dp"
    android:background="@color/bg">

    <TextView
        android:id="@+id/title"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:text="@string/built_here"
        android:textColor="@color/accent"
        android:textSize="20sp"
        android:textStyle="bold"
        android:gravity="center" />

    <TextView
        android:id="@+id/info"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_marginTop="20dp"
        android:padding="14dp"
        android:background="@color/card"
        android:textColor="@color/text_lo"
        android:textSize="12sp"
        android:fontFamily="monospace" />

    <TextView
        android:id="@+id/counter"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:layout_marginTop="20dp"
        android:textColor="@color/text_hi"
        android:textSize="16sp" />

    <Button
        android:id="@+id/button"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:layout_marginTop="12dp"
        android:text="@string/tap_me" />

</LinearLayout>
EOF

# ── Código Java — para que javac deje de estar en NO-SOURCE ────
cat > "$PROJECT_DIR/app/src/main/java/$PKG_PATH/MainActivity.java" <<EOF
package $APP_ID;

import android.os.Build;
import android.os.Bundle;
import android.widget.Button;
import android.widget.TextView;
import androidx.appcompat.app.AppCompatActivity;

public class MainActivity extends AppCompatActivity {

    private int taps = 0;
    private TextView counter;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        TextView info = findViewById(R.id.info);
        info.setText(
            "Modelo    : " + Build.MODEL + "\\n" +
            "SoC       : " + Build.HARDWARE + "\\n" +
            "ABI       : " + Build.SUPPORTED_ABIS[0] + "\\n" +
            "Android   : " + Build.VERSION.RELEASE + " (API " + Build.VERSION.SDK_INT + ")\\n" +
            "Paquete   : " + BuildConfig.APPLICATION_ID + "\\n" +
            "Compilada : dentro de proot, con aapt2 aarch64"
        );

        counter = findViewById(R.id.counter);
        updateCounter();

        Button b = findViewById(R.id.button);
        b.setOnClickListener(v -> {
            taps++;
            updateCounter();
        });
    }

    private void updateCounter() {
        counter.setText(getString(R.string.taps, taps));
    }
}
EOF

ok "proyecto generado"
info "Activity + layout + 4 ficheros de recursos + AndroidX appcompat"

# ── Wrapper ───────────────────────────────────────────────────
cd "$PROJECT_DIR" || die "cd falló"
echo -e "${C_CYN}▸ Generando el wrapper de Gradle${C_RESET}"
gradle wrapper --gradle-version "$GRADLE_VER" --quiet 2>&1 | tail -2 \
  || die "No se pudo generar el wrapper."

# ── Build ─────────────────────────────────────────────────────
echo ""
echo -e "${C_CYN}▸ ./gradlew assembleDebug${C_RESET}"
info "La primera vez baja AndroidX de Maven (~50 MB)"
hr
if ! ./gradlew assembleDebug --no-daemon --console=plain 2>&1 | tail -30; then
  hr
  die "La compilación falló. Mira los errores de arriba."
fi
hr

APK="$PROJECT_DIR/app/build/outputs/apk/debug/app-debug.apk"
[ -f "$APK" ] || die "Build correcta pero no hay APK. Raro."

SZ=$(du -h "$APK" | cut -f1)
ok "═══ APK REAL: OK ═══"
ok "$APK ($SZ)"
echo ""

# ── Qué hemos demostrado ──────────────────────────────────────
echo -e "${C_CYN}▸ Contenido${C_RESET}"
"$BT/aapt2" dump badging "$APK" 2>/dev/null | head -3
echo ""
DEX_COUNT=$(unzip -l "$APK" 2>/dev/null | grep -c '\.dex$')
RES_COUNT=$(unzip -l "$APK" 2>/dev/null | grep -c '^.*res/')
info "ficheros .dex : $DEX_COUNT   (código real dexado)"
info "recursos      : $RES_COUNT   (aapt2 los compiló y enlazó)"
if [ "$DEX_COUNT" -gt 0 ] && [ "$RES_COUNT" -gt 0 ]; then
  ok "javac + aapt2 + d8 verificados de verdad"
else
  warn "Algo no cuadra: esperaba dex y recursos dentro del APK."
fi

# ── Instalar ──────────────────────────────────────────────────
echo ""
if [ "$DO_INSTALL" = "1" ]; then
  echo -e "${C_CYN}▸ adb install${C_RESET}"
  if ! adb devices 2>/dev/null | grep -q "device$"; then
    warn "No hay ningún dispositivo conectado por adb."
    info "Usa 'Conectar adb' en la tarjeta, o:"
    info "  adb connect 127.0.0.1:PUERTO"
    exit 1
  fi
  adb install -r "$APK" 2>&1 | tail -3
  if adb shell pm list packages 2>/dev/null | grep -q "$APP_ID"; then
    ok "Instalada. Abriendo..."
    adb shell am start -n "$APP_ID/.MainActivity" 2>&1 | tail -1
    echo ""
    ok "Busca 'XTR Test' en el lanzador."
  fi
else
  info "Para instalarla en el teléfono:"
  info "  1. Tarjeta Android SDK / Dev → Conectar adb"
  info "  2. $0 --install"
  echo ""
  info "O a mano:  adb install -r $APK"
fi
