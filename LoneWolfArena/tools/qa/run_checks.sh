#!/usr/bin/env bash
# Every automated check of Lone Wolf Arena, the same set CI runs. Run from anywhere:
#   tools/qa/run_checks.sh            all checks (a few minutes)
#   tools/qa/run_checks.sh quick      import, compile check and unit tests only
# Checks (each fails the run on its own):
#   textures               the 3D textures keep their phone import settings (texture_import.py)
#   tests/check.tscn       every script compiles with the autoloads present
#   warnings               the same load with the debugger on (-d) reports no GDScript warning
#   tests/run_tests.tscn   unit tests: damage/TTK, spread, weapon state, HUD layout, guard,
#                          signer list parsing, settings clamping, results honours
#   --autotest=sim         a full headless match (scripted player vs bot) ends with results
#   --autotest=aim         aim assist: pull, head stop, tracking with vs without, red crosshair
#   tests/anim_check.gd    every clip merged, toe fix, swap timing, flinch limit, grenade release
#   tests/bot_check.gd     grenade arc accuracy, the bot survives the closing zone
#   tests/flow_soak.gd     several matches in one process: no leaks, corpses stay on the floor
#   tests/guard_check.gd   a detection made before a match voids it
#   tests/lan_check.gd     Wi-Fi 1 vs 1 with two copies of the game: find, challenge, accept,
#                          play, a lethal hit and the result on both
#   tests/cloud_check.gd   the same over the internet transport, against tests/realtime_mock.gd
# Screenshots and the APK have their own tools: tools/qa/capture.sh, tools/build_apk.sh.
set -uo pipefail
cd "$(dirname "$0")/../.."
LOGS="$(mktemp -d)"
# Godot's user data (logs, anything a run writes to user://) goes to a scratch folder: the
# checks never touch the player's own data and parallel runs share nothing (Linux).
export XDG_DATA_HOME="$LOGS/userdata"
fail=0
step() { # step <name> <command...>
  local name="$1"; shift
  if "$@" > "$LOGS/$name.log" 2>&1; then
    echo "ok    $name"
  else
    echo "FAIL  $name (log: $LOGS/$name.log)"
    tail -20 "$LOGS/$name.log"
    fail=1
  fi
}
step textures python3 tools/qa/texture_import.py --check
# A fresh checkout's first import can exit non-zero before the class cache exists; retry once.
step import bash -c 'godot --headless --path . --import || godot --headless --path . --import'
step compile godot --headless --path . res://tests/check.tscn
# GDScript reports warnings (shadowed names, unused variables, int-to-enum) only to a debugger.
step warnings bash -c 'out="$(godot --headless -d --path . res://tests/check.tscn </dev/null 2>&1)"
  code=$?; printf "%s\n" "$out"; [ $code -eq 0 ] && ! grep -q "GDScript::reload" <<<"$out"'
step unit godot --headless --path . res://tests/run_tests.tscn
if [ "${1:-}" != "quick" ]; then
  step sim godot --headless --path . -- --autotest=sim
  step aim godot --headless --path . -- --autotest=aim
  step anim godot --headless --path . -- --autotest=script:res://tests/anim_check.gd
  step bot godot --headless --path . -- --autotest=script:res://tests/bot_check.gd
  step soak env LW_ROUNDS=4 godot --headless --path . -- --autotest=script:res://tests/flow_soak.gd
  step guard godot --headless --path . -- --autotest=script:res://tests/guard_check.gd
  step lan bash -c 'LW_LAN_ROLE=host timeout 150 godot --headless --path . -- --autotest=script:res://tests/lan_check.gd > "$0" 2>&1 &
    h=$!; LW_LAN_ROLE=guest timeout 150 godot --headless --path . -- --autotest=script:res://tests/lan_check.gd; g=$?
    wait $h; r=$?; echo "--- host:"; cat "$0"; [ $g -eq 0 ] && [ $r -eq 0 ]' "$LOGS/lan_host.txt"
  step cloud bash -c 'timeout 200 godot --headless -s res://tests/realtime_mock.gd -- 47810 > /dev/null 2>&1 & m=$!
    sleep 2; export LW_ONLINE_URL=ws://127.0.0.1:47810/realtime/v1/websocket
    LW_LAN_ROLE=host timeout 150 godot --headless --path . -- --autotest=script:res://tests/cloud_check.gd > "$0" 2>&1 &
    h=$!; LW_LAN_ROLE=guest timeout 150 godot --headless --path . -- --autotest=script:res://tests/cloud_check.gd; g=$?
    wait $h; r=$?; kill $m 2>/dev/null; echo "--- host:"; cat "$0"; [ $g -eq 0 ] && [ $r -eq 0 ]' "$LOGS/cloud_host.txt"
fi
# A script error anywhere fails the run even when the check itself exited 0.
if grep -l "SCRIPT ERROR" "$LOGS"/*.log >/dev/null 2>&1; then
  echo "FAIL  script errors in: $(grep -l "SCRIPT ERROR" "$LOGS"/*.log | tr '\n' ' ')"
  fail=1
fi
echo "logs: $LOGS"
exit $fail
