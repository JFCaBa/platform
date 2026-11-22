package com.jfcaba.platform

import java.time.Instant
import java.time.ZoneId
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import kotlin.math.abs

// Data for the next-trains home screen widget: what the app leaves (lib/widget/home_widget.dart),
// the board the widget fetches itself (NextTrainsWorker), and how both become rows. No Android, so
// it runs on the JVM. Same rules as ios/FollowActivity/NextTrainsData.swift.

data class WidgetService(
  val std: String,
  val etd: String?,
  val platform: String?,
  val destination: String,
  val cancelled: Boolean,
)

/** What the app leaves: the station on screen, its filters and its latest board (epoch seconds). */
data class WidgetSnapshot(
  val crs: String,
  val name: String,
  val filters: Set<String>,
  val generatedAt: Long?,
  val services: List<WidgetService>,
)

/** A board the widget fetched itself. Epoch seconds. */
data class FetchedBoard(val crs: String, val fetchedAt: Long, val generatedAt: Long, val services: List<WidgetService>)

data class ShownTrain(
  /** Expected time when Darwin gives one, else scheduled. */
  val time: String,
  /** Epoch seconds. */
  val dep: Long,
  val destination: String,
  val platform: String?,
  val cancelled: Boolean,
  val late: Boolean,
  /** Darwin only says "Delayed", no time. */
  val delayedUnknown: Boolean,
)

data class ResolvedBoard(val name: String, val generatedAt: Long?, val trains: List<ShownTrain>)

val LONDON: ZoneId = ZoneId.of("Europe/London")

/** A board older than this shows when it was updated. */
const val BOARD_OLD_AFTER_SEC = 10 * 60L

/** A "Delayed" train (no time) stays this long after its scheduled time. */
const val DELAYED_KEEP_SEC = 15 * 60L

private val HHMM = Regex("^\\d{2}:\\d{2}$")

/**
 * A London "HH:MM" as epoch seconds: of yesterday's, today's and tomorrow's London date, the one
 * nearest to [now] (right across midnight and clock changes). Null if it is not a time.
 */
fun departureAt(hhmm: String, now: Long): Long? {
  if (!HHMM.matches(hhmm)) return null
  val h = hhmm.substring(0, 2).toInt()
  val m = hhmm.substring(3).toInt()
  if (h > 23 || m > 59) return null
  val today = Instant.ofEpochSecond(now).atZone(LONDON).toLocalDate()
  return (-1L..1L).map { ZonedDateTime.of(today.plusDays(it).atTime(h, m), LONDON).toEpochSecond() }
    .minByOrNull { abs(it - now) }
}

fun londonHhmm(epochSec: Long): String =
  Instant.ofEpochSecond(epochSec).atZone(LONDON).format(DateTimeFormatter.ofPattern("HH:mm"))

/**
 * The trains to draw at [now]: the newer of the app's board and the widget's own for the app's
 * station, filtered by the app's destinations, without those that left.
 */
fun resolve(snap: WidgetSnapshot, fetched: FetchedBoard?, now: Long): ResolvedBoard {
  var services = snap.services
  var generatedAt = snap.generatedAt
  if (fetched != null && fetched.crs == snap.crs && fetched.generatedAt > (generatedAt ?: 0)) {
    services = fetched.services
    generatedAt = fetched.generatedAt
  }
  // Times are dated around when the board was made, not now: a board from last night must not
  // come back as today's trains.
  val anchor = generatedAt ?: now
  val trains = services.mapNotNull { s ->
    if (snap.filters.isNotEmpty() && s.destination !in snap.filters) return@mapNotNull null
    val cancelled = s.cancelled || s.etd == "Cancelled"
    val delayedUnknown = !cancelled && s.etd == "Delayed"
    val expected = if (!cancelled && s.etd != null && HHMM.matches(s.etd)) s.etd else s.std
    val dep = departureAt(expected, anchor) ?: return@mapNotNull null
    if (dep + (if (delayedUnknown) DELAYED_KEEP_SEC else 60) < now) return@mapNotNull null
    ShownTrain(
      time = expected, dep = dep, destination = s.destination,
      platform = if (cancelled) null else s.platform, cancelled = cancelled,
      late = delayedUnknown || (!cancelled && expected != s.std), delayedUnknown = delayedUnknown,
    )
  }.sortedBy { it.dep }
  return ResolvedBoard(snap.name, generatedAt, trains)
}
