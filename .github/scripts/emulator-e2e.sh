#!/usr/bin/env bash
#
# Runs the instrumented suite on a booted emulator, collects the evidence
# (screenshots, logcat) whether it passes or fails, then installs the signed
# release APK and proves it launches without crashing.
#
# This lives in a file rather than in the workflow's `script:` block because
# android-emulator-runner executes that block one line at a time via `sh -c`:
# variables do not survive between lines and multi-line if/for blocks are a
# syntax error.

set -uo pipefail

# The application ID (package name) from app/build.gradle.kts, not the app's name.
PKG=app.entesaver
# The application ID Ente Saver had until 12.2: a different app to Android.
EARLIER_PKG=app.cloudsaver
SHOTS_ON_DEVICE=/sdcard/Pictures/CSTestShots
OUT=artifacts
mkdir -p "$OUT/screenshots"

adb wait-for-device
# Deterministic dates: EXIF carries no timezone, so MediaProvider resolves it
# in the device's zone. Pin it so capture times are reproducible.
adb shell "su root setprop persist.sys.timezone UTC" 2>/dev/null || true
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0
# The emulator's own apps can hang on a loaded runner, and Android then puts
# an "isn't responding" dialog over everything. That dialog takes window
# focus, so taps and back presses stop reaching the app under test and a
# whole leg goes red with Ente Saver untouched (run 373, API 35: the Pixel
# Launcher's dialog sat over nine tests). Hide those dialogs. The suite's
# own assertions, the crash buffer collected below and the process checks
# after the release install still report every failure that is the app's.
adb shell settings put global hide_error_dialogs 1
# The setting stops dialogs raised from now on; one already up stays up. The
# emulator can hang its own launcher while it boots, before this script runs
# (run 550, API 35: the runner's unlock key took 6.6 s instead of 0.1 s, and
# the launcher's dialog then sat over the whole suite). End the app such a
# dialog is about, as the setting does for later ones: Android takes an
# app's error dialogs down with its process. Nothing of Ente Saver's is
# installed yet, so whatever this finds is the emulator's own. The pause
# lets a dialog that was already on its way reach the screen first.
sleep 5
for proc in $(adb shell dumpsys window windows | tr -d '\r' \
    | grep -o -E 'Application (Not Responding|Error): [^} ]+' \
    | sed 's/^.*: //' | sort -u); do
  # The dialog names a process. Its package is that name, or the name with
  # a ":part" or ".part" taken off (com.google.android.gms.persistent).
  pkg=${proc%%:*}
  until [ -z "$pkg" ] || adb shell pm path "$pkg" > /dev/null 2>&1; do
    case "$pkg" in *.*) pkg=${pkg%.*} ;; *) pkg= ;; esac
  done
  if [ -n "$pkg" ]; then
    echo "::warning::Android was showing an error dialog about $proc before the suite started; closing $pkg."
    adb shell am force-stop "$pkg"
  else
    echo "::warning::Android was showing an error dialog about $proc before the suite started, and no installed package matches it."
  fi
done

echo "::group::Instrumented end-to-end tests"
tests_failed=0
./gradlew connectedDebugAndroidTest --no-daemon || tests_failed=1
echo "::endgroup::"

# Gradle prints only "There was N failure(s)" - the names live in the XML
# report, which used to mean downloading an artifact to learn what broke.
# Print them here so a red leg is diagnosable from the log alone.
if [ "$tests_failed" -ne 0 ]; then
  echo "::group::Which tests failed"
  python3 - <<'REPORT' || true
import glob, xml.etree.ElementTree as ET
for path in sorted(glob.glob(
        "app/build/outputs/androidTest-results/connected/**/*.xml",
        recursive=True)):
    for case in ET.parse(path).getroot().iter("testcase"):
        for bad in list(case.findall("failure")) + list(case.findall("error")):
            head = (bad.text or "").strip().splitlines()
            print("FAILED {}.{}".format(
                case.get("classname"), case.get("name")))
            for line in head[:6]:
                print("       " + line)
REPORT
  echo "::endgroup::"
fi

