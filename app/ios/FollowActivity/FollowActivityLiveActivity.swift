import ActivityKit
import SwiftUI
import WidgetKit

/// Countdown to departure, drawn by iOS so it ticks without pushes. Only for a time still ahead:
/// a reversed range would crash the widget.
@available(iOS 16.1, *)
private struct Countdown: View {
  let state: TrainActivityAttributes.ContentState
  var body: some View {
    if state.cancelled {
      Text("Cancelled").foregroundStyle(.red)
    } else if let d = state.departure, d > Date() {
      Text(timerInterval: Date()...d, countsDown: true).monospacedDigit()
    } else if state.departure != nil {
      Text("Due")
    } else {
      Text(state.status.isEmpty ? "Delayed" : state.status).foregroundStyle(.orange)
    }
  }
}

@available(iOS 16.1, *)
private struct PlatformTile: View {
  let platform: String?
  var body: some View {
    VStack(spacing: 0) {
      Text("Platform").font(.caption2)
      Text(platform ?? "–").font(.system(size: 30, weight: .heavy)).minimumScaleFactor(0.5)
    }
    .frame(minWidth: 70)
    .padding(.vertical, 6)
    .padding(.horizontal, 8)
    .background(RoundedRectangle(cornerRadius: 12).fill(platform == nil ? Color.gray.opacity(0.3) : Color.blue))
    .foregroundStyle(.white)
  }
}

@available(iOS 16.1, *)
struct FollowActivityLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TrainActivityAttributes.self) { context in
      // Lock screen / banner
      HStack(alignment: .center, spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(context.attributes.title).font(.headline).lineLimit(1)
          Countdown(state: context.state).font(.system(size: 28, weight: .heavy))
          if !context.state.status.isEmpty && !context.state.cancelled {
            Text(context.state.status).font(.subheadline).foregroundStyle(.secondary)
          }
          if let w = context.state.where {
            Label(w, systemImage: "tram.fill").font(.caption).lineLimit(2)
          }
        }
        Spacer(minLength: 0)
        PlatformTile(platform: context.state.platform)
      }
      .padding(14)
      .activityBackgroundTint(Color.black.opacity(0.75))
      .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Text(context.attributes.title).font(.caption).lineLimit(2)
        }
        DynamicIslandExpandedRegion(.trailing) {
          PlatformTile(platform: context.state.platform)
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 2) {
            Countdown(state: context.state).font(.title2.bold())
            if let w = context.state.where {
              Text(w).font(.caption).lineLimit(1)
            }
          }
        }
      } compactLeading: {
        Text(context.state.platform.map { "P\($0)" } ?? "P–").bold()
      } compactTrailing: {
        Countdown(state: context.state).frame(maxWidth: 56)
      } minimal: {
        Text(context.state.platform ?? "–").bold()
      }
    }
  }
}
