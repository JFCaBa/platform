package com.jfcaba.platform

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.view.View
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import es.antonborri.home_widget.HomeWidgetProvider
import org.json.JSONObject

/** Next trains of the last station opened: the app leaves it (lib/widget) and NextTrainsWorker refreshes the board. */
class NextTrainsWidgetProvider : HomeWidgetProvider() {
  private val rows = listOf(
    Row(R.id.row0, R.id.time0, R.id.dest0, R.id.plat0, R.id.status0),
    Row(R.id.row1, R.id.time1, R.id.dest1, R.id.plat1, R.id.status1),
    Row(R.id.row2, R.id.time2, R.id.dest2, R.id.plat2, R.id.status2),
    Row(R.id.row3, R.id.time3, R.id.dest3, R.id.plat3, R.id.status3),
  )

  private data class Row(val row: Int, val time: Int, val dest: Int, val plat: Int, val status: Int)

  override fun onEnabled(context: Context) {
    super.onEnabled(context)
    NextTrainsWorker.ensureScheduled(context)
    NextTrainsWorker.runNow(context)
  }

  override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray, widgetData: SharedPreferences) {
    NextTrainsWorker.ensureScheduled(context) // in case it was lost (app update, etc.)
    val snap = parseSnapshot(widgetData.getString(SNAPSHOT_KEY, null))
    val fetched = NextTrainsWorker.load(context)
    // A new station in the app: fetch its board now, once (not again on every redraw if it fails).
    if (snap != null && fetched?.crs != snap.crs && widgetData.getString(ASKED_KEY, null) != snap.crs) {
      widgetData.edit().putString(ASKED_KEY, snap.crs).apply()
      NextTrainsWorker.runNow(context)
    }
    val now = System.currentTimeMillis() / 1000
    val board = snap?.let { resolve(it, fetched, now) }
    val trains = board?.trains.orEmpty()
    for (id in appWidgetIds) {
      val views = RemoteViews(context.packageName, R.layout.next_trains_widget)
      views.setOnClickPendingIntent(R.id.widget_root, HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java))
      views.setTextViewText(R.id.station, board?.name ?: "")
      val g = board?.generatedAt
      if (g != null && now - g > BOARD_OLD_AFTER_SEC) {
        views.setViewVisibility(R.id.updated, View.VISIBLE)
        views.setTextViewText(R.id.updated, londonHhmm(g))
      } else {
        views.setViewVisibility(R.id.updated, View.GONE)
      }
      views.setViewVisibility(R.id.empty, if (trains.isEmpty()) View.VISIBLE else View.GONE)
      views.setTextViewText(R.id.empty, context.getString(if (snap == null) R.string.widget_empty else R.string.widget_no_trains))
      rows.forEachIndexed { i, r ->
        val t = trains.getOrNull(i)
        if (t == null) views.setViewVisibility(r.row, View.GONE) else fill(context, views, r, t)
      }
      appWidgetManager.updateAppWidget(id, views)
    }
    // Wake up when the first train leaves, so trains that left do not stay on screen (the 15 min
    // refresh may come late). Inexact alarm, no special permission. Same cut-off as resolve().
    trains.firstOrNull { !it.delayedUnknown }?.let {
      scheduleRefresh(context, maxOf((it.dep + 61) * 1000, System.currentTimeMillis() + 15_000))
    }
  }

  private fun fill(context: Context, views: RemoteViews, r: Row, t: ShownTrain) {
    views.setViewVisibility(r.row, View.VISIBLE)
    views.setFloat(r.row, "setAlpha", if (t.cancelled) 0.5f else 1f)
    val color = context.getColor(if (t.late) R.color.widget_amber else R.color.widget_text)
    views.setTextViewText(r.time, t.time)
    views.setTextColor(r.time, color)
    views.setInt(r.time, "setPaintFlags", if (t.cancelled) STRIKE else 0)
    views.setTextViewText(r.dest, t.destination)
    val p = t.platform
    if (p == null) {
      views.setViewVisibility(r.plat, View.GONE)
    } else {
      views.setViewVisibility(r.plat, View.VISIBLE)
      views.setTextViewText(r.plat, p)
    }
    // A status, not a countdown: with the app closed the widget is redrawn every ~15 min, and a
    // "10 min" would go stale. The time column already shows the expected time.
    val status = context.getString(
      when {
        t.cancelled -> R.string.widget_cancelled
        t.delayedUnknown -> R.string.widget_delayed
        t.late -> R.string.widget_late
        else -> R.string.widget_on_time
      })
    views.setTextViewText(r.status, status)
    views.setTextColor(r.status, color)
  }

  override fun onDisabled(context: Context) {
    super.onDisabled(context)
    context.getSystemService(AlarmManager::class.java)?.cancel(refreshIntent(context))
    NextTrainsWorker.cancel(context)
  }

  private fun scheduleRefresh(context: Context, atMillis: Long) {
    context.getSystemService(AlarmManager::class.java)?.set(AlarmManager.RTC, atMillis, refreshIntent(context))
  }

  private fun refreshIntent(context: Context): PendingIntent =
    PendingIntent.getBroadcast(context, 0, updateIntent(context), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

  companion object {
    private const val SNAPSHOT_KEY = "next_trains"
    private const val ASKED_KEY = "widget_asked_crs"
    private const val STRIKE = android.graphics.Paint.STRIKE_THRU_TEXT_FLAG or android.graphics.Paint.ANTI_ALIAS_FLAG

    private fun updateIntent(context: Context) = Intent(context, NextTrainsWidgetProvider::class.java).apply {
      action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
      val ids = AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, NextTrainsWidgetProvider::class.java))
      putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
    }

    /** Redraws the placed widgets (after a fetch). */
    fun refresh(context: Context) = context.sendBroadcast(updateIntent(context))

    fun loadSnapshot(context: Context): WidgetSnapshot? =
      parseSnapshot(context.getSharedPreferences("HomeWidgetPreferences", Context.MODE_PRIVATE).getString(SNAPSHOT_KEY, null))

    /** The app's snapshot; null when absent, unreadable or from an older shape. */
    fun parseSnapshot(s: String?): WidgetSnapshot? = try {
      s?.let { JSONObject(it) }?.takeIf { it.has("crs") }?.let { j ->
        val f = j.optJSONArray("filters")
        val b = j.optJSONObject("board")
        WidgetSnapshot(
          crs = j.getString("crs"),
          name = j.optString("name", j.getString("crs")),
          filters = if (f == null) emptySet() else (0 until f.length()).map { f.getString(it) }.toSet(),
          generatedAt = b?.getLong("generatedAt"),
          services = b?.getJSONArray("services")?.let { NextTrainsWorker.parseServices(it) }.orEmpty(),
        )
      }
    } catch (_: Exception) {
      null
    }
  }
}
