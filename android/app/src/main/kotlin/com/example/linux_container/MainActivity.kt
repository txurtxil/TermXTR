package com.example.linux_container

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

    private val WIDGET_CH    = "xtr/widget"
    private val KEEPALIVE_CH = "xtr/keepalive"

    // Accion pendiente procedente del widget de escritorio (click en una
    // fila SSH/SFTP). Se guarda aqui y Flutter la recoge con
    // "getPendingAction" (fetch+clear atomico: sin duplicados ni perdidas).
    private var widgetChannel: MethodChannel? = null
    private var pendingWidgetAction: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // ── Widget de escritorio (hosts SSH / favoritos SFTP) ──
        val wch = MethodChannel(messenger, WIDGET_CH)
        widgetChannel = wch
        wch.setMethodCallHandler { call, result ->
            when (call.method) {
                // WidgetSync.dart acaba de escribir el espejo JSON en prefs:
                // refrescar la lista del widget.
                "refresh" -> {
                    HostsWidgetProvider.requestRefresh(applicationContext)
                    result.success(true)
                }
                // Flutter recoge (y limpia) la accion pendiente del widget.
                "getPendingAction" -> {
                    val a = pendingWidgetAction
                    pendingWidgetAction = null
                    result.success(a)
                }
                else -> result.notImplemented()
            }
        }

        // ── KeepAlive: foreground service para sesiones en 2o plano ──
        // Lo controla Dart (Ajustes -> "Mantener sesiones en 2o plano",
        // por defecto ON). Protege las sesiones SSH/SFTP mientras la app
        // esta abierta.
        MethodChannel(messenger, KEEPALIVE_CH)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val i = Intent(this, KeepAliveService::class.java)
                        i.action = KeepAliveService.ACTION_START
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(i)
                        else startService(i)
                        result.success(true)
                    }
                    "stop" -> {
                        val i = Intent(this, KeepAliveService::class.java)
                        i.action = KeepAliveService.ACTION_STOP
                        startService(i)
                        result.success(true)
                    }
                    "isRunning" -> result.success(KeepAliveService.isRunning)
                    // Ajustes del sistema para excluir la app de la
                    // optimizacion de bateria (Samsung la aplica con dureza).
                    "batterySettings" -> {
                        try {
                            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── Widget: captura del intent con extras xtr_widget_* ────
    private fun handleWidgetIntent(intent: Intent?) {
        val type = intent?.getStringExtra("xtr_widget_type") ?: return
        val action = mutableMapOf<String, Any?>("type" to type)
        intent.getStringExtra("xtr_widget_host_id")?.let { action["hostId"] = it }
        intent.getStringExtra("xtr_widget_path")?.let { action["path"] = it }
        pendingWidgetAction = action
        // Aviso ligero: si Flutter ya esta escuchando, pide la accion y la
        // procesa al momento (app en caliente). Si no, la recogera en el
        // arranque con getPendingAction (app en frio).
        widgetChannel?.invokeMethod("onWidgetAction", null)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleWidgetIntent(intent)
    }

    // ── onCreate: dialogo de primer arranque ──────────────────
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            !Environment.isExternalStorageManager()) {
            try {
                startActivity(Intent(
                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                    Uri.parse("package:$packageName")))
            } catch (e: Exception) {
                Log.w("XTR", "No se pudo abrir ajustes de almacenamiento", e)
            }
        }
        // Click del widget en frio (la app se abre por el PendingIntent).
        handleWidgetIntent(intent)
    }

}
