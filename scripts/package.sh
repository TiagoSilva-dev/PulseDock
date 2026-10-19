#!/bin/bash
# Builds a distributable PulseDock: release build → signed .app → ZIP and DMG in build/dist/.
#
#   scripts/package.sh
#
# Signing and notarization use only Apple's tools and your own credentials:
#   PULSEDOCK_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   sign with hardened runtime + timestamp
#   PULSEDOCK_NOTARY_PROFILE="pulsedock-notary"                        keychain profile created once with
#       xcrun notarytool store-credentials pulsedock-notary --apple-id … --team-id … --password <app-specific>
#
# Without an identity the build is ad-hoc signed: it runs on this Mac, but Gatekeeper rejects it on
# other Macs. This script never weakens Gatekeeper and never suggests disabling it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source scripts/app-config.sh

scripts/build-app.sh release >/dev/null
APP="$ROOT/build/release/PulseDock.app"
DIST="$ROOT/build/dist"
NAME="PulseDock-$VERSION"
rm -rf "$DIST"
mkdir -p "$DIST"

codesign --verify --strict --deep --verbose=2 "$APP"

ZIP="$DIST/$NAME.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [ -n "${PULSEDOCK_SIGN_IDENTITY:-}" ] && [ -n "${PULSEDOCK_NOTARY_PROFILE:-}" ]; then
  echo "Submitting for notarization…"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PULSEDOCK_NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
  NOTARIZED=yes
else
  NOTARIZED=no
fi

STAGING="$(mktemp -d)"
chmod 755 "$STAGING"   # mktemp creates 0700; the volume root must be readable
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$DIST/$NAME.dmg"
# `diskutil image` replaces `hdiutil create` on recent macOS; fall back for macOS 15.
if diskutil image create from --help >/dev/null 2>&1; then
  diskutil image create from --format UDZO --volumeName "PulseDock" "$STAGING" "$DMG" >/dev/null
else
  hdiutil create -volname "PulseDock" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
fi
rm -rf "$STAGING"
if [ -n "${PULSEDOCK_SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$PULSEDOCK_SIGN_IDENTITY" "$DMG"
  if [ "$NOTARIZED" = yes ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$PULSEDOCK_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo
echo "Artifacts in $DIST:"
ls -lh "$DIST"
echo
echo "Signature: $(codesign -dv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)"
if [ "$NOTARIZED" = yes ]; then
  spctl --assess --type execute --verbose=2 "$APP" || true
else
  echo "Not notarized (set PULSEDOCK_SIGN_IDENTITY and PULSEDOCK_NOTARY_PROFILE). Gatekeeper will block this build on other Macs."
fi
