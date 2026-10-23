#!/usr/bin/env bash
# Runs every SlopLab scenario and prints one RESULT line each.
# Usage: run_all.sh <sim-udid> <outdir> [scenarios...]
cd "$(dirname "$0")"
UDID="$1"; OUT="$2"; shift 2
SCENARIOS="${*:-sideload leave dm feed refresh reels cold}"
for sc in $SCENARIOS; do
    if [ "$sc" == "cold" ]; then
        # Three launches in a row: 30 s, then 45 s, then 60 s
        reset="-SGResetColdStarts YES"
        for want in 30 45 60; do
            TIMEOUT=120 ./run.sh "$UDID" cold "$OUT" -SGTimeScale 1 -SGExpectCold $want -SGForceNight NO $reset >/dev/null 2>&1
            reset=""
            cp "$OUT/cold.log" "$OUT/cold-$want.log"
            for f in "$OUT"/cold-inapp-*.png; do [ -f "$f" ] && mv "$f" "$OUT/cold$want-$(basename "$f")"; done
            echo "=== cold $want: $(grep RESULT "$OUT/cold.log")"
        done
    else
        TIMEOUT=500 ./run.sh "$UDID" "$sc" "$OUT" -SGTimeScale 0.3 -SGSeed 5 -SGResetColdStarts YES -SGForceNight NO >/dev/null 2>&1
        echo "=== $sc: $(grep RESULT "$OUT/$sc.log")"
    fi
done
