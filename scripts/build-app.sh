#!/bin/bash
# Builds build/<configuration>/PulseDock.app with the hook helper and pulsedockctl inside.
#   scripts/build-app.sh [debug|release]
# Signing: ad-hoc by default. Set PULSEDOCK_SIGN_IDENTITY="Developer ID Application: …"
# for a distributable build (hardened runtime + secure timestamp).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
cd "$ROOT"
source scripts/app-config.sh

# Release builds fail on a missing or malformed translation; debug builds only warn.
if [ "$CONFIG" = "release" ]; then python3 scripts/localize.py --strict >/dev/null; else python3 scripts/localize.py >/dev/null; fi
if [ ! -f Resources/AppIcon.icns ]; then
  swift scripts/make-icon.swift Resources >/dev/null
fi

# Release builds are universal (Apple Silicon + Intel); set PULSEDOCK_UNIVERSAL=0 for a native-only
# build. Debug builds stay native for fast iteration.
ARCH_FLAGS=()
if [ "$CONFIG" = "release" ] && [ "${PULSEDOCK_UNIVERSAL:-1}" = "1" ]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
# (bash 3.2 + `set -u`: expand a possibly empty array safely)
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product PulseDock
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product pulsedock-hook
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --product pulsedockctl
BIN="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="$ROOT/build/$CONFIG/PulseDock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/PulseDock" "$APP/Contents/MacOS/PulseDock"
cp "$BIN/pulsedock-hook" "$APP/Contents/Helpers/pulsedock-hook"
cp "$BIN/pulsedockctl" "$APP/Contents/Helpers/pulsedockctl"
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp -R Resources/Generated/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${PULSEDOCK_SIGN_IDENTITY:--}"
if [ "$IDENTITY" = "-" ]; then
  SIGN=(codesign --force --options runtime --sign -)
else
  SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
fi
"${SIGN[@]}" --identifier "$BUNDLE_ID.hook" "$APP/Contents/Helpers/pulsedock-hook"
"${SIGN[@]}" --identifier "$BUNDLE_ID.ctl" "$APP/Contents/Helpers/pulsedockctl"
"${SIGN[@]}" --entitlements Resources/PulseDock.entitlements "$APP"
codesign --verify --strict --deep "$APP"
echo "$APP"