echo "::group::Collect screenshots and logs"
# The suite publishes PNGs through MediaStore because adb cannot read
# /sdcard/Android/data on Android 11+.
if adb pull "$SHOTS_ON_DEVICE" "$OUT/" ; then
  # adb creates artifacts/CSTestShots; flatten it into screenshots/.
  if [ -d "$OUT/CSTestShots" ]; then
    mv "$OUT/CSTestShots"/* "$OUT/screenshots/" 2>/dev/null || true
    rmdir "$OUT/CSTestShots" 2>/dev/null || true
  fi
fi
ls -la "$OUT/screenshots" || true
adb logcat -d > "$OUT/logcat.txt" 2>/dev/null || true
adb logcat -d -b crash > "$OUT/logcat-crash.txt" 2>/dev/null || true
# Which apps Android found hung during this leg, and why. The report's
# logcats cover only the time each test ran, and the emulator can hang an
# app of its own before the first one: this is where that shows.
grep -E 'ActivityManager: (ANR in |Reason: )' "$OUT/logcat.txt" | head -20 || true
echo "::endgroup::"

if [ "$tests_failed" -ne 0 ]; then
  echo "::error::Instrumented tests failed"
  tail -80 "$OUT/logcat-crash.txt" 2>/dev/null || true
  exit 1
fi

BT="$ANDROID_HOME/build-tools/$(ls "$ANDROID_HOME/build-tools" | sort -V | tail -1)"

# install_apk <log> <adb install arguments...>: true when the package manager
# says Success. Streamed, never incremental: on a busy emulator adb's
# incremental install hung for a minute and then both it and the streamed
# fallback broke off with "Failure calling service package: Broken pipe"
# before the package manager had said anything about the APK. A stream that
# breaks like that is tried once more, after the package service answers
# again; anything the package manager itself says stands.
install_apk() {
  local log=$1
  shift
  adb install --no-incremental "$@" > "$log" 2>&1
  if ! grep -q "^Success" "$log" && grep -qE "Broken pipe|Can't find service: package|device offline" "$log"; then
    echo "::warning::adb install broke off before the package manager answered; trying once more"
    adb wait-for-device
    for _ in $(seq 1 30); do
      adb shell pm path android > /dev/null 2>&1 && break
      sleep 2
    done
    adb install --no-incremental "$@" > "$log" 2>&1
  fi
  grep -q "^Success" "$log"
}

# The last published release: what every phone with Ente Saver updates from.
PREV_DIR=$(mktemp -d)
PREV=""
EARLIER=""
if gh release download --repo "$GITHUB_REPOSITORY" --pattern 'EnteSaver-v*-release.apk' --dir "$PREV_DIR" > /dev/null 2>&1; then
  PREV=$(ls "$PREV_DIR"/*.apk 2> /dev/null | head -1)
fi
if [ -z "$PREV" ]; then
  echo "::notice::No published release to update from."
else
  badging() { "$BT/aapt2" dump badging "$1" 2> /dev/null; }
  pkg_of() { badging "$1" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -1; }
  code_of() { badging "$1" | sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" | head -1; }
  PREV_PKG=$(pkg_of "$PREV")
  NEW_PKG=$(pkg_of EnteSaver-release.apk)
  PREV_CODE=$(code_of "$PREV")
  NEW_CODE=$(code_of EnteSaver-release.apk)
  if [ "$NEW_PKG" != "$PKG" ]; then
    echo "::error::This build's package is '$NEW_PKG', not $PKG"
    exit 1
  fi
  if [ "$PREV_PKG" != "$PKG" ]; then
    # Until the first release under this id, the last one is the earlier
    # app: a different app to Android, which this build installs next to.
    echo "::notice::The last release is the earlier app ($PREV_PKG); there is no update to check until a release of $PKG is published."
    EARLIER="$PREV"
    PREV=""
  elif [ -z "$PREV_CODE" ] || [ -z "$NEW_CODE" ] || [ "$PREV_CODE" -gt "$NEW_CODE" ]; then
    echo "::notice::The last release ($PREV_CODE) is newer than this build ($NEW_CODE); no update to check."
    PREV=""
  fi
  # A release built for a newer Android than this emulator's does not
  # install on it - every release before Android 9 support needs Android 10
  # - so no phone on this Android can have it to update from, or to sit
  # beside. The checks below are for the Androids that can.
  min_of() { badging "$1" | sed -n "s/^\(minSdkVersion\|sdkVersion\):'\([0-9]*\)'.*/\2/p" | head -1; }
  DEVICE_SDK=$(adb shell getprop ro.build.version.sdk | tr -d '\r')
  for apk in "$PREV" "$EARLIER"; do
    [ -n "$apk" ] || continue
    NEED=$(min_of "$apk")
    if [ -n "$NEED" ] && [ -n "$DEVICE_SDK" ] && [ "$DEVICE_SDK" -lt "$NEED" ]; then
      echo "::notice::$(basename "$apk") needs API $NEED and this emulator runs API $DEVICE_SDK; there is nothing to update from or install beside here."
      [ "$apk" = "$PREV" ] && PREV=""
      [ "$apk" = "$EARLIER" ] && EARLIER=""
    fi
  done
