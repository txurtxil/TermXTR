package com.example.linux_container

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.widget.RemoteViews

/**
 * Widget de escritorio "XTR Hosts": lista los hosts SSH y los favoritos SFTP
 * (espejo JSON en FlutterSharedPreferences, escrito por WidgetSync.dart).
 *
 * v14.22/14.23 — adaptable al tamano:
 *  - Puede encogerse hasta 2x1 celdas (hosts_widget_info.xml).
 *  - updateOne() elige layout NORMAL / COMPACTO / MICRO segun las celdas
 *    reales del launcher, y pasa el modo al RemoteViewsService con
 *    EXTRA_MODE para las filas.
 *  - onAppWidgetOptionsChanged() re-aplica al redimensionar.
 *  - El titulo (y el texto de vacio) abren la app.
 */
class HostsWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_REFRESH = "com.example.linux_container.widget.REFRESH"
        const val EXTRA_MODE = "com.example.linux_container.widget.MODE"

        const val MODE_NORMAL = 0
        const val MODE_COMPACT = 1
        const val MODE_MICRO = 2

        /** dp -> celdas del launcher (formula oficial: 70*n - 30). */
        private fun cellsFor(dp: Int): Int = if (dp <= 0) 1 else (dp + 30) / 70

        /** Modo segun celdas reales: 1 celda en cualquier eje -> MICRO;
         *  2 o menos -> COMPACTO; mas -> NORMAL. */
        fun modeFor(options: Bundle?): Int {
            if (options == null) return MODE_NORMAL
            val w = cellsFor(options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH))
            val h = cellsFor(options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT))
            return when {
                w <= 1 || h <= 1 -> MODE_MICRO
                w <= 2 || h <= 2 -> MODE_COMPACT
                else -> MODE_NORMAL
            }
        }

        /** Llamado desde MainActivity (canal xtr/widget "refresh") y desde el
         *  boton de refresco del propio widget. */
        fun requestRefresh(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val ids = mgr.getAppWidgetIds(
                ComponentName(context, HostsWidgetProvider::class.java))
            if (ids.isNotEmpty()) {
                mgr.notifyAppWidgetViewDataChanged(ids, R.id.widget_list)
            }
        }

        private fun updateOne(context: Context, mgr: AppWidgetManager, widgetId: Int) {
            val mode = modeFor(mgr.getAppWidgetOptions(widgetId))
            val layout = when (mode) {
                MODE_MICRO -> R.layout.widget_hosts_micro
                MODE_COMPACT -> R.layout.widget_hosts_compact
                else -> R.layout.widget_hosts
            }
            val views = RemoteViews(context.packageName, layout)

            // Adapter de la lista -> nuestro RemoteViewsService. La data URI
            // hace unico el intent por (widgetId, modo): sin ella el sistema
            // cachea la factory del primer widget y todos compartirian modo.
            val svcIntent = Intent(context, HostsWidgetService::class.java).apply {
                putExtra(EXTRA_MODE, mode)
                data = Uri.parse("xtrwidget://hosts/$widgetId/$mode")
            }
            views.setRemoteAdapter(R.id.widget_list, svcIntent)
            views.setEmptyView(R.id.widget_list, R.id.widget_empty)

            // Abrir la app: titulo y vista de vacio.
            val launchPi = PendingIntent.getActivity(
                context, 2,
                Intent(context, MainActivity::class.java).apply {
                    action = Intent.ACTION_MAIN
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
                },
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            views.setOnClickPendingIntent(R.id.widget_title, launchPi)
            views.setOnClickPendingIntent(R.id.widget_empty, launchPi)

            // Plantilla de PendingIntent para clicks de fila: cada fila rellena
            // los extras xtr_widget_* con setOnClickFillInIntent.
            val clickIntent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            }
            val clickPi = PendingIntent.getActivity(
                context, 0, clickIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            views.setPendingIntentTemplate(R.id.widget_list, clickPi)

            // Boton de refresco de la cabecera
            val refreshIntent = Intent(context, HostsWidgetProvider::class.java).apply {
                action = ACTION_REFRESH
            }
            val refreshPi = PendingIntent.getBroadcast(
                context, 1, refreshIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
            views.setOnClickPendingIntent(R.id.widget_refresh, refreshPi)

            mgr.updateAppWidget(widgetId, views)
            mgr.notifyAppWidgetViewDataChanged(widgetId, R.id.widget_list)
        }
    }

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) updateOne(context, mgr, id)
    }

    /** Redimensionar el widget: re-aplicar layout (normal/compacto) y filas. */
    override fun onAppWidgetOptionsChanged(
        context: Context, mgr: AppWidgetManager, widgetId: Int, newOptions: Bundle) {
        updateOne(context, mgr, widgetId)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_REFRESH) requestRefresh(context)
    }
}
