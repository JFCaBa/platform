package com.jfcaba.platform

import android.content.Context
import android.util.Log
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import java.util.concurrent.TimeUnit

/**
 * Every 15 min, while a widget is placed and there is network: fetches the board of the app's
 * station from our API, saves it and redraws the widget. It must declare the network: in the
 * background Android cuts the network of jobs that do not.
 */
class NextTrainsWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
  override fun doWork(): Result {
    val crs = NextTrainsWidgetProvider.loadSnapshot(applicationContext)?.crs
    if (crs != null) {
      try {
        fetch(crs)?.let { save(applicationContext, it) }
      } catch (e: Exception) {
        // API down or offline: the saved board stays.
        Log.w("WhatPlatform", "widget board: ${e.javaClass.simpleName}")
      }
    }
    NextTrainsWidgetProvider.refresh(applicationContext)
    return Result.success()
  }

  private fun fetch(crs: String): FetchedBoard? {
    if (!Regex("^[A-Z]{3}$").matches(crs)) return null
    val conn = URL("$API_BASE/departures/$crs").openConnection() as HttpURLConnection
    try {
      conn.connectTimeout = 10_000
      conn.readTimeout = 10_000
      conn.setRequestProperty("User-Agent", USER_AGENT)
      if (conn.responseCode != 200) return null
      val body = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
      return parseBoard(JSONObject(body), System.currentTimeMillis() / 1000)?.takeIf { it.crs == crs }
    } finally {
      conn.disconnect()
    }
  }

  companion object {
    private const val API_BASE = "https://api.whatplatform.uk"
    private const val USER_AGENT = "WhatPlatform/1.5"
    private const val PERIODIC = "platform_widget_board"
    private const val NOW = "platform_widget_board_now"
    private const val PREFS = "HomeWidgetPreferences" // home_widget's, where the snapshot is
    private const val KEY = "widget_board"

    private val online = Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

    /** Keeps the periodic fetch scheduled. UPDATE: replaces an older version's without restarting its period. */
    fun ensureScheduled(context: Context) {
      WorkManager.getInstance(context).enqueueUniquePeriodicWork(
        PERIODIC, ExistingPeriodicWorkPolicy.UPDATE,
        PeriodicWorkRequestBuilder<NextTrainsWorker>(15, TimeUnit.MINUTES).setConstraints(online).build())
    }

    /** One fetch now: on adding the widget and when the app changes station. */
    fun runNow(context: Context) {
      WorkManager.getInstance(context).enqueueUniqueWork(
        NOW, ExistingWorkPolicy.REPLACE, OneTimeWorkRequestBuilder<NextTrainsWorker>().setConstraints(online).build())
    }

    fun cancel(context: Context) {
      WorkManager.getInstance(context).run {
        cancelUniqueWork(PERIODIC)
        cancelUniqueWork(NOW)
      }
    }

    /** `GET /departures/{CRS}`; null if it is not a board. */
    fun parseBoard(json: JSONObject, fetchedAt: Long): FetchedBoard? = try {
      FetchedBoard(
        crs = json.getString("crs"),
        fetchedAt = fetchedAt,
        generatedAt = Instant.parse(json.getString("generatedAt")).epochSecond,
        services = parseServices(json.getJSONArray("services")),
      )
    } catch (_: Exception) {
      null
    }

    fun parseServices(a: JSONArray): List<WidgetService> = (0 until a.length()).mapNotNull { i ->
      val s = a.optJSONObject(i) ?: return@mapNotNull null
      if (!s.has("std") || !s.has("destination")) return@mapNotNull null
      WidgetService(
        std = s.getString("std"),
        etd = s.optStringOrNull("etd"),
        platform = s.optStringOrNull("platform"),
        destination = s.getString("destination"),
        cancelled = s.optBoolean("cancelled"),
      )
    }

    private fun services(list: List<WidgetService>) = JSONArray().apply {
      for (s in list) put(JSONObject().put("std", s.std).put("etd", s.etd ?: JSONObject.NULL)
        .put("platform", s.platform ?: JSONObject.NULL).put("destination", s.destination).put("cancelled", s.cancelled))
    }

    private fun save(context: Context, b: FetchedBoard) {
      val json = JSONObject().put("crs", b.crs).put("fetchedAt", b.fetchedAt).put("generatedAt", b.generatedAt)
        .put("services", services(b.services))
      context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, json.toString()).apply()
    }

    fun load(context: Context): FetchedBoard? = try {
      context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)?.let { s ->
        val j = JSONObject(s)
        FetchedBoard(j.getString("crs"), j.getLong("fetchedAt"), j.getLong("generatedAt"), parseServices(j.getJSONArray("services")))
      }
    } catch (_: Exception) {
      null
    }
  }
}

fun JSONObject.optStringOrNull(key: String): String? = if (!has(key) || isNull(key)) null else optString(key)
