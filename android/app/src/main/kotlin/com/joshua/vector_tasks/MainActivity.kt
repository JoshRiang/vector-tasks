package com.joshua.vector_tasks

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/**
 * Refreshes the home-screen widget whenever the app is opened.
 *
 * An AppWidgetProvider only runs on its updatePeriodMillis schedule (30 min) or
 * when the launcher chooses to, so after installing an update the home screen
 * keeps showing the OLD widget until it is removed and re-added. Refreshing here
 * means opening the app once is enough to pick up new widget code.
 */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        try {
            val mgr = AppWidgetManager.getInstance(applicationContext)
            val ids = mgr.getAppWidgetIds(
                ComponentName(applicationContext, NextActionWidget::class.java))
            if (ids.isNotEmpty()) {
                val intent = Intent(applicationContext, NextActionWidget::class.java)
                intent.action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                intent.putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                sendBroadcast(intent)
            }
        } catch (e: Exception) {
            // A refresh failure must never stop the app from opening.
        }
    }
}
