#!/usr/bin/env bash
# Usage: run.sh <sim-udid> <scenario> <outdir> [extra launch args...]
# Launches SlopLab with -SGAutotest <scenario>, screenshots every "SNAP name" line, stops on DONE.
set -uo pipefail
UDID="$1"; SCENARIO="$2"; OUT="$3"; shift 3
mkdir -p "$OUT"
xcrun simctl terminate "$UDID" com.slopgram.lab >/dev/null 2>&1 || true
DATA=$(xcrun simctl get_app_container "$UDID" com.slopgram.lab data)
LOG="$DATA/Documents/sglog.txt"
rm -f "$LOG" "$DATA"/Documents/inapp-*.png
xcrun simctl launch "$UDID" com.slopgram.lab -SGAutotest "$SCENARIO" "$@" >/dev/null
# Wait for the fresh log
for i in $(seq 1 600); do grep -q SCENARIO "$LOG" 2>/dev/null && break; sleep 0.2; done
seen=0
deadline=$((SECONDS + ${TIMEOUT:-400}))
while [ $SECONDS -lt $deadline ]; do
    total=$(cat "$LOG" 2>/dev/null | wc -l)
    if [ "$total" -gt "$seen" ]; then
        sed -n "$((seen + 1)),${total}p" "$LOG" | while IFS= read -r line; do
            echo "$line"
            case "$line" in
                *" SNAP "*) [ -n "${SHOTS:-}" ] && name="${line##* SNAP }" && xcrun simctl io "$UDID" screenshot "$OUT/$SCENARIO-$name.png" >/dev/null 2>&1 ;;
            esac
        done
        seen=$total
        grep -q " DONE" "$LOG" && break
    fi
    sleep 0.1
done
cp "$LOG" "$OUT/$SCENARIO.log"
for f in "$DATA"/Documents/inapp-*.png; do [ -f "$f" ] && mv "$f" "$OUT/$SCENARIO-$(basename "$f")"; done
