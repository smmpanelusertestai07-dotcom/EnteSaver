#!/usr/bin/env bash
# Builds the signed release APK (arm64-v8a + armeabi-v7a) and checks it.
#
#   tools/build_apk.sh [preset] [out.apk]        preset defaults to "Android"
#
# Signing key: LW_KEYSTORE / LW_KEY_ALIAS / LW_KEY_PASS. When LW_KEYSTORE is not set, a key in
# ~/.lonewolf/release.keystore is used (created on first run with a random password stored next
# to it, both outside the repository). Never commit keystores or passwords.
# The certificate's SHA-256 goes into the game, which refuses to count matches when it runs
# from an APK signed with another key. Stores that re-sign the APKs they deliver (Google Play
# App Signing) use their own key: list its SHA-256 (from the store's console) in
# LW_EXTRA_SIGNERS, space-separated, so it counts too.
# The save-signing secret lives next to the keystore (~/.lonewolf/save_secret, or LW_SAVE_SECRET)
# and must stay the same for every release signed with that key: a new one resets every player's
# profile on update. It is only created together with a new keystore (or with
# LW_NEW_SAVE_SECRET=1); otherwise a missing secret stops the build.
# Both go into res://build_keys.gd for the export (compiled into the APK, never a plain file);
# the file is git-ignored and deleted again when the script ends.
# Needs: godot 4.7.2 + Android export templates, Android SDK build-tools (apksigner, aapt),
# and Godot editor settings pointing at the SDK and JDK.
set -euo pipefail
cd "$(dirname "$0")/.."
PRESET="${1:-Android}"
OUT="${2:-build/LoneWolfArena.apk}"

if [ -z "${LW_KEYSTORE:-}" ]; then
  mkdir -p "$HOME/.lonewolf"
  chmod 700 "$HOME/.lonewolf"
  LW_KEYSTORE="$HOME/.lonewolf/release.keystore"
  LW_KEY_ALIAS="lonewolf"
  if [ ! -f "$LW_KEYSTORE" ]; then
    head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$HOME/.lonewolf/release.pass"
    chmod 600 "$HOME/.lonewolf/release.pass"
    keytool -genkeypair -noprompt -keystore "$LW_KEYSTORE" -alias "$LW_KEY_ALIAS" -keyalg RSA -keysize 4096 \
      -validity 10000 -storepass:file "$HOME/.lonewolf/release.pass" \
      -keypass:file "$HOME/.lonewolf/release.pass" -dname "CN=Lone Wolf Arena" 2>/dev/null
    echo "created new release key: $LW_KEYSTORE"
    NEW_KEY=1
  fi
  LW_KEY_PASS="$(cat "$HOME/.lonewolf/release.pass")"
fi

# Certificate fingerprint(s) and the save secret -> build_keys.gd (read by autoload/guard.gd).
# keytool gets the password through its environment only (not its command line). Godot's
# export hands it to apksigner on the command line for the few seconds of signing; on the
# default path it is stored next to the keystore anyway.
: "${LW_KEY_ALIAS:?set LW_KEY_ALIAS (the key alias in LW_KEYSTORE)}" "${LW_KEY_PASS:?set LW_KEY_PASS (the keystore password)}"
export -n LW_KEY_PASS 2>/dev/null || true
SIGNER="$(LW_KEY_PASS="$LW_KEY_PASS" keytool -list -v -keystore "$LW_KEYSTORE" -alias "$LW_KEY_ALIAS" -storepass:env LW_KEY_PASS 2>/dev/null \
  | grep -m1 "SHA256:" | sed 's/.*SHA256: *//' | tr -d ':' | tr 'A-F' 'a-f')"
[[ "$SIGNER" =~ ^[0-9a-f]{64}$ ]] || { echo "could not read the certificate fingerprint"; exit 1; }
SIGNERS="\"$SIGNER\""
for extra in ${LW_EXTRA_SIGNERS:-}; do
  extra="$(echo "$extra" | tr -d ':' | tr 'A-F' 'a-f')"
  [[ "$extra" =~ ^[0-9a-f]{64}$ ]] || { echo "LW_EXTRA_SIGNERS: not a SHA-256: $extra"; exit 1; }
  SIGNERS="$SIGNERS, \"$extra\""
