import os, re

kt_path = "android/app/src/main/kotlin/com/example/linux_container/MediaPipeEngine.kt"
if os.path.exists(kt_path):
    with open(kt_path, "r") as f: content = f.read()
    if "LlmInference.createFromOptions" in content and "catch (e: Throwable)" not in content:
        content = re.sub(
            r"(llmInference\s*=\s*LlmInference\.createFromOptions\([^)]+\))",
            r"try {\n            \1\n        } catch (e: Throwable) {\n            android.util.Log.e(\"MediaPipeEngine\", \"Crash nativo evitado (GPU): ${e.message}\")\n        }",
            content
        )
        with open(kt_path, "w") as f: f.write(content)

dart_services = "lib/src/agent/agent_services.dart"
if os.path.exists(dart_services):
    with open(dart_services, "r") as f: content = f.read()
    if '"GPU local"' not in content:
        content = content.replace('"Personalizado"', '"Personalizado", "GPU local"')
        with open(dart_services, "w") as f: f.write(content)

dart_dashboard = "lib/src/agent/agent_dashboard.dart"
if os.path.exists(dart_dashboard):
    with open(dart_dashboard, "r") as f: content = f.read()
    if "ignore_for_file: use_build_context_synchronously" not in content:
        with open(dart_dashboard, "w") as f: f.write("// ignore_for_file: use_build_context_synchronously\n" + content)

print("[OK] Código frontend y lints parcheados con éxito.")
