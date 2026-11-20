#!/bin/bash
# start recording when the test starts; log scene offsets; stop at the end
LOG=$1; OUT=$(mkdir -p "$2" && cd "$2" && pwd); U=$3  # test log, output dir, simulator UDID
FIFO=$(mktemp -u); mkfifo "$FIFO"
tail -n +1 -F "$LOG" > "$FIFO" 2>/dev/null & TP=$!; disown $TP  # our own tail: capture.sh may watch the same log
PID=
stop() { if [ -n "$PID" ]; then kill -INT $PID 2>/dev/null; wait $PID 2>/dev/null; PID=; fi; }
trap 'stop; kill $TP 2>/dev/null; rm -f "$FIFO"' EXIT
while read -r line; do
  case "$line" in
    *"store screens"*) if [ -z "$PID" ]; then : > "$OUT/scenes.txt"; xcrun simctl io $U recordVideo --codec h264 --force "$OUT/rec.mov" >/dev/null 2>&1 & PID=$!; sleep 1; kill -0 $PID 2>/dev/null || { echo "recordVideo failed"; PID=; exit 1; }; T0=$(python3 -c 'import time;print(time.time())'); echo "rec $PID"; fi;;
    *"SCENE "*) n=${line##*SCENE }; n=${n%%[^a-z]*}; python3 -c "import time;print('$n', round(time.time()-$T0,2))" >> "$OUT/scenes.txt";;
    *"All tests passed"*|*"tests failed"*) sleep 0.5; stop; echo "end"; exit 0;;
  esac
done < "$FIFO"
