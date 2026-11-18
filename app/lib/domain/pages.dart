import 'package:timezone/timezone.dart' as tz;

import '../data/departures.dart';

/// Darwin's largest timeOffset: the last page reaches about 4 h ahead.
const maxOffset = 119;

/// Pages are asked at multiples of this, so a station's users share nginx cache entries.
const offsetStep = 15;

/// Minutes from [nowUtc] to [hhmm] on London clocks, in [-720, 720): "00:05" is 15 min after
/// 23:50, "23:50" is 20 min before 00:10.
int? minutesUntil(String hhmm, DateTime nowUtc) {
  final parts = hhmm.split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null) return null;
  final now = tz.TZDateTime.from(nowUtc, tz.getLocation('Europe/London'));
  final diff = (h * 60 + m) - (now.hour * 60 + now.minute);
  return (diff + 720) % 1440 - 720;
}

/// One train across boards: Darwin's serviceId, else scheduled time and destination.
String trainKey(Departure d) => d.serviceId ?? '${d.std}|${d.destination}';

/// Base board plus later pages as one list, by scheduled time. A train in several of them is
/// shown once, from the most recently generated copy (the base, refreshed every 30 s, takes
/// over a page's train once it reaches it). Within the time the base covers, the base is the
/// truth: a page train it no longer lists has left or gone, and is dropped.
List<Departure> mergeServices(Board base, List<Board> pages, DateTime nowUtc) {
  if (pages.isEmpty) return base.services;
  int at(Departure d) => minutesUntil(d.std, nowUtc) ?? 0;
  // Strictly before the base's end: trains in its last minute may be cut off by the row limit.
  final baseEnd = endIn(base, nowUtc) ?? startIn(base, nowUtc);
  final best = <String, (Departure, DateTime)>{};
  final order = <String>[]; // first appearance: base order, then each page's
  void add(Departure d, DateTime generated) {
    final k = trainKey(d);
    final seen = best[k];
    if (seen == null) order.add(k);
    if (seen == null || generated.isAfter(seen.$2)) best[k] = (d, generated);
  }

  for (final d in base.services) {
    add(d, base.generatedAt);
  }
  final baseKeys = {for (final d in base.services) trainKey(d)};
  for (final p in pages) {
    for (final d in p.services) {
      if (baseKeys.contains(trainKey(d)) || at(d) >= baseEnd) add(d, p.generatedAt);
    }
  }
  final idx = {for (var i = 0; i < order.length; i++) order[i]: i};
  final out = [for (final k in order) best[k]!.$1];
  // List.sort is not stable: ties (same minute) keep Darwin's order through the index.
  out.sort((a, b) {
    final c = at(a).compareTo(at(b));
    return c != 0 ? c : idx[trainKey(a)]!.compareTo(idx[trainKey(b)]!);
  });
  return out;
}

/// Minutes from now to where [b] starts: Darwin's offset counts from when the board was made.
int startIn(Board b, DateTime nowUtc) => b.timeOffset - nowUtc.difference(b.generatedAt).inMinutes;

/// Minutes from now to the end of what [b] lists: its whole 120-min window when complete, else
/// its last train. Null for an incomplete board with no trains.
int? endIn(Board b, DateTime nowUtc) {
  if (b.complete) return startIn(b, nowUtc) + 120;
  int? last;
  for (final d in b.services) {
    final m = minutesUntil(d.std, nowUtc);
    if (m != null && (last == null || m > last)) last = m;
  }
  return last;
}

/// The pages that still follow on from [base] without a gap, in order. Offsets are relative to
/// when each page was made, so after a while a page can start beyond what the (refreshed) base
/// and the earlier pages list: it and the pages after it are left out (load them again). A page
/// the base has caught up with adds nothing and is left out too.
List<Board> contiguousPages(Board base, List<Board> pages, DateTime nowUtc) => _chain(base, pages, nowUtc).$1;

/// Minutes from now to the end of what [base] and its contiguous [pages] list.
int coveredEnd(Board base, List<Board> pages, DateTime nowUtc) => _chain(base, pages, nowUtc).$2;

(List<Board>, int) _chain(Board base, List<Board> pages, DateTime nowUtc) {
  var covered = endIn(base, nowUtc) ?? startIn(base, nowUtc);
  final out = <Board>[];
  for (final p in pages) {
    if (startIn(p, nowUtc) > covered) break;
    final end = endIn(p, nowUtc);
    if (end == null || end <= covered) continue; // all inside what is already listed: adds nothing
    covered = end;
    out.add(p);
  }
  return (out, covered);
}

/// Offset of the next page, or null when Darwin cannot reach further.
/// [prevStart]/[prevComplete]: the last board loaded, its start in minutes from now
/// ([startIn]; the base is about 0). [lastMinutes]: minutes from now to the last train listed.
int? nextOffset({required int prevStart, required bool prevComplete, required int? lastMinutes}) {
  if (prevStart >= maxOffset) return null;
  final m = lastMinutes;
  if (prevComplete || m == null) return _cap(prevStart + 120);
  final q = _cap(m ~/ offsetStep * offsetStep);
  if (q > prevStart) return q;
  // A page covering under 15 min: ask from the last train's own minute (overlap, no gap).
  final exact = _cap(m);
  return exact > prevStart ? exact : null;
}

/// Darwin's offsets for later pages are 1..119.
int _cap(int v) => v > maxOffset ? maxOffset : (v < 1 ? 1 : v);
