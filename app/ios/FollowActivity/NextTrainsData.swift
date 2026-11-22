import Foundation

// Data for the next-trains home screen widget: what the app leaves (lib/widget/home_widget.dart),
// the board the widget fetches itself, and how both become rows. Foundation only, so it can be
// tested outside the simulator. Same rules as android/.../NextTrainsData.kt.

struct WidgetService: Codable {
  let std: String
  let etd: String?
  let platform: String?
  let destination: String
  let cancelled: Bool?
}

struct SnapshotBoard: Codable {
  let generatedAt: Double
  let services: [WidgetService]
}

/// What the app leaves: the station on screen, its filters and its latest board.
struct WidgetSnapshot: Codable {
  let crs: String
  let name: String
  let filters: [String]?
  let board: SnapshotBoard?
}

/// A board the widget fetched itself.
struct FetchedBoard: Codable {
  let crs: String
  let fetchedAt: Double
  let generatedAt: Double
  let services: [WidgetService]
}

struct ShownTrain {
  /// The time to show: the expected one when Darwin gives it, else the scheduled one.
  let time: String
  let departure: Date
  let destination: String
  let platform: String?
  let cancelled: Bool
  /// Expected later than scheduled, or "Delayed".
  let late: Bool
  /// Darwin only says "Delayed", no time.
  let delayedUnknown: Bool
}

struct ResolvedBoard {
  let name: String
  let generatedAt: Date?
  let trains: [ShownTrain]
}

let london = TimeZone(identifier: "Europe/London")!

/// A board older than this shows when it was updated.
let boardOldAfter: TimeInterval = 10 * 60

/// A "Delayed" train (no time) stays this long after its scheduled time.
let delayedKeep: TimeInterval = 15 * 60

private func isHhmm(_ s: String?) -> Bool {
  guard let s, s.count == 5 else { return false }
  let c = Array(s)
  return c[2] == ":" && [c[0], c[1], c[3], c[4]].allSatisfy { $0.isASCII && $0.isNumber }
}

/// A London "HH:MM" as an instant: of yesterday's, today's and tomorrow's London date, the one
/// nearest to [now] (right across midnight and clock changes).
func departureAt(_ hhmm: String, now: Date) -> Date? {
  guard isHhmm(hhmm), let h = Int(hhmm.prefix(2)), let m = Int(hhmm.suffix(2)) else { return nil }
  var cal = Calendar(identifier: .gregorian)
  cal.timeZone = london
  let today = cal.dateComponents([.year, .month, .day], from: now)
  var best: Date?
  for day in [-1, 0, 1] {
    var c = today
    c.day = (today.day ?? 1) + day
    c.hour = h
    c.minute = m
    guard let at = cal.date(from: c) else { continue }
    if best == nil || abs(at.timeIntervalSince(now)) < abs(best!.timeIntervalSince(now)) { best = at }
  }
  return best
}

func londonHhmm(_ d: Date) -> String {
  let f = DateFormatter()
  f.dateFormat = "HH:mm"
  f.timeZone = london
  return f.string(from: d)
}

/// The trains to draw at [now], dated around the board's generation time: the newer of the app's board and the widget's own for the app's
/// station, filtered by the app's destinations, without those that left.
func resolve(_ snap: WidgetSnapshot, fetched: FetchedBoard?, now: Date) -> ResolvedBoard {
  var services = snap.board?.services ?? []
  var generatedAt = snap.board?.generatedAt
  if let f = fetched, f.crs == snap.crs, f.generatedAt > (generatedAt ?? 0) {
    services = f.services
    generatedAt = f.generatedAt
  }
  let filters = Set(snap.filters ?? [])
  // Times are dated around when the board was made, not now: a board from last night must not
  // come back as today's trains.
  let anchor = generatedAt.map { Date(timeIntervalSince1970: $0) } ?? now
  var trains: [ShownTrain] = []
  for s in services where filters.isEmpty || filters.contains(s.destination) {
    let cancelled = (s.cancelled ?? false) || s.etd == "Cancelled"
    let delayedUnknown = !cancelled && s.etd == "Delayed"
    let expected = !cancelled && isHhmm(s.etd) ? s.etd! : s.std
    guard let dep = departureAt(expected, now: anchor) else { continue }
    let keepUntil = dep.addingTimeInterval(delayedUnknown ? delayedKeep : 60)
    guard keepUntil >= now else { continue }
    trains.append(ShownTrain(
      time: expected, departure: dep, destination: s.destination,
      platform: cancelled ? nil : s.platform, cancelled: cancelled,
      late: delayedUnknown || (!cancelled && expected != s.std), delayedUnknown: delayedUnknown))
  }
  trains.sort { $0.departure < $1.departure }
  return ResolvedBoard(name: snap.name, generatedAt: generatedAt.map { Date(timeIntervalSince1970: $0) }, trains: trains)
}

