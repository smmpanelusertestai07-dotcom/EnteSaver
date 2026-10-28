#!/usr/bin/env bash
# Runs N full headless match simulations back to back and fails on any script error,
# a match that does not finish, or a crash. Usage: tools/qa/soak.sh [N] [log_dir]
set -u
N="${1:-5}"; LOG="${2:-/tmp/lonewolf-soak}"
HERE="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$LOG"
fail=0
for i in $(seq 1 "$N"); do
  godot --headless --path "$HERE" -- --autotest=sim > "$LOG/sim_$i.log" 2>&1
  rc=$?
  errs=$(grep -c "SCRIPT ERROR" "$LOG/sim_$i.log")
  res=$(grep -o "SIM RESULT.*" "$LOG/sim_$i.log" | head -1)
  win=$(grep -o "winner=[a-z]*" "$LOG/sim_$i.log" | head -1)
  echo "run $i: exit=$rc script_errors=$errs $win $res"
  if [ "$rc" -ne 0 ] || [ "$errs" -ne 0 ]; then fail=1; fi
done
exit $fail
