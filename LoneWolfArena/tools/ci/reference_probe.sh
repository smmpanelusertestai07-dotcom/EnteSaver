#!/usr/bin/env bash
# Private reference probe, run only by hand (the "reference" job of
# .github/workflows/lonewolf-arena.yml): installs an Android app the job fetched, launches it on
# the emulator and records screenshots and its log for private analysis. The job encrypts the
# results with a public key given when it is started, so the run publishes nothing of the probed
# app. Nothing here is part of the game.
# With nav minutes > 0 it hands the screen to reference_nav.py (reads the screen, taps through,
# plays a practice session, makes a video) instead of only taking pictures. state_dir keeps the
# app's downloaded game data between runs (big files only, no account files), so a later run
# continues without downloading it again.
#   reference_probe.sh <package> <app_dir> <out_dir> [minutes] [nav_minutes] [state_dir]
set -uo pipefail
PKG="$1"
APP_DIR="$2"
OUT="$3"
MINUTES="${4:-12}"
NAV_MINUTES="${5:-0}"
STATE="${6:-}"
mkdir -p "$OUT"
log() { echo "[probe] $*" | tee -a "$OUT/probe.txt"; }

adb wait-for-device
log "abi list: $(adb shell getprop ro.product.cpu.abilist | tr -d '\r')"
log "android sdk: $(adb shell getprop ro.build.version.sdk | tr -d '\r')"
# Split APKs (unpacked from an .xapk) install together; expansion files go to Android/obb.
mapfile -t APKS < <(find "$APP_DIR" -maxdepth 2 -name "*.apk" | sort)
log "apks: ${APKS[*]##*/}"
if [ "${#APKS[@]}" -eq 0 ]; then
  log "nothing to install"
  exit 0
elif [ "${#APKS[@]}" -gt 1 ]; then
  timeout 900 adb install-multiple -r -g "${APKS[@]}" 2>&1 | tail -3 | tee -a "$OUT/probe.txt"
else
  timeout 900 adb install -r -g "${APKS[0]}" 2>&1 | tail -3 | tee -a "$OUT/probe.txt"
fi
if [ -d "$APP_DIR/Android/obb/$PKG" ]; then
  adb shell mkdir -p "/sdcard/Android/obb/$PKG"
  for f in "$APP_DIR/Android/obb/$PKG"/*; do
    timeout 900 adb push "$f" "/sdcard/Android/obb/$PKG/" 2>&1 | tail -1 | tee -a "$OUT/probe.txt"
  done
fi
installed=""
for t in 1 2 3 4 5 6; do
  adb shell pm path "$PKG" 2>/dev/null | tr -d '\r' | grep -q "^package:" && { installed=1; break; }
  sleep 5
done
if [ -z "$installed" ]; then
  log "not installed: $(adb shell pm list packages 2>&1 | tr -d '\r' | grep -i -m3 "${PKG##*.}" | tr '\n' ' ')"
  exit 0
fi
if [ -n "$STATE" ] && [ -d "$STATE/$PKG" ]; then
  adb shell mkdir -p /sdcard/Android/data
  timeout 1200 adb push "$STATE/$PKG" /sdcard/Android/data/ 2>&1 | tail -1 | tee -a "$OUT/probe.txt"
  log "game data from the last run restored ($(du -sh "$STATE/$PKG" | cut -f1))"
fi
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
log "launched"
if [ "$NAV_MINUTES" -gt 0 ]; then
  python3 "$(dirname "$0")/reference_nav.py" "$OUT" "$NAV_MINUTES" "$PKG"
  log "navigation done: $(grep -c "tap " "$OUT/nav.txt" 2>/dev/null) taps"
else
  for ((i = 0; i < MINUTES * 3; i++)); do
    sleep 20
    adb exec-out screencap -p > "$OUT/s$(printf %03d "$i").png" 2>/dev/null
    log "t=$(((i + 1) * 20))s pid=$(adb shell pidof "$PKG" | tr -d '\r') $(adb shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | tr -s ' ')"
  done
fi
adb logcat -d > "$OUT/logcat.txt" 2>/dev/null
if [ -n "$STATE" ]; then
  # Keep the downloaded game data for the next run: big files only, nothing that looks like an
  # account, login or settings file.
  rm -rf "${STATE:?}/$PKG"
  mkdir -p "$STATE"
  timeout 1800 adb pull "/sdcard/Android/data/$PKG" "$STATE/" > /dev/null 2>&1
  find "$STATE" -type f \( -size -100k -o -iname '*token*' -o -iname '*account*' -o -iname '*guest*' -o -iname '*session*' \
    -o -iname '*login*' -o -iname '*pref*' -o -iname '*.db' -o -iname '*.xml' -o -iname '*.json' \) -delete 2>/dev/null
  log "game data kept for the next run: $(du -sh "$STATE" 2>/dev/null | cut -f1)"
fi
exit 0