private func parseDate(_ s: String) -> Date? {
  let f = ISO8601DateFormatter()
  if let d = f.date(from: s) { return d }
  f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return f.date(from: s)
}

/// `GET /departures/{CRS}` of our API.
func parseBoard(_ data: Data, fetchedAt: Date) -> FetchedBoard? {
  guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let crs = j["crs"] as? String,
        let gen = (j["generatedAt"] as? String).flatMap(parseDate),
        let list = j["services"] as? [Any] else { return nil }
  var services: [WidgetService] = []
  for case let s as [String: Any] in list {
    guard let std = s["std"] as? String, let dest = s["destination"] as? String else { continue }
    services.append(WidgetService(std: std, etd: s["etd"] as? String, platform: s["platform"] as? String,
                                  destination: dest, cancelled: s["cancelled"] as? Bool))
  }
  return FetchedBoard(crs: crs, fetchedAt: fetchedAt.timeIntervalSince1970,
                      generatedAt: gen.timeIntervalSince1970, services: services)
}

let appGroup = "group.com.jfcaba.platform"
private let snapshotKey = "next_trains"
private let fetchedKey = "widget_board"
private let apiBase = "https://api.whatplatform.uk"

func loadSnapshot() -> WidgetSnapshot? {
  guard let json = UserDefaults(suiteName: appGroup)?.string(forKey: snapshotKey),
        let data = json.data(using: .utf8) else { return nil }
  return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
}

func loadFetched() -> FetchedBoard? {
  guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: fetchedKey) else { return nil }
  return try? JSONDecoder().decode(FetchedBoard.self, from: data)
}

/// Fetches [crs]'s board (at most once a minute) and saves it; on failure, the saved one.
func refreshBoard(crs: String, completion: @escaping (FetchedBoard?) -> Void) {
  let saved = loadFetched().flatMap { $0.crs == crs ? $0 : nil }
  if let saved, Date().timeIntervalSince1970 - saved.fetchedAt < 60 { return completion(saved) }
  guard crs.count == 3, let url = URL(string: "\(apiBase)/departures/\(crs)") else { return completion(saved) }
  var req = URLRequest(url: url, timeoutInterval: 10)
  req.setValue("WhatPlatform/1.5", forHTTPHeaderField: "User-Agent")
  URLSession.shared.dataTask(with: req) { data, resp, _ in
    guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
          let b = parseBoard(data, fetchedAt: Date()), b.crs == crs else { return completion(saved) }
    if let encoded = try? JSONEncoder().encode(b) { UserDefaults(suiteName: appGroup)?.set(encoded, forKey: fetchedKey) }
    completion(b)
  }.resume()
}

/// What the widget gallery shows before there are real trains.
func sampleSnapshot(now: Date) -> WidgetSnapshot {
  func s(_ min: Double, _ dest: String, _ platform: String, late: Double = 0) -> WidgetService {
    let std = londonHhmm(now.addingTimeInterval(min * 60))
    return WidgetService(std: std, etd: late > 0 ? londonHhmm(now.addingTimeInterval((min + late) * 60)) : "On time",
                         platform: platform, destination: dest, cancelled: false)
  }
  return WidgetSnapshot(crs: "EUS", name: "London Euston", filters: nil, board: SnapshotBoard(
    generatedAt: now.timeIntervalSince1970,
    services: [
      s(3, "Birmingham New Street", "3"),
      s(7, "Manchester Piccadilly", "15", late: 4),
      s(12, "Milton Keynes Central", "9"),
      s(20, "Glasgow Central", "1"),
    ]))
}
