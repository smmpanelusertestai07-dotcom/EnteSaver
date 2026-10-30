#!/usr/bin/env bash
# Private reference probe, run only by hand (the "reference" job of
# .github/workflows/lonewolf-arena.yml): installs an Android app the job fetched, launches it on
# the emulator and records screenshots and its log for private analysis. The job encrypts the
# results with a public key given when it is started, so the run publishes nothing of the probed
# app. Nothing here is part of the game.
#   reference_probe.sh <package> <app_dir> <out_dir> [minutes]
set -uo pipefail
PKG="$1"
APP_DIR="$2"
OUT="$3"
MINUTES="${4:-12}"
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
if ! adb shell pm list packages | tr -d '\r' | grep -qx "package:$PKG"; then
  log "not installed"
  exit 0
fi
adb logcat -c
adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
log "launched"
for ((i = 0; i < MINUTES * 3; i++)); do
  sleep 20
  adb exec-out screencap -p > "$OUT/s$(printf %03d "$i").png" 2>/dev/null
  log "t=$(((i + 1) * 20))s pid=$(adb shell pidof "$PKG" | tr -d '\r') $(adb shell dumpsys window 2>/dev/null | grep -m1 mCurrentFocus | tr -s ' ')"
done
adb logcat -d > "$OUT/logcat.txt" 2>/dev/null
exit 0
