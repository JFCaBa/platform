package com.jfcaba.platform

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class NextTrainsDataTest {
  private fun at(s: String) = Instant.parse(s).epochSecond
  private fun svc(std: String, etd: String? = "On time", dest: String = "Cambridge", c: Boolean = false) =
    WidgetService(std, etd, "9", dest, c)

  private val now = at("2026-11-22T14:00:00Z")
  private val services = listOf(svc("13:58"), svc("14:05", "14:09"), svc("13:50", "Delayed"), svc("14:02", "Cancelled"),
    svc("14:20", dest = "Leeds", c = true))
  private fun snap(filters: Set<String> = emptySet(), gen: Long? = now - 60, s: List<WidgetService> = services) =
    WidgetSnapshot("KGX", "London Kings Cross", filters, gen, s)

  @Test fun midnightAndClockChange() {
    assertEquals(at("2026-11-22T23:58:00Z"), departureAt("23:58", at("2026-11-23T00:01:00Z")))
    assertEquals(at("2026-11-23T00:05:00Z"), departureAt("00:05", at("2026-11-22T23:50:00Z")))
    assertEquals(at("2026-07-01T13:00:00Z"), departureAt("14:00", at("2026-07-01T12:30:00Z")))
    assertNull(departureAt("Delayed", now))
  }

  @Test fun dropsLeftAndSorts() {
    val r = resolve(snap(), null, now)
    assertEquals(listOf("13:50", "14:02", "14:09", "14:20"), r.trains.map { it.time })
    assertTrue(r.trains[0].delayedUnknown && r.trains[0].late)
    assertTrue(r.trains[1].cancelled && r.trains[1].platform == null && !r.trains[1].late)
    assertTrue(r.trains[2].late)
  }

  @Test fun yesterdaysBoardShowsNothing() {
    // Offline overnight: a board made at 22:00 yesterday, drawn at 09:00 today.
    val old = snap(gen = at("2026-11-21T22:00:00Z"), s = listOf(svc("22:30"), svc("23:50")))
    assertTrue(resolve(old, null, at("2026-11-22T09:00:00Z")).trains.isEmpty())
  }

  @Test fun filters() {
    assertEquals(listOf("Leeds"), resolve(snap(setOf("Leeds")), null, now).trains.map { it.destination })
    assertTrue(resolve(snap(setOf("York")), null, now).trains.isEmpty())
  }

  @Test fun boardChoice() {
    val newer = FetchedBoard("KGX", now, now, listOf(svc("14:30", dest = "Ely")))
    assertEquals(listOf("Ely"), resolve(snap(), newer, now).trains.map { it.destination })
    val other = FetchedBoard("EUS", now, now + 100, listOf(svc("14:30", dest = "Crewe")))
    assertTrue(resolve(snap(), other, now).trains.none { it.destination == "Crewe" })
    val older = FetchedBoard("KGX", now, now - 600, listOf(svc("14:30", dest = "Ely")))
    assertTrue(resolve(snap(), older, now).trains.none { it.destination == "Ely" })
    assertEquals(1, resolve(snap(gen = null, s = emptyList()), newer, now).trains.size)
  }

  @Test fun parsesApiAndSnapshot() {
    val api = JSONObject("""{"crs":"EUS","name":"London Euston","generatedAt":"2026-11-22T14:55:18Z","services":[
      {"std":"14:56","etd":"On time","platform":null,"destination":"Birmingham New Street","cancelled":false},
      {"std":"15:01","etd":"15:04","platform":"3","destination":"Chester","cancelled":false},{"bad":1}]}""")
    val b = NextTrainsWorker.parseBoard(api, 100)!!
    assertEquals("EUS", b.crs)
    assertEquals(at("2026-11-22T14:55:18Z"), b.generatedAt)
    assertEquals(listOf(null, "3"), b.services.map { it.platform })
    val s = NextTrainsWidgetProvider.parseSnapshot("""{"crs":"KGX","name":"K","filters":["Leeds"],"board":null}""")!!
    assertEquals(setOf("Leeds"), s.filters)
    assertNull(s.generatedAt)
    assertNull(NextTrainsWidgetProvider.parseSnapshot("""{"station":"x","trains":[]}"""))
    assertNull(NextTrainsWidgetProvider.parseSnapshot("garbage"))
  }
}