fi

# What the update does to the app, whichever key signs this build: the last
# release and this build, re-signed with one test key, installed one over
# the other the way a phone updates.
echo "::group::Update over the last published release: the app"
if [ -n "$PREV" ]; then
  TK=$(mktemp -d)
  export TEST_KEY_PASS
  TEST_KEY_PASS=$(openssl rand -hex 16)
  step() { "$@" || { echo "::error::Could not prepare the test-signed APKs: $1 failed"; exit 1; }; }
  step keytool -genkeypair -keystore "$TK/test.p12" -storetype PKCS12 -alias test \
    -keyalg RSA -keysize 2048 -validity 3650 -storepass "$TEST_KEY_PASS" -keypass "$TEST_KEY_PASS" \
    -dname "CN=Update check"
  for apk in prev:"$PREV" new:EnteSaver-release.apk; do
    SIGN_KS="$TK/test.p12" SIGN_KS_ALIAS=test KEYSTORE_PASSWORD="$TEST_KEY_PASS" KEY_PASSWORD="$TEST_KEY_PASS" \
      step bash .github/scripts/sign-apk.sh "${apk#*:}" "$TK/${apk%%:*}.apk"
  done
  adb uninstall "$PKG" > /dev/null 2>&1 || true
  if ! install_apk "$PREV_DIR/one.log" -g "$TK/prev.apk"; then
    echo "::error::The last published release did not install"
    cat "$PREV_DIR/one.log"
    exit 1
  fi
  # Opened once, so the update meets an app that has started.
  adb shell am start -n "$PKG/.MainActivity" > /dev/null 2>&1 || true
  sleep 8
  # As after Force stop or an OEM cleaner: the update then reaches an app
  # that no broadcast wakes, so the icon must not depend on any code running.
  adb shell am force-stop "$PKG" > /dev/null 2>&1 || true
  if ! install_apk "$PREV_DIR/two.log" -r -g "$TK/new.apk"; then
    echo "::error::This build does not install as an update over the last published release ($(basename "$PREV"))"
    cat "$PREV_DIR/two.log"
    exit 1
  fi
  # Exactly one home-screen entry after the update, the one launchers know.
  launchers=$(adb shell cmd package query-activities -a android.intent.action.MAIN \
    -c android.intent.category.LAUNCHER "$PKG" | tr -d '\r')
  count=$(printf '%s\n' "$launchers" | sed -n 's/^\([0-9][0-9]*\) activities found.*/\1/p' | head -1)
  entry=$(printf '%s\n' "$launchers" | sed -n 's/^ *name=\(.*\)$/\1/p' | head -1)
  if [ "${count:-0}" != 1 ] || [ "$entry" != "$PKG.MainActivity" ]; then
    echo "::error::After the update the app's home-screen entries are not exactly $PKG.MainActivity (${count:-no} found)"
    printf '%s\n' "$launchers" | head -20
    exit 1
  fi
  # The updated app, opened from that entry on the data the last release
  # left, starts and stays up.
  adb logcat -c || true
  adb shell am start -n "$PKG/.MainActivity" > /dev/null 2>&1 || true
  sleep 8
  if ! adb shell pidof "$PKG" > /dev/null 2>&1 || adb logcat -d -b crash | grep -q "$PKG"; then
    echo "::error::The update installed, but the updated app did not start cleanly"
    adb logcat -d -b crash | tail -80
    exit 1
  fi
  adb uninstall "$PKG" > /dev/null 2>&1 || true
  rm -rf "$TK"
  echo "This build updates $(basename "$PREV") and starts on its data."
fi
echo "::endgroup::"

# The update a phone really gets: the published release, then this build as
# signed. A release that cannot do this would leave uninstalling - and losing
# what the app knew - as the only way on, so it fails here rather than on
# someone's phone.
echo "::group::Update over the last published release: the signatures"
if [ "${THROWAWAY_KEY:-false}" = "true" ]; then
  echo "::notice::This build was signed with a throwaway key; it is never published, so its signature is not checked against the last release."
elif [ -n "$PREV" ]; then
  adb uninstall "$PKG" > /dev/null 2>&1 || true
  if ! install_apk "$PREV_DIR/three.log" -g "$PREV"; then
    echo "::error::The last published release did not install"
    cat "$PREV_DIR/three.log"
    exit 1
  fi
  if ! install_apk "$PREV_DIR/four.log" -r -g EnteSaver-release.apk; then
    echo "::error::This build's signature cannot update the last published release ($(basename "$PREV"))"
    cat "$PREV_DIR/four.log"
    exit 1
  fi
  echo "As signed, this build installs over $(basename "$PREV") as an update."
