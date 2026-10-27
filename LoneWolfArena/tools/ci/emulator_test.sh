#!/usr/bin/env bash
# Installs the APK on a running Android emulator, launches the game, presses START,
# plays a few seconds (hold FIRE, move, look) and collects screenshots + logcat.
# Usage: emulator_test.sh <apk> <out_dir>
set -u
APK="$1"; OUT="$2"; PKG=com.lonewolf.arena
mkdir -p "$OUT"
log() { echo "[emu-test] $*"; }
shot() { adb exec-out screencap -p > "$OUT/$1.png"; log "screenshot $1 alive=$(alive)"; }
alive() { adb shell pidof "$PKG" >/dev/null 2>&1 && echo yes || echo no; }

adb install -r -g "$APK" || { log "INSTALL FAILED"; exit 1; }
adb shell settings put system screen_off_timeout 1800000
adb shell svc power stayon true
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 35
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
sleep 15
shot 02_countdown
sleep 8
shot 03_fight_start
# Hold FIRE (right fire button), then push the joystick forward, then drag to look.
FX=$(px "0.845*$VW*$S"); FY=$(px "0.63*720*$S")
adb shell input swipe "$FX" "$FY" "$FX" "$FY" 2500
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
grep -E "FATAL EXCEPTION|SIGSEGV|SIGABRT|Abort message" "$OUT/logcat.txt" > "$OUT/crashes.txt" || true
grep -iE "godot" "$OUT/logcat.txt" | grep -iE "error|script" | head -100 > "$OUT/godot_errors.txt" || true
log "crash lines: $(wc -l < "$OUT/crashes.txt")  godot error lines: $(wc -l < "$OUT/godot_errors.txt")"
if [ "$(alive)" != "yes" ]; then log "GAME NOT RUNNING AT END"; exit 2; fi
exit 0
