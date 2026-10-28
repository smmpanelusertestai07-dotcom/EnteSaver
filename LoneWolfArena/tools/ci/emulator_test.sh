#!/usr/bin/env bash
# Installs the APK on a running Android emulator, launches the game, presses START,
# plays a few seconds (hold FIRE, move, look) and collects screenshots + logcat.
# The game logs one-time "[LoneWolf] ..." markers, which are checked at the end.
# Usage: emulator_test.sh <apk> <out_dir>
set -u
APK="$1"; OUT="$2"; PKG=com.lonewolf.arena
mkdir -p "$OUT"
log() { echo "[emu-test] $*"; }
alive() { adb shell pidof "$PKG" >/dev/null 2>&1 && echo yes || echo no; }
shot() { adb exec-out screencap -p > "$OUT/$1.png"; log "screenshot $1 alive=$(alive)"; }
has_mark() { adb logcat -d -s godot:I 2>/dev/null | grep -q "\[LoneWolf\] $1"; }
wait_mark() { # wait_mark <text> <seconds>
  local i
  for ((i = 0; i < $2; i += 2)); do has_mark "$1" && { log "marker '$1' after ${i}s"; return 0; }; sleep 2; done
  log "marker '$1' NOT seen after $2s"; return 1
}

adb install -r -g "$APK" || { log "INSTALL FAILED"; exit 1; }
adb shell settings put system screen_off_timeout 1800000
adb shell svc power stayon true
# Skip the one-time "Viewing full screen" immersive-mode hint, which covers the game.
adb shell settings put secure immersive_mode_confirmations confirmed
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
wait_mark "lobby ready" 120
sleep 8
shot 01_lobby
read -r W H < <(python3 -c "import struct;d=open('$OUT/01_lobby.png','rb').read(24);print(*struct.unpack('>II',d[16:24]))")
log "screen ${W}x${H}"
# Godot stretch: the virtual canvas is 720 px tall and its width expands to the aspect ratio.
S=$(python3 -c "print($H/720.0)")
VW=$(python3 -c "print($W/($H/720.0))")
px() { python3 -c "print(int(round($1)))"; }
# START: bottom-right anchored, 400x92 at offset (-420,-112) => centre (VW-220, 654).
SX=$(px "($VW-220)*$S"); SY=$(px "654*$S")
log "tap START at $SX,$SY"
adb shell input tap "$SX" "$SY"
sleep 6
shot 02_countdown
wait_mark "match started" 120
sleep 2
shot 03_fight_start
# Hold FIRE (right fire button), then push the joystick forward, then drag to look.
FX=$(px "0.845*$VW*$S"); FY=$(px "0.63*720*$S")
adb shell input swipe "$FX" "$FY" "$FX" "$FY" 3000
shot 04_after_fire
JX=$(px "0.15*$VW*$S"); JY=$(px "0.71*720*$S"); JY2=$(px "0.55*720*$S")
adb shell input swipe "$JX" "$JY" "$JX" "$JY2" 3000
shot 05_after_move
LX=$(px "0.62*$VW*$S"); LY=$(px "0.4*720*$S"); LX2=$(px "0.74*$VW*$S")
adb shell input swipe "$LX" "$LY" "$LX2" "$LY" 700
sleep 2
shot 06_look
sleep 25
shot 07_later
log "alive after test=$(alive)"
adb logcat -d > "$OUT/logcat.txt"
grep -o "\[LoneWolf\].*" "$OUT/logcat.txt" > "$OUT/markers.txt" || true
grep -E "FATAL EXCEPTION|SIGSEGV|SIGABRT|Abort message" "$OUT/logcat.txt" > "$OUT/crashes.txt" || true
grep -iE " godot " "$OUT/logcat.txt" | grep -iE "error|script|OpenGL API" | head -200 > "$OUT/godot_errors.txt" || true
log "markers:"; cat "$OUT/markers.txt"
log "crash lines: $(wc -l < "$OUT/crashes.txt")  godot error lines: $(wc -l < "$OUT/godot_errors.txt")"
status=0
for m in "lobby ready" "match started" "player fired" "player moved" "signature ok"; do
  grep -q "\] $m" "$OUT/markers.txt" || { log "MISSING marker: $m"; status=3; }
done
if [ "$(alive)" != "yes" ]; then log "GAME NOT RUNNING AT END"; status=2; fi
exit $status
