#!/bin/bash
# Build JustHide.app.
#
# No Xcode project on purpose: this is one target with a handful of files, and a
# hand-assembled bundle is less machinery than a pbxproj to maintain.
#
# Signing note: TCC (the Accessibility grant) keys on the code signature, and an
# ad-hoc signature changes with every build, so macOS would ask again after each
# rebuild. If a self-signed identity named "JustHide Dev" exists in the keychain it
# is used instead, which keeps the grant across rebuilds. Create one with:
#   Keychain Access > Certificate Assistant > Create a Certificate...
#   name "JustHide Dev", identity type "Self Signed Root", type "Code Signing"

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-$ROOT/build/JustHide.app}"
# Which identity to sign with, best first. TCC keys the Accessibility grant on
# the signature, so a STABLE identity is what stops every rebuild losing the
# permission -- an ad-hoc signature is different every time.
#
# A real Developer ID beats the self-signed "JustHide Dev" this used to look for:
# it is stable in exactly the same way, and it is the identity a release needs
# anyway, so there is no reason to keep a second one around.
if [ -n "${JUSTHIDE_IDENTITY:-}" ]; then
    IDENTITY="$JUSTHIDE_IDENTITY"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application"; then
    IDENTITY="Developer ID Application"
else
    IDENTITY="JustHide Dev"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> Compiling"
xcrun swiftc \
    -O \
    -target arm64-apple-macos14.0 \
    -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
    -framework Cocoa \
    -o "$APP/Contents/MacOS/JustHide" \
    "$ROOT"/Sources/*.swift

echo "==> Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --options runtime --entitlements "$ROOT/Resources/JustHide.entitlements" --sign "$IDENTITY" "$APP"
    echo "    signed with '$IDENTITY' (Accessibility grant persists across rebuilds)"
else
    codesign --force --entitlements "$ROOT/Resources/JustHide.entitlements" --sign - "$APP"
    echo "    ad-hoc signed; no '$IDENTITY' identity found."
    echo "    macOS may re-ask for Accessibility after each rebuild."
fi

echo "==> Built: $APP"
echo
echo "Try:  '$APP/Contents/MacOS/JustHide' --list"
echo "Then: '$APP/Contents/MacOS/JustHide' --selftest"
