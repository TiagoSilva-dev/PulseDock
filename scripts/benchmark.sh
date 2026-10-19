#!/bin/bash
# Reproducible resource benchmark for PulseDock.
#   scripts/benchmark.sh [debug|release] [seconds]
#
# 1. Builds the app and relaunches it (any running PulseDock is quit first).
# 2. Launch time: read from PulseDock's own "launched in N ms" log entry.
# 3. Idle CPU: samples `ps` once per second while nobody touches the dock.
# 4. Memory: physical footprint reported by `footprint` (the figure Activity Monitor uses).
# 5. Event pipeline: the 25-session load test (AgentCoreTests/LoadTests).
#
# Numbers depend on the machine; compare runs on the same Mac. Targets come from the
# product brief: idle CPU < 1 %, memory < ~180 MB, launch < ~1.5 s.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
SECONDS_TO_SAMPLE="${2:-30}"
cd "$ROOT"

scripts/build-app.sh "$CONFIG" >/dev/null
APP="$ROOT/build/$CONFIG/PulseDock.app"

pkill -f 'PulseDock.app/Contents/MacOS/PulseDock' 2>/dev/null || true
sleep 1
START="$(date '+%Y-%m-%d %H:%M:%S')"
open "$APP" --args --no-onboarding
for _ in $(seq 1 50); do
  PID="$(pgrep -f "$APP/Contents/MacOS/PulseDock" | head -1 || true)"
  [ -n "$PID" ] && break
  sleep 0.1
done
[ -n "${PID:-}" ] || { echo "PulseDock did not start" >&2; exit 1; }

sleep 3
LAUNCH="$(/usr/bin/log show --start "$START" --info --predicate 'subsystem == "app.pulsedock.PulseDock" AND eventMessage BEGINSWITH "launched in"' --style compact 2>/dev/null \
  | sed -nE 's/.*launched in ([0-9]+) ms.*/\1/p' | tail -1)"

echo "Settling for 10 s…"
sleep 10
echo "Sampling CPU for ${SECONDS_TO_SAMPLE} s (do not move the pointer over the dock)…"
SAMPLES=()
for _ in $(seq 1 "$SECONDS_TO_SAMPLE"); do
  SAMPLES+=("$(ps -o %cpu= -p "$PID" | tr -d ' ')")
  sleep 1
done
CPU_AVG="$(printf '%s\n' "${SAMPLES[@]}" | awk '{s+=$1} END {printf "%.2f", s/NR}')"
CPU_MAX="$(printf '%s\n' "${SAMPLES[@]}" | sort -n | tail -1)"
FOOTPRINT="$(/usr/bin/footprint -p "$PID" 2>/dev/null | sed -nE 's/^ *(phys_footprint|Footprint): *([0-9.]+ ?[KMG]B).*/\2/p' | head -1)"
[ -n "$FOOTPRINT" ] || FOOTPRINT="$(ps -o rss= -p "$PID" | awk '{printf "%.1f MB (RSS)", $1/1024}')"

PIPELINE="$(swift test --filter LoadTests 2>&1 | sed -nE 's/^\[benchmark\] (.*)$/\1/p' | tail -1)"

cat <<EOF

PulseDock benchmark — $(date '+%Y-%m-%d %H:%M') — $(sysctl -n machdep.cpu.brand_string), macOS $(sw_vers -productVersion), $CONFIG build
  Launch (app start → dock ready): ${LAUNCH:-n/a} ms
  Idle CPU over ${SECONDS_TO_SAMPLE} s:  avg ${CPU_AVG} %, max ${CPU_MAX} %
  Memory (physical footprint):  ${FOOTPRINT:-n/a}
  Event pipeline (debug test):  ${PIPELINE:-n/a}
EOF
