import ActivityKit
import Foundation

/// The followed train's Live Activity. Shared by the app (starts and ends it) and the widget
/// extension (draws it). The server pushes `ContentState` as JSON with exactly these keys
/// (api/platform_api/live.py): `departs` is epoch seconds, not a Date, so decoding is unambiguous.
@available(iOS 16.1, *)
struct TrainActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var departs: Double?
    var status: String
    var platform: String?
    var `where`: String?
    var cancelled: Bool

    var departure: Date? { departs.map { Date(timeIntervalSince1970: $0) } }
  }

  /// "16:42 to Peterborough"
  var title: String
  /// CRS of the station it leaves from.
  var station: String
}
