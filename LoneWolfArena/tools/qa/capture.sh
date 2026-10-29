#!/usr/bin/env bash
# Plays the scripted screenshot walkthrough (lobby -> menus -> match -> results) in a virtual
# display with software OpenGL and writes PNGs + the run log.
# Usage: tools/qa/capture.sh <out_dir> [WIDTHxHEIGHT] [autotest-mode]
#   e.g. tools/qa/capture.sh /tmp/shots 1560x720 screens
set -u
OUT="${1:?out dir}"; RES="${2:-1560x720}"; MODE="${3:-screens}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$OUT"
# Godot's user data (logs, anything a run writes to user://) goes to a scratch folder: the
# checks never touch the player's own data and parallel runs share nothing (Linux).
export XDG_DATA_HOME="$(mktemp -d)"
W="${RES%x*}"; H="${RES#*x}"
xvfb-run -a -s "-screen 0 $((W + 40))x$((H + 40))x24" \
  godot --path "$HERE" --rendering-driver opengl3 --resolution "$RES" -- --autotest="$MODE" --shots="$OUT" \
  > "$OUT/run.log" 2>&1
status=$?
# Audio device errors are expected in the headless container (no sound card).
grep -E "SCRIPT ERROR|ERROR:" "$OUT/run.log" | grep -v "Returning: ERR_CANT_OPEN" > "$OUT/errors.txt" || true
echo "capture exit=$status pngs=$(ls "$OUT"/*.png 2>/dev/null | wc -l) error_lines=$(wc -l < "$OUT/errors.txt")"
exit $status
