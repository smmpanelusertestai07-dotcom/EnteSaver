#!/usr/bin/env bash
# Builds the signed release APK (arm64-v8a + armeabi-v7a) and checks it.
#
#   tools/build_apk.sh [preset] [out.apk]        preset defaults to "Android"
#
# Signing key: LW_KEYSTORE / LW_KEY_ALIAS / LW_KEY_PASS. When LW_KEYSTORE is not set, a key in
# ~/.lonewolf/release.keystore is used (created on first run with a random password stored next
# to it, both outside the repository). Never commit keystores or passwords.
# The certificate's SHA-256 is written to build_signer.txt (git-ignored) and packed into the
# game, which refuses to count matches when it runs from an APK re-signed with another key.
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
      -validity 10000 -storepass "$(cat "$HOME/.lonewolf/release.pass")" \
      -keypass "$(cat "$HOME/.lonewolf/release.pass")" -dname "CN=Lone Wolf Arena, O=LoneWolf, C=IN" 2>/dev/null
    echo "created new release key: $LW_KEYSTORE"
  fi
  LW_KEY_PASS="$(cat "$HOME/.lonewolf/release.pass")"
fi

# Certificate fingerprint of the signing key -> build_signer.txt (read by autoload/guard.gd).
keytool -list -v -keystore "$LW_KEYSTORE" -alias "$LW_KEY_ALIAS" -storepass "$LW_KEY_PASS" 2>/dev/null \
  | grep -m1 "SHA256:" | sed 's/.*SHA256: *//' | tr -d ':' | tr 'A-F' 'a-f' > build_signer.txt
test "$(wc -c < build_signer.txt)" -ge 64 || { echo "could not read the certificate fingerprint"; exit 1; }

godot --headless --path . --import > build_import.log 2>&1 || { tail -30 build_import.log; exit 1; }
rm -f build_import.log
godot --headless --path . res://tests/check.tscn
godot --headless --path . res://tests/run_tests.tscn

mkdir -p "$(dirname "$OUT")"
GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$LW_KEYSTORE" GODOT_ANDROID_KEYSTORE_RELEASE_USER="$LW_KEY_ALIAS" \
GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$LW_KEY_PASS" \
  godot --headless --path . --export-release "$PRESET" "$OUT"
test -s "$OUT"

# Checks: signature, permissions (no network), size.
SDK="$(grep -m1 android_sdk_path "$HOME/.config/godot/editor_settings-4.7.tres" | sed 's/.*= *"\(.*\)"/\1/')"
BT="$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)"
"$BT/apksigner" verify --print-certs "$OUT" 2>/dev/null | grep -E "Signer #1 certificate (DN|SHA-256)"
"$BT/aapt" dump badging "$OUT" | grep -E "^package:|uses-permission|sdkVersion|native-code"
if "$BT/aapt" dump badging "$OUT" | grep -q "android.permission.INTERNET"; then
  echo "ERROR: the APK requests INTERNET permission"; exit 1
fi
ls -la "$OUT"
