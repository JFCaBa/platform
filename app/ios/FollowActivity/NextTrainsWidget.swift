import SwiftUI
import WidgetKit

struct NextTrainsEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot?
  let fetched: FetchedBoard?

  var board: ResolvedBoard? { snapshot.map { resolve($0, fetched: fetched, now: date) } }
}

struct NextTrainsProvider: TimelineProvider {
  func placeholder(in context: Context) -> NextTrainsEntry {
    NextTrainsEntry(date: Date(), snapshot: sampleSnapshot(now: Date()), fetched: nil)
  }

  /// In the gallery: the real trains if there are any, else a sample.
  func getSnapshot(in context: Context, completion: @escaping (NextTrainsEntry) -> Void) {
    let now = Date()
    let real = NextTrainsEntry(date: now, snapshot: loadSnapshot(), fetched: loadFetched())
    let empty = real.board?.trains.isEmpty ?? true
    completion(context.isPreview && empty ? NextTrainsEntry(date: now, snapshot: sampleSnapshot(now: now), fetched: nil) : real)
  }

  /// Fetches the station's board and leaves one entry a minute (the countdown moves, trains that
  /// leave disappear); asks to come back in 15 min (iOS decides when, as with Weather or Stocks).
  func getTimeline(in context: Context, completion: @escaping (Timeline<NextTrainsEntry>) -> Void) {
    let snap = loadSnapshot()
    let make: (FetchedBoard?) -> Void = { fetched in
      let now = Date()
      var entries = [NextTrainsEntry(date: now, snapshot: snap, fetched: fetched)]
      var t = now.addingTimeInterval(60 - now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60))
      while entries.count < 120 {
        entries.append(NextTrainsEntry(date: t, snapshot: snap, fetched: fetched))
        t = t.addingTimeInterval(60)
      }
      completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
    }
    guard let crs = snap?.crs else { return make(nil) }
    refreshBoard(crs: crs, completion: make)
  }
}

private let brand = Color(red: 0x1E / 255, green: 0x3A / 255, blue: 0x8A / 255)

private func amber(_ scheme: ColorScheme) -> Color {
  scheme == .dark ? Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
    : Color(red: 0xB4 / 255, green: 0x53 / 255, blue: 0x09 / 255)
}

private struct TrainRow: View {
  @Environment(\.colorScheme) var scheme
  let train: ShownTrain
  let now: Date
  let compact: Bool

  private var status: String {
    if train.cancelled { return "Cancelled" }
    if train.delayedUnknown { return "Delayed" }
    let m = Int(floor(train.departure.timeIntervalSince(now) / 60))
    if m <= 0 { return "Due" }
    return m < 60 ? "\(m) min" : "\(m / 60) h \(String(format: "%02d", m % 60))"
  }

  private var time: some View {
    Text(train.time)
      .font(compact ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
      .monospacedDigit()
      .strikethrough(train.cancelled)
      .fixedSize()
      .foregroundStyle(train.late ? amber(scheme) : Color.primary)
  }

  @ViewBuilder private var platform: some View {
    if let p = train.platform {
      Text(p)
        .font(.caption2.weight(.bold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(brand))
        .foregroundStyle(.white)
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      time
      if compact {
        // Small: time and platform only.
        Spacer(minLength: 2)
        platform
      } else {
        Text(train.destination).font(.caption).lineLimit(1).strikethrough(train.cancelled)
        Spacer(minLength: 2)
        platform
        Text(status)
          .font(.caption.weight(.semibold))
          .monospacedDigit()
          .fixedSize()
          .foregroundStyle(train.late ? amber(scheme) : Color.primary)
      }
    }
    .opacity(train.cancelled ? 0.5 : 1)
  }
}

struct NextTrainsView: View {
  @Environment(\.widgetFamily) var family
  let entry: NextTrainsEntry

  var body: some View {
    let board = entry.board
    let trains = board?.trains ?? []
    VStack(alignment: .leading, spacing: 4) {
      if let board {
        HStack(spacing: 4) {
          Text(board.name).font(.subheadline.weight(.bold)).lineLimit(1)
          if let g = board.generatedAt, entry.date.timeIntervalSince(g) > boardOldAfter {
            Text(londonHhmm(g)).font(.caption2).foregroundStyle(.secondary).fixedSize()
          }
        }
      }
      if trains.isEmpty {
        Spacer(minLength: 0)
        Text(board == nil ? "Open What Platform to see the next trains" : "No trains in the next hours")
          .font(.caption).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      } else {
        ForEach(Array(trains.prefix(4).enumerated()), id: \.offset) { _, t in
          TrainRow(train: t, now: entry.date, compact: family == .systemSmall)
        }
        Spacer(minLength: 0)
      }
    }
    .widgetBackground()
  }
}

private extension View {
  @ViewBuilder func widgetBackground() -> some View {
    if #available(iOS 17.0, *) {
      containerBackground(for: .widget) { Color(.systemBackground) }
    } else {
      padding()
    }
  }
}

struct NextTrainsWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: "NextTrainsWidget", provider: NextTrainsProvider()) { entry in
      NextTrainsView(entry: entry)
    }
    .configurationDisplayName("Next trains")
    .description("Next trains and platforms at the last station you opened.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}
