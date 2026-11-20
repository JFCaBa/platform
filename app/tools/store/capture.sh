#!/bin/bash
# watch the test log; screenshot on each SCENE marker
LOG=$1; OUT=$(mkdir -p "$2" && cd "$2" && pwd); U=$3  # test log, output dir, simulator UDID
FIFO=$(mktemp -u); mkfifo "$FIFO"
tail -n +1 -F "$LOG" > "$FIFO" 2>/dev/null & TP=$!; disown $TP  # our own tail: record.sh may watch the same log
trap 'kill $TP 2>/dev/null; rm -f "$FIFO"' EXIT
while read -r line; do
  case "$line" in
    *"SCENE "*) n=${line##*SCENE }; n=${n%%[^a-z]*}; sleep 1.2; if xcrun simctl io $U screenshot "$OUT/$n.png" >/dev/null 2>&1; then echo "shot $n"; else echo "FAILED $n"; fi;;
    *"All tests passed"*|*"Some tests failed"*|*"tests failed"*) echo "end: $line"; exit 0;;
  esac
done < "$FIFO"
