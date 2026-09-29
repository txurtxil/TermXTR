package com.example.linux_container

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * KeepAliveService — mantiene VIVO EL PROCESO de la app (y con el las
 * sesiones SSH/SFTP de flutter_pty, que son procesos hijos) cuando la app
 * pasa a segundo plano. Es el mismo enfoque que Termux: foreground service
 * con notificacion persistente + PARTIAL_WAKE_LOCK para que los keepalives
 * SSH (keepAliveInterval de dartssh2) sigan disparando con la pantalla
 * apagada.
 *
 * Android mata la app en background y las sesiones mueren con ella; este
 * servicio lo evita y se controla desde Ajustes ("Mantener sesiones en 2o
 * plano", por defecto ON).
 */
class KeepAliveService : Service() {
    companion object {
        const val CHANNEL_ID = "xtr_keepalive"
        const val NOTIF_ID = 4712
        const val ACTION_START = "com.example.linux_container.KEEPALIVE_START"
        const val ACTION_STOP = "com.example.linux_container.KEEPALIVE_STOP"

        @Volatile var isRunning = false
            private set
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForegroundCompat()
            releaseLock()
            isRunning = false
            stopSelf()
            return START_NOT_STICKY
        }
        startAsForeground()
        acquireLock()
        isRunning = true
        return START_STICKY
    }

    private fun startAsForeground() {
        createChannel()
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, launch,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )
        val notif: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("XTR Terminal activo")
            .setContentText("Sesiones SSH/SFTP en segundo plano")
            .setSmallIcon(applicationInfo.icon)
            .setOngoing(true)
            .setContentIntent(pi)
            .build()

        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIF_ID, notif,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            @Suppress("DEPRECATION")
            startForeground(NOTIF_ID, notif)
        }
    }

    private fun acquireLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "xtr:keepalive").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseLock() {
        try { if (wakeLock?.isHeld == true) wakeLock?.release() } catch (_: Exception) {}
        wakeLock = null
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
    }

    override fun onDestroy() {
        releaseLock()
        isRunning = false
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (mgr.getNotificationChannel(CHANNEL_ID) == null) {
                val ch = NotificationChannel(
                    CHANNEL_ID, "Sesiones en segundo plano",
                    NotificationManager.IMPORTANCE_MIN
                )
                ch.description = "Mantiene vivas las sesiones SSH/SFTP con la app en segundo plano"
                ch.setShowBadge(false)
                mgr.createNotificationChannel(ch)
            }
        }
    }
}