done

SECRET_SRC="${LW_SAVE_SECRET:-$(dirname "$LW_KEYSTORE")/save_secret}"
if [ ! -f "$SECRET_SRC" ]; then
  if [ -n "${LW_SAVE_SECRET:-}" ] || { [ "${NEW_KEY:-0}" != 1 ] && [ "${LW_NEW_SAVE_SECRET:-0}" != 1 ]; }; then
    echo "ERROR: no save-signing secret at $SECRET_SRC. Copy the one used for the previous release"
    echo "(a new one resets every player's profile on update); LW_NEW_SAVE_SECRET=1 makes a new one."
    exit 1
  fi
  (umask 077; head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$SECRET_SRC")
  echo "created save-signing secret: $SECRET_SRC"
fi
SECRET="$(tr -d ' \n' < "$SECRET_SRC")"
[[ "$SECRET" =~ ^[0-9a-f]{32,}$ ]] || { echo "save-signing secret in $SECRET_SRC is not 32+ hex digits"; exit 1; }

trap 'rm -f build_keys.gd build_keys.gd.uid' EXIT
(umask 077; printf '# Written by tools/build_apk.sh for one build and deleted after it. Never commit.\nconst SIGNERS := [%s]\nconst SAVE_SECRET := "%s"\n' \
  "$SIGNERS" "$SECRET" > build_keys.gd)

# A fresh checkout's first import can exit non-zero before the class cache exists; retry once.
godot --headless --path . --import > build_import.log 2>&1 || godot --headless --path . --import > build_import.log 2>&1 \
  || { tail -30 build_import.log; exit 1; }
rm -f build_import.log
godot --headless --path . res://tests/check.tscn
godot --headless --path . res://tests/run_tests.tscn

mkdir -p "$(dirname "$OUT")"
GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$LW_KEYSTORE" GODOT_ANDROID_KEYSTORE_RELEASE_USER="$LW_KEY_ALIAS" \
GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$LW_KEY_PASS" \
  godot --headless --path . --export-release "$PRESET" "$OUT"
test -s "$OUT"

# Checks: signature, permissions (no network), size. Each tool's whole output is captured first:
# with pipefail, "tool | grep -q" fails when grep stops reading early (the tool gets SIGPIPE).
SDK="$(grep -m1 android_sdk_path "$HOME/.config/godot/editor_settings-4.7.tres" | sed 's/.*= *"\(.*\)"/\1/')"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
CERTS="$("$BT/apksigner" verify --print-certs "$OUT" 2>/dev/null)"
grep -E "Signer #1 certificate (DN|SHA-256)" <<< "$CERTS"
# The game must accept its own signature, or every match would be voided.
SIGNED="$(grep -m1 "Signer #1 certificate SHA-256" <<< "$CERTS" | sed 's/.*: *//')"
[ "$SIGNED" = "$SIGNER" ] || { echo "ERROR: APK signer $SIGNED is not the key the game expects ($SIGNER)"; exit 1; }
# The keys ship compiled, and no plain key file does.
FILES="$(unzip -l "$OUT")"
grep -q "assets/build_keys.gdc" <<< "$FILES" || { echo "ERROR: the build keys are missing from the APK"; exit 1; }
if grep -qE "build_(signer|secret)\.txt|build_keys\.gd$" <<< "$FILES"; then
  echo "ERROR: the APK carries a plain build key file"; exit 1
fi
BADGING="$("$BT/aapt" dump badging "$OUT")"
grep -E "^package:|uses-permission|sdkVersion|native-code" <<< "$BADGING"
if grep -q "android.permission.INTERNET" <<< "$BADGING"; then
  echo "ERROR: the APK requests INTERNET permission"; exit 1
fi
ls -la "$OUT"