fi
echo "::endgroup::"

# The move from the earlier app: this build goes on next to it, both are
# there, and it starts cleanly with the earlier one installed.
echo "::group::Next to the earlier Ente Saver ($EARLIER_PKG)"
if [ -n "$EARLIER" ]; then
  adb uninstall "$PKG" > /dev/null 2>&1 || true
  adb uninstall "$EARLIER_PKG" > /dev/null 2>&1 || true
  if ! install_apk "$PREV_DIR/five.log" -g "$EARLIER"; then
    echo "::error::The earlier release did not install"
    cat "$PREV_DIR/five.log"
    exit 1
  fi
  if ! install_apk "$PREV_DIR/six.log" -g EnteSaver-release.apk; then
    echo "::error::This build does not install next to the earlier Ente Saver"
    cat "$PREV_DIR/six.log"
    exit 1
  fi
  adb logcat -c || true
  adb shell am start -n "$PKG/.MainActivity" > /dev/null 2>&1 || true
  sleep 8
  if ! adb shell pidof "$PKG" > /dev/null 2>&1 || adb logcat -d -b crash | grep -q "$PKG"; then
    echo "::error::With the earlier Ente Saver installed, this build did not start cleanly"
    adb logcat -d -b crash | tail -80
    exit 1
  fi
  adb uninstall "$PKG" > /dev/null 2>&1 || true
  adb uninstall "$EARLIER_PKG" > /dev/null 2>&1 || true
  echo "This build installs next to $(basename "$EARLIER") and starts cleanly beside it."
else
  echo "::notice::No earlier release to install next to."
fi
rm -rf "$PREV_DIR"
echo "::endgroup::"

echo "::group::Install the signed release APK and launch it"
adb uninstall "$PKG" 2>/dev/null || true
# -g grants the runtime permissions up front, so setup's media step offers
# "Next" instead of a system prompt the walk below cannot answer.
LIVE_LOG=$(mktemp)
if ! install_apk "$LIVE_LOG" -r -g EnteSaver-release.apk; then
  echo "::error::The signed release APK did not install"
  cat "$LIVE_LOG"
  exit 1
fi
rm -f "$LIVE_LOG"
adb logcat -c || true
adb shell am start -n "$PKG/.MainActivity"
sleep 12

# A crash would leave no process behind.
if ! adb shell pidof "$PKG" > /dev/null 2>&1; then
  echo "::error::The released APK is not running after launch"
  adb logcat -d -b crash | tail -80
  exit 1
fi
adb exec-out screencap -p > "$OUT/screenshots/40-release-apk-launched.png"

# Walk the four tabs in the RELEASE build. The instrumented suite runs
# against the debug APK, so nothing else ever opens a second screen with R8
# applied - and a missing keep rule shows up as a crash on the screen that
# needs the stripped class, not at launch. A fresh install opens on setup,
# which has no tab bar: the walk finishes setup by each button's label first
# and fails unless every tab really opens. It used to tap by screen fraction,
# landed on setup every time, and passed without drawing a single tab.
if ! python3 .github/scripts/release-tab-walk.py "$PKG" "$OUT/screenshots"; then
  echo "::error::The release build's tab walk failed"
  exit 1
fi

# The release APK's promises that only the installed package can show.
# No internet permission, ever: the whole privacy claim rests on it.
if adb shell dumpsys package "$PKG" | grep -q "android.permission.INTERNET"; then
  echo "::error::The released APK holds the INTERNET permission"
  exit 1
fi
# The icon pack is found by launchers through their own actions; a pack
# no launcher can see is a feature that silently is not there.
if ! adb shell cmd package query-activities -a org.adw.launcher.THEMES | grep -q "IconPackActivity"; then
  echo "::error::The icon pack is not discoverable by launchers"
  exit 1
fi
# Ente Saver's own screens open only from its icon, its alerts and its
# shortcuts. From outside - here the shell - Android must refuse them.
for cls in HostActivity OpenEnteActivity; do
  out=$(adb shell am start -W -n "$PKG/.$cls" 2>&1 || true)
  if echo "$out" | grep -q "Status: ok"; then
    echo "::error::$cls can be opened by other apps: $out"
    exit 1
  fi
done
sleep 3

if adb logcat -d -b crash | grep -q "$PKG"; then
  echo "::error::Crash reported for $PKG"
  adb logcat -d -b crash | tail -120
  exit 1
fi
echo "::endgroup::"
echo "Emulator end-to-end run finished clean."
