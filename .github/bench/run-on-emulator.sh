#!/usr/bin/env bash
# One shard of the savings benchmark, inside a booted emulator: fill the
# gallery with the shard's library, run SavingsBenchTest over it, pull the
# results and the copies it kept for grading (quality.py). Called by
# .github/workflows/savings-bench.yml with the shard number.
set -uo pipefail
SHARD=${1:?usage: run-on-emulator.sh <shard>}
LIB=bench-library
OUT=bench-out
KEEP=bench-keep
PKG=app.entesaver
mkdir -p "$OUT" "$KEEP"

adb wait-for-device
adb shell settings put global hide_error_dialogs 1
adb install -r -g app-debug.apk
adb install -r -g app-debug-androidTest.apk

# Files in a folder with a .nomedia (WhatsApp's Sent) are on the phone but
# in no gallery; the library says how many the gallery should list.
expected=$(cat "$LIB-in-gallery.txt")
echo "::group::Fill the gallery ($(find "$LIB" -type f ! -name .nomedia | wc -l) videos, $expected in the gallery)"
# One push per top folder: a push into a folder that already exists merges
# into it, so DCIM/Camera lands beside whatever DCIM the image has.
for top in "$LIB"/*; do
  if adb push "$top" /sdcard/ > /dev/null; then continue; fi
  if [ "$(basename "$top")" != Android ]; then echo "::error::Could not push $top"; exit 1; fi
  # An image that will not let the shell write under another app's
  # Android/media gets the folders those apps used before Android 11 -
  # where phones upgraded from Android 10 still have them.
  echo "::warning::Android/media is not writable here; using the apps' pre-Android 11 folders."
  for pair in "com.whatsapp/WhatsApp:WhatsApp" "org.telegram.messenger/Telegram:Telegram"; do
    src="$top/media/${pair%%:*}"
    [ -d "$src" ] || continue
    adb push "$src" "/sdcard/" > /dev/null || { echo "::error::Could not push $src"; exit 1; }
  done
done
adb shell df -h /data | tail -1
echo "::endgroup::"

listed() {
  adb shell content query --uri content://media/external/video/media --projection _id 2> /dev/null \
    | grep -c '^Row:'
}

wait_for_index() {
  local tries=$1 n=0
  for _ in $(seq 1 "$tries"); do
    n=$(listed)
    [ "$n" -ge "$expected" ] && break
    sleep 10
  done
  echo "$n"
}

echo "::group::Index the gallery"
adb shell content call --method scan_volume --uri content://media --arg external_primary > /dev/null 2>&1 || true
n=$(wait_for_index 18)
if [ "$n" -lt "$expected" ]; then
  # A full rescan happens whenever storage is mounted, so a reboot finishes
  # whatever the on-demand scan did not get to.
  echo "MediaStore lists $n of $expected after the scan; rebooting to index the rest."
  adb reboot
  adb wait-for-device
  until [ "$(adb shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = "1" ]; do sleep 5; done
  n=$(wait_for_index 30)
fi
echo "MediaStore lists $n of $expected videos"
echo "::endgroup::"

# The files whose copies are kept for grading, one name per line, handed
# over as base64url: names with spaces and brackets reach the test as they
# are, through every shell on the way.
keep=()
if [ -s "$LIB-keep.txt" ]; then
  keep=(-e keep "$(base64 -w0 < "$LIB-keep.txt" | tr '+/' '-_' | tr -d '=')")
  echo "Keeping the copies of $(wc -l < "$LIB-keep.txt") videos for grading"
fi

echo "::group::Run the benchmark"
adb logcat -c || true
# Bounded below the job's own limit: the results are written line by line,
# so a run that is cut short still leaves everything it measured to pull,
# and the grading after it still has time.
timeout 7200 adb shell am instrument -w -r \
  -e class app.entesaver.SavingsBenchTest \
  -e savingsBench true \
  -e expected "$expected" \
  ${keep[@]+"${keep[@]}"} \
  "$PKG.test/androidx.test.runner.AndroidJUnitRunner" | tee "$OUT/instrument-shard$SHARD.txt"
echo "::endgroup::"

adb exec-out run-as "$PKG" cat files/savings/savings.csv > "$OUT/savings-shard$SHARD.csv"
adb exec-out run-as "$PKG" cat files/savings/device.txt > "$OUT/device-shard$SHARD.txt"
adb logcat -d > "$OUT/logcat-shard$SHARD.txt" 2> /dev/null || true

# The kept copies, out of the app's private files the same way (the debug
# build lets run-as read them; no root). The test names them in characters
# that need no quoting.
echo "::group::Pull the copies kept for grading"
for f in $(adb exec-out run-as "$PKG" ls files/savings/keep 2> /dev/null | tr -d '\r'); do
  adb exec-out run-as "$PKG" cat "files/savings/keep/$f" > "$KEEP/$f" || echo "::warning::Could not pull $f"
done
ls -l "$KEEP"
echo "::endgroup::"

lines=$(($(wc -l < "$OUT/savings-shard$SHARD.csv") - 1))
echo "Measured $lines of $expected videos; pulled $(find "$KEEP" -type f | wc -l) copies for grading"
cat "$OUT/device-shard$SHARD.txt"
[ "$lines" -ge 1 ] || { echo "::error::The benchmark wrote no results"; exit 1; }
