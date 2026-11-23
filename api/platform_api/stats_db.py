"""SQLite store of the usage aggregates (stats.py): per day, hour, station and app version.
Only counts: no IP, User-Agent, hash or device identifier is ever written here."""
from __future__ import annotations

import sqlite3
import threading
from pathlib import Path

from .stats import Delta

SCHEMA = """
CREATE TABLE IF NOT EXISTS days (day TEXT PRIMARY KEY, visitors INTEGER NOT NULL DEFAULT 0,
    requests INTEGER NOT NULL DEFAULT 0, follows INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS hours (day TEXT NOT NULL, hour INTEGER NOT NULL,
    requests INTEGER NOT NULL, PRIMARY KEY (day, hour));
CREATE TABLE IF NOT EXISTS stations (day TEXT NOT NULL, crs TEXT NOT NULL,
    requests INTEGER NOT NULL, PRIMARY KEY (day, crs));
CREATE TABLE IF NOT EXISTS versions (day TEXT NOT NULL, version TEXT NOT NULL,
    requests INTEGER NOT NULL, PRIMARY KEY (day, version));
"""


class StatsDB:
    def __init__(self, path: str | Path) -> None:
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(str(path), check_same_thread=False)
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.executescript(SCHEMA)
        self._base: dict[str, int] = {}

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def _base_for(self, day: str) -> int:
        """Visitors already stored for `day` the first time this store sees it (a restart's
        earlier count); frozen, so base + the live set never counts a flush twice."""
        if day not in self._base:
            row = self._conn.execute("SELECT visitors FROM days WHERE day = ?", (day,)).fetchone()
            self._base[day] = row[0] if row else 0
        return self._base[day]

    def visitors_base(self, day: str) -> int:
        with self._lock:
            return self._base_for(day)

    def apply(self, deltas: list[Delta]) -> None:
        with self._lock, self._conn:
            c = self._conn
            for d in deltas:
                visitors = self._base_for(d.day) + d.visitors
                c.execute("INSERT INTO days (day, visitors, requests, follows) VALUES (?, ?, ?, ?) "
                          "ON CONFLICT(day) DO UPDATE SET visitors = excluded.visitors, "
                          "requests = requests + excluded.requests, follows = follows + excluded.follows",
                          (d.day, visitors, d.requests, d.follows))
                for table, col, counts in (("hours", "hour", d.hours), ("stations", "crs", d.stations),
                                           ("versions", "version", d.versions)):
                    c.executemany(f"INSERT INTO {table} (day, {col}, requests) VALUES (?, ?, ?) "
                                  f"ON CONFLICT(day, {col}) DO UPDATE SET requests = requests + excluded.requests",
                                  [(d.day, k, n) for k, n in counts.items()])

    def _since(self, since: str | None) -> tuple[str, tuple]:
        return ("WHERE day >= ?", (since,)) if since else ("", ())

    def days(self, since: str | None) -> list[dict]:
        where, args = self._since(since)
        with self._lock:
            rows = self._conn.execute(f"SELECT day, visitors, requests, follows FROM days {where} ORDER BY day",
                                      args).fetchall()
        return [{"day": r[0], "visitors": r[1], "requests": r[2], "follows": r[3]} for r in rows]

    def top_stations(self, since: str | None, limit: int = 20) -> list[tuple[str, int]]:
        where, args = self._since(since)
        with self._lock:
            return [tuple(r) for r in self._conn.execute(
                f"SELECT crs, SUM(requests) AS n FROM stations {where} GROUP BY crs ORDER BY n DESC, crs LIMIT ?",
                args + (limit,))]

    def hours(self, since: str | None) -> dict[int, int]:
        where, args = self._since(since)
        with self._lock:
            return dict(self._conn.execute(f"SELECT hour, SUM(requests) FROM hours {where} GROUP BY hour", args))

    def versions(self, since: str | None) -> dict[str, int]:
        where, args = self._since(since)
        with self._lock:
            return dict(self._conn.execute(f"SELECT version, SUM(requests) FROM versions {where} GROUP BY version",
                                           args))

    def stations_count(self, day: str) -> int:
        with self._lock:
            return self._conn.execute("SELECT COUNT(*) FROM stations WHERE day = ?", (day,)).fetchone()[0]

    def backup(self, dest_dir: Path, day: str, keep: int = 7) -> None:
        dest_dir = Path(dest_dir)
        dest_dir.mkdir(parents=True, exist_ok=True)
        target = sqlite3.connect(str(dest_dir / f"stats-{day}.db"))
        try:
            with self._lock:
                self._conn.backup(target)
        finally:
            target.close()
        for old in sorted(dest_dir.glob("stats-*.db"))[:-keep]:
            old.unlink()
