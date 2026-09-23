package com.joshua.vector_tasks

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONArray
import kotlin.concurrent.thread

/**
 * VECTOR Tasks home-screen widget.
 *
 * Shows today's startable actions as tickable rows. Completing one re-fetches
 * and re-renders, so the finished task disappears, the next blocked task
 * unlocks and the progress bar moves -- all without opening the app.
 *
 * The list is built and ordered SERVER-SIDE. This widget holds no planning
 * logic of its own: it renders whatever the API says is startable.
 */
class NextActionWidget : AppWidgetProvider() {

    companion object {
        const val ACTION_TOGGLE = "com.joshua.vector_tasks.TOGGLE"
        const val EXTRA_TASK_ID = "task_id"
        const val EXTRA_DONE = "done"
    }

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) {
            val views = RemoteViews(context.packageName, R.layout.widget_next_action)
            views.setTextViewText(R.id.widget_primary,
                context.getString(R.string.widget_loading))
            mgr.updateAppWidget(id, views)
            thread { refresh(context, mgr, id) }
        }
    }

    /**
     * A checkbox tap arrives here. Network work must not run on the main
     * thread, so the write happens on a background thread and the widget is
     * refreshed from that same thread afterwards.
     */
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action != ACTION_TOGGLE) return
        val taskId = intent.getStringExtra(EXTRA_TASK_ID) ?: return
        val done = intent.getBooleanExtra(EXTRA_DONE, true)
        val pending = goAsync()
        thread {
            try {
                httpPost(context, if (done) "/tasks/" + taskId + "/done"
                                    else "/tasks/" + taskId + "/reopen")
            } catch (e: Exception) {
                // A failed tap must not crash the launcher; the next refresh
                // re-reads the server and shows the true state.
            } finally {
                val mgr = AppWidgetManager.getInstance(context)
                for (id in mgr.getAppWidgetIds(
                        android.content.ComponentName(context, NextActionWidget::class.java))) {
                    refresh(context, mgr, id)
                }
                pending.finish()
            }
        }
    }

    private fun refresh(context: Context, mgr: AppWidgetManager, id: Int) {
        val views = RemoteViews(context.packageName, R.layout.widget_next_action)
        try {
            val rows = JSONArray(httpGet(context, "/tasks/startable"))
            var shown = 0
            for (i in 0 until 5) {
                if (i < rows.length()) {
                    val o = rows.getJSONObject(i)
                    val mins = o.optInt("minutes", 30)
                    bindRow(context, views, i,
                        o.optString("id", null),
                        o.optString("title", "Untitled task"),
                        mins.toString() + " min",
                        false)
                    shown++
                } else {
                    bindRow(context, views, i, null, "", "", false)
                }
            }
            if (shown == 0) {
                views.setViewVisibility(R.id.widget_empty,
                    android.view.View.VISIBLE)
                views.setTextViewText(R.id.widget_empty,
                    context.getString(R.string.widget_all_clear))
            } else {
                views.setViewVisibility(R.id.widget_empty,
                    android.view.View.GONE)
            }
            // Progress: how many of today's tasks are already done.
            val today = org.json.JSONObject(httpGet(context, "/today"))
            val done = today.optJSONArray("done_today")?.length() ?: 0
            val total = done + shown
            val pct = if (total > 0) (100 * done / total) else 0
            views.setTextViewText(R.id.widget_badge, done.toString() + "/" +
                total.toString() + " DONE")
            views.setProgressBar(R.id.widget_progress, 100, pct, false)
            views.setTextViewText(R.id.widget_secondary,
                if (total > 0) pct.toString() + "% of today complete" else "")
        } catch (e: Exception) {
            for (i in 0 until 5) bindRow(context, views, i, null, "", "", false)
            views.setViewVisibility(R.id.widget_empty, android.view.View.VISIBLE)
            views.setTextViewText(R.id.widget_empty,
                context.getString(R.string.widget_offline))
            views.setTextViewText(R.id.widget_badge, "")
            views.setTextViewText(R.id.widget_secondary, "")
        }

        // "Ask Hermes" opens the app, where a goal becomes a plan.
        val ask = Intent(context, MainActivity::class.java)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        views.setOnClickPendingIntent(R.id.widget_ask,
            PendingIntent.getActivity(context, 1, ask, flags))
        val open = Intent(context, MainActivity::class.java)
        views.setOnClickPendingIntent(R.id.widget_root,
            PendingIntent.getActivity(context, 0, open, flags))
        mgr.updateAppWidget(id, views)
    }


    /**
     * Render one task row into the widget.
     *
     * RemoteViews has no adapter and no dynamic child views, so the rows are
     * laid out statically in XML and shown/hidden as needed. Each row's
     * checkbox and body carry their own PendingIntent because the ids are
     * per-row.
     */
    private fun bindRow(
        context: Context,
        views: RemoteViews,
        idx: Int,
        taskId: String?,
        title: String,
        meta: String,
        done: Boolean
    ) {
        val rowIds = intArrayOf(
            R.id.row0, R.id.row1, R.id.row2, R.id.row3, R.id.row4)
        val boxIds = intArrayOf(
            R.id.row0_box, R.id.row1_box, R.id.row2_box,
            R.id.row3_box, R.id.row4_box)
        val txtIds = intArrayOf(
            R.id.row0_text, R.id.row1_text, R.id.row2_text,
            R.id.row3_text, R.id.row4_text)
        val subIds = intArrayOf(
            R.id.row0_sub, R.id.row1_sub, R.id.row2_sub,
            R.id.row3_sub, R.id.row4_sub)

        if (taskId == null) {
            views.setViewVisibility(rowIds[idx], android.view.View.GONE)
            return
        }
        views.setViewVisibility(rowIds[idx], android.view.View.VISIBLE)
        views.setTextViewText(boxIds[idx], if (done) "\u2713" else "\u25CB")
        views.setTextViewText(txtIds[idx], title)
        views.setTextViewText(subIds[idx], meta)

        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        // Tapping the checkbox completes the task; tapping the text opens the
        // app. Both are needed: one-tap finish, or go in and read the detail.
        val toggle = Intent(context, javaClass).apply {
            action = ACTION_TOGGLE
            putExtra(EXTRA_TASK_ID, taskId)
            putExtra(EXTRA_DONE, !done)
            data = android.net.Uri.parse("vectortoggle://" + taskId)
        }
        views.setOnClickPendingIntent(
            boxIds[idx], PendingIntent.getBroadcast(context, 100 + idx, toggle, flags))
        val open = Intent(context, MainActivity::class.java)
        views.setOnClickPendingIntent(
            txtIds[idx], PendingIntent.getActivity(context, 200 + idx, open, flags))
        views.setOnClickPendingIntent(
            subIds[idx], PendingIntent.getActivity(context, 300 + idx, open, flags))
    }


    /** Group digits so a 7-figure amount stays readable in a narrow widget. */
    private fun fmt(v: Double): String = String.format("%,.0f", v)

    private fun httpGet(context: Context, path: String): String =
        http(context, "GET", path, null)

    private fun httpPost(context: Context, path: String): String =
        http(context, "POST", path, "{}")

    /**
     * Single HTTP entry point. A widget provider runs on the main thread, so
     * every caller is responsible for being off it.
     */
    private fun http(context: Context, method: String, path: String,
                     body: String?): String {
        val base = context.getString(R.string.vector_api_base).trimEnd('/')
        val userId = context.getString(R.string.vector_user_id)
        val key = context.getString(R.string.vector_api_key)
        val conn = (URL(base + path).openConnection() as HttpURLConnection).apply {
            requestMethod = method
            connectTimeout = 8000
            readTimeout = 8000
            setRequestProperty("X-User-Id", userId)
            setRequestProperty("Accept", "application/json")
            if (key.isNotEmpty()) setRequestProperty("X-Api-Key", key)
            if (body != null) {
                doOutput = true
                setRequestProperty("Content-Type", "application/json")
            }
        }
        try {
            if (body != null) {
                conn.outputStream.use { it.write(body.toByteArray()) }
            }
            val code = conn.responseCode
            val stream = if (code in 200..299) conn.inputStream else conn.errorStream
            return stream?.bufferedReader()?.use { it.readText() } ?: ""
        } finally {
            conn.disconnect()
        }
    }


}
