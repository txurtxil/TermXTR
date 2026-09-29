package com.example.linux_container

import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import org.json.JSONArray

/**
 * RemoteViewsFactory del widget: lee el espejo JSON que WidgetSync.dart
 * escribe en FlutterSharedPreferences (mismo fichero que usa el plugin
 * shared_preferences, claves con prefijo "flutter.").
 *
 * Estructura esperada:
 *   flutter.widget_hosts_json: [{"id","name","username","hostname","port","osTag"}]
 *   flutter.widget_sftp_json:  [{"id","hostId","hostName","path","label"}]
 *
 * v14.22/14.23: EXTRA_MODE (normal/compacto/micro) -> filas de dos lineas,
 * una linea o micro (avatar 20dp); el titulo combina nombre y detalle
 * cuando no hay espacio para subtitulo.
 */
class HostsWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        HostsWidgetFactory(
            applicationContext,
            intent.getIntExtra(HostsWidgetProvider.EXTRA_MODE, HostsWidgetProvider.MODE_NORMAL))
}

private data class Row(
    val isSftp: Boolean,
    val title: String,
    val subtitle: String,
    val hostId: String,
    val path: String,      // solo SFTP
    val osTag: String,     // solo SSH
)

private class HostsWidgetFactory(
    private val context: Context,
    private val mode: Int,
) : RemoteViewsService.RemoteViewsFactory {

    private val rows = mutableListOf<Row>()

    private val compact get() = mode != HostsWidgetProvider.MODE_NORMAL

    private fun sshLayout(): Int = when (mode) {
        HostsWidgetProvider.MODE_MICRO -> R.layout.widget_row_ssh_micro
        HostsWidgetProvider.MODE_COMPACT -> R.layout.widget_row_ssh_small
        else -> R.layout.widget_row_ssh
    }

    private fun sftpLayout(): Int = when (mode) {
        HostsWidgetProvider.MODE_MICRO -> R.layout.widget_row_sftp_micro
        HostsWidgetProvider.MODE_COMPACT -> R.layout.widget_row_sftp_small
        else -> R.layout.widget_row_sftp
    }

    override fun onCreate() {}

    override fun onDataSetChanged() {
        // Se ejecuta en hilo binder: aqui SI se puede leer disco/prefs.
        rows.clear()
        val prefs = context.getSharedPreferences(
            "FlutterSharedPreferences", Context.MODE_PRIVATE)

        val hostsJson = prefs.getString("flutter.widget_hosts_json", "[]") ?: "[]"
        try {
            val arr = JSONArray(hostsJson)
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val name = o.optString("name", "Host")
                val user = o.optString("username", "")
                val host = o.optString("hostname", "")
                val port = o.optInt("port", 22)
                rows.add(Row(
                    isSftp = false,
                    title = name,
                    subtitle = "$user@$host" + (if (port != 22) ":$port" else ""),
                    hostId = o.optString("id", ""),
                    path = "",
                    osTag = o.optString("osTag", "generic"),
                ))
            }
        } catch (_: Exception) {}

        val sftpJson = prefs.getString("flutter.widget_sftp_json", "[]") ?: "[]"
        try {
            val arr = JSONArray(sftpJson)
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                rows.add(Row(
                    isSftp = true,
                    title = o.optString("label", o.optString("path", "/")),
                    subtitle = o.optString("hostName", ""),
                    hostId = o.optString("hostId", ""),
                    path = o.optString("path", "."),
                    osTag = "",
                ))
            }
        } catch (_: Exception) {}
    }

    override fun getViewAt(position: Int): RemoteViews {
        // El launcher puede pedir una posicion obsoleta mientras se
        // rehace el dataset: nunca devolver null (crashea el host).
        if (position < 0 || position >= rows.size) {
            return RemoteViews(context.packageName, sshLayout())
        }
        val row = rows[position]
        return if (row.isSftp) sftpView(row) else sshView(row)
    }

    private fun sshView(row: Row): RemoteViews {
        val v = RemoteViews(context.packageName, sshLayout())
        // En compacto el detalle va en la misma linea: "nombre · user@host".
        v.setTextViewText(R.id.row_title,
            if (compact && row.subtitle.isNotEmpty()) "${row.title} · ${row.subtitle}"
            else row.title)
        if (!compact) v.setTextViewText(R.id.row_subtitle, row.subtitle)
        v.setTextViewText(R.id.row_avatar, row.title.firstOrNull()?.uppercase() ?: "?")
        v.setInt(R.id.row_avatar, "setBackgroundResource", avatarFor(row.osTag))
        v.setOnClickFillInIntent(R.id.widget_row_root, Intent().apply {
            putExtra("xtr_widget_type", "ssh")
            putExtra("xtr_widget_host_id", row.hostId)
        })
        return v
    }

    private fun sftpView(row: Row): RemoteViews {
        val v = RemoteViews(context.packageName, sftpLayout())
        v.setTextViewText(R.id.row_title,
            if (compact && row.subtitle.isNotEmpty()) "${row.title} — ${row.subtitle}"
            else row.title)
        if (!compact) v.setTextViewText(R.id.row_subtitle, row.subtitle)
        v.setOnClickFillInIntent(R.id.widget_row_root, Intent().apply {
            putExtra("xtr_widget_type", "sftp")
            putExtra("xtr_widget_host_id", row.hostId)
            putExtra("xtr_widget_path", row.path)
        })
        return v
    }

    private fun avatarFor(osTag: String): Int = when (osTag) {
        "debian" -> R.drawable.widget_avatar_debian
        "ubuntu" -> R.drawable.widget_avatar_ubuntu
        "raspbian" -> R.drawable.widget_avatar_raspbian
        else -> R.drawable.widget_avatar_generic
    }

    override fun getLoadingView(): RemoteViews? = null
    // 6 layouts de fila posibles: ssh/sftp x normal/compacto/micro.
    override fun getViewTypeCount(): Int = 6
    override fun getItemId(position: Int): Long = position.toLong()
    override fun hasStableIds(): Boolean = true
    override fun getCount(): Int = rows.size
    override fun onDestroy() {}
}
