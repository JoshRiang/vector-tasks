package com.joshua.vector_tasks

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

/**
 * Next action home-screen widget.
 *
 * Fetches the API on a background thread (a widget provider runs on the main
 * thread, so network work here must never be done inline) and renders with
 * RemoteViews. Falls back to a readable message instead of an empty box when
 * the server is unreachable -- a widget that silently shows nothing is
 * indistinguishable from a broken app.
 */
class NextActionWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.widget_next_action)
            views.setTextViewText(R.id.widget_primary, context.getString(R.string.widget_loading))
            views.setTextViewText(R.id.widget_secondary, "")
            appWidgetManager.updateAppWidget(id, views)
            thread { refresh(context, appWidgetManager, id) }
        }
    }

    private fun refresh(context: Context, mgr: AppWidgetManager, id: Int) {
        val views = RemoteViews(context.packageName, R.layout.widget_next_action)
        try {
            val body = httpGet(context, "/tasks/startable")
            val (primary, secondary, badge) = render(body)
            views.setTextViewText(R.id.widget_primary, primary)
            views.setTextViewText(R.id.widget_secondary, secondary)
            views.setTextViewText(R.id.widget_badge, badge)
        } catch (e: Exception) {
            views.setTextViewText(R.id.widget_primary, context.getString(R.string.widget_offline))
            views.setTextViewText(R.id.widget_secondary, context.getString(R.string.widget_offline_hint))
            views.setTextViewText(R.id.widget_badge, "")
        }

        // Tapping the widget opens the app.
        val intent = Intent(context, MainActivity::class.java)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        views.setOnClickPendingIntent(
            R.id.widget_root,
            PendingIntent.getActivity(context, 0, intent, flags)
        )
        mgr.updateAppWidget(id, views)
    }

    /** Next action content. Returns (primary, secondary, badge). */
    private fun render(body: String): Triple<String, String, String> {

        // The whole product premise: surface exactly ONE startable action.
        // A widget that listed the backlog would recreate the paralysis.
        val arr = JSONArray(body)
        if (arr.length() == 0) {
            return Triple(
                "Nothing to start",
                "Open the app to set a goal",
                ""
            )
        }
        val top = arr.getJSONObject(0)
        val title = top.optString("title", "Untitled task")
        val minutes = top.optInt("minutes", 30)
        val more = arr.length() - 1
        val secondary = if (more > 0)
            "$minutes min  \u00b7  $more more unlocked"
        else
            "$minutes min"
        return Triple(title, secondary, "START HERE")
    }

    /** Group digits so a 7-figure amount stays readable in a narrow widget. */
    private fun fmt(v: Double): String {
        val s = String.format("%,.0f", v)
        return s
    }

    private fun httpGet(context: Context, path: String): String {
        val base = context.getString(R.string.vector_api_base).trimEnd('/')
        val userId = context.getString(R.string.vector_user_id)
        val conn = (URL(base + path).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 8000
            readTimeout = 8000
            setRequestProperty("X-User-Id", userId)
            // Shared secret, required once the API is publicly reachable.
            val apiKey = context.getString(R.string.vector_api_key)
            if (apiKey.isNotEmpty()) setRequestProperty("X-Api-Key", apiKey)
            setRequestProperty("Accept", "application/json")
        }
        try {
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            return stream?.bufferedReader()?.use { it.readText() } ?: ""
        } finally {
            conn.disconnect()
        }
    }
}
