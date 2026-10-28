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
# The game logs "[LoneWolf] ui <name> <x> <y>" (screen pixels) for the controls this test
# presses; ui_pos <name> <fallback x> <fallback y> prints the logged position or the fallback.
ui_pos() {
  local line
  line=$(adb logcat -d -s godot:I 2>/dev/null | grep -o "\[LoneWolf\] ui $1 [0-9]* [0-9]*" | tail -1)
  if [ -n "$line" ]; then echo "$line" | awk '{print $4, $5}'; else echo "$2 $3"; fi
}
wait_mark() { # wait_mark <text> <seconds>
  local i
  for ((i = 0; i < $2; i += 2)); do has_mark "$1" && { log "marker '$1' after ${i}s"; return 0; }; sleep 2; done
  log "marker '$1' NOT seen after $2s"; return 1
}

# The slow software emulator makes system apps (launcher, Play services) stall; their "isn't
# responding" dialogs would cover the game and swallow the taps. Hide such dialogs.
adb shell settings put global hide_error_dialogs 1
close_dialogs() { adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1; }
close_dialogs
# A normal install (not an incremental one, which streams the APK lazily).
adb install --no-incremental -r -g "$APK" || { log "INSTALL FAILED"; exit 1; }
adb shell settings put system screen_off_timeout 1800000
adb shell svc power stayon true
# The emulator renders in software (SwiftShader): at the pixel_6's 2400x1080 the game runs at
# 1-2 FPS and a 10 s prep takes minutes. A 1280x720 display cuts the pixels about 3x.
adb shell wm size 720x1280
adb shell wm density 280
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
# START: bottom-right anchored, spans VW-342..VW-12 x 630..708 => centre (VW-177, 669).
read -r SX SY < <(ui_pos start "$(px "($VW-177)*$S")" "$(px "669*$S")")
log "tap START at $SX,$SY"
# Software rendering makes frames slow; tap again if the match did not begin loading.
focus() { adb shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | tr -s ' '; }
for try in 1 2 3; do
  # Bring the game back to the front if something else holds the focus.
  focus | grep -q "$PKG" || { log "focus elsewhere:$(focus)"; close_dialogs
    adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; sleep 5; }
  adb shell input tap "$SX" "$SY"
  wait_mark "prep started" 60 && break
  log "START tap $try not taken; focus:$(focus); display: $(adb shell wm size | tr '\n' ' ')"
done
shot 02_countdown
# Game time runs slower than real time at a few FPS (physics catches up 6 steps per frame).
wait_mark "match started" 420
sleep 2
shot 03_fight_start
# Hold FIRE (right fire button), then push the joystick forward, then drag to look.
read -r FX FY < <(ui_pos fire "$(px "0.845*$VW*$S")" "$(px "0.63*720*$S")")
log "hold FIRE at $FX,$FY"
adb shell input swipe "$FX" "$FY" "$FX" "$FY" 3000
shot 04_after_fire
read -r JX JY < <(ui_pos joystick "$(px "0.15*$VW*$S")" "$(px "0.71*720*$S")")
JY2=$(( JY - $(px "0.16*720*$S") ))
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
log "script errors:"; grep -E "SCRIPT ERROR|Parse Error|Invalid call|Invalid access" "$OUT/logcat.txt" | head -40 || true
grep -iE " godot " "$OUT/logcat.txt" | grep -iE "error|script|OpenGL API" | head -200 > "$OUT/godot_errors.txt" || true
log "markers:"; cat "$OUT/markers.txt"
log "crash lines: $(wc -l < "$OUT/crashes.txt")  godot error lines: $(wc -l < "$OUT/godot_errors.txt")"
status=0
for m in "lobby ready" "match started" "player fired" "player moved" "signature ok"; do
  grep -q "\] $m" "$OUT/markers.txt" || { log "MISSING marker: $m"; status=3; }
done
if [ "$(alive)" != "yes" ]; then log "GAME NOT RUNNING AT END"; status=2; fi
exit $status
