#!/bin/bash
# Cut a release of JustHide: build, sign, notarise, staple, zip, checksum, and
# optionally publish the GitHub release and bump the Homebrew cask.
#
# Nothing secret lives in this file or in the repo. It needs two things set up
# once, both documented in docs/RELEASING.md:
#
#   1. A Developer ID Application certificate in your keychain:
#        security find-identity -v -p codesigning
#      It is picked automatically when there is exactly one; set
#      JUSTHIDE_IDENTITY to choose between several.
#
#   2. A notarytool keychain profile, made once with an App Store Connect key:
#        xcrun notarytool store-credentials justhide \
#            --key AuthKey_XXXXXXXX.p8 --key-id XXXXXXXX --issuer <issuer-uuid>
#      Set JUSTHIDE_NOTARY_PROFILE to use a different profile name.
#
# Usage:
#   ./release.sh              build, sign, notarise, staple, zip, print the cask
#   ./release.sh --publish    also create the GitHub release and bump the tap
#
# The version is read from the bundle, so the tag, the zip and the cask cannot
# drift apart: bump CFBundleShortVersionString in Resources/Info.plist and this
# follows it.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROFILE="${JUSTHIDE_NOTARY_PROFILE:-justhide}"
TAP="${JUSTHIDE_TAP:-$HOME/Developer/homebrew-tap}"
PUBLISH=false
[[ "${1:-}" == "--publish" ]] && PUBLISH=true

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
           "$ROOT/Resources/Info.plist")"
APP="$ROOT/build/JustHide.app"
ZIP="$ROOT/build/JustHide-$VERSION.zip"

# ---- Identity

if [[ -n "${JUSTHIDE_IDENTITY:-}" ]]; then
    IDENTITY="$JUSTHIDE_IDENTITY"
else
    IDENTITY="$(security find-identity -v -p codesigning \
                | grep 'Developer ID Application' \
                | head -1 \
                | sed -n 's/.*"\(.*\)".*/\1/p')"
fi

if [[ -z "$IDENTITY" ]]; then
    cat >&2 <<'NOIDENTITY'
No "Developer ID Application" certificate in your keychain.

A release has to be signed with one: it is what lets macOS install the app
without a Gatekeeper fight, and what keeps everyone's Accessibility permission
across updates (an ad-hoc signature is a hash of one exact build, so every
update would reset it).

See docs/RELEASING.md for how to create one without Xcode.
NOIDENTITY
    exit 1
fi

echo "==> JustHide $VERSION"
echo "    identity: $IDENTITY"

# ---- Build and sign

"$ROOT/build.sh" "$APP" >/dev/null

# Signed again here, deliberately. Notarisation refuses anything without the
# hardened runtime and a secure timestamp, and build.sh asks for neither of
# those when it is signing something you are only going to run locally.
echo "==> Signing for distribution"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Printed because it is the thing that matters for updates: identity-based, not
# a hash of this build. If this says "cdhash" then something signed it ad-hoc
# and every update will ask your users for Accessibility again.
echo "==> Designated requirement:"
codesign -d --requirements - "$APP" 2>&1 | sed -n 's/^designated =>/    /p'

# ---- Notarise

echo "==> Notarising (Apple usually takes a couple of minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# The ticket is stapled to the .app, so the zip has to be made again afterwards
# or what people download is the un-stapled copy.
echo "==> Stapling"
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> As Gatekeeper will see it:"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | sed 's/^/    /' || true

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

echo
echo "==> $ZIP"
echo "    sha256 $SHA"

if [[ "$PUBLISH" != true ]]; then
    cat <<EOF

Not published (pass --publish to do that). To do it by hand:

    gh release create v$VERSION "$ZIP" --title "JustHide $VERSION" --generate-notes

and in the tap's Casks/justhide.rb:

    version "$VERSION"
    sha256 "$SHA"
EOF
    exit 0
fi

# ---- Publish

echo "==> Creating release v$VERSION"
gh release create "v$VERSION" "$ZIP" \
    --repo benjustjammin/justhide \
    --title "JustHide $VERSION" \
    --generate-notes

CASK="$TAP/Casks/justhide.rb"
if [[ -f "$CASK" ]]; then
    echo "==> Updating the cask in $TAP"
    /usr/bin/sed -i '' \
        -e "s/^  version \".*\"/  version \"$VERSION\"/" \
        -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
        "$CASK"
    git -C "$TAP" add Casks/justhide.rb
    git -C "$TAP" commit -m "justhide $VERSION" >/dev/null
    if git -C "$TAP" remote get-url origin >/dev/null 2>&1; then
        git -C "$TAP" push
        echo "    pushed"
    else
        echo "    committed; the tap has no remote yet, so nothing was pushed"
    fi
else
    echo "==> No cask at $CASK, so nothing to bump (set JUSTHIDE_TAP)"
fi

echo
echo "Done. Check it installs the way a stranger would:"
echo "    brew uninstall --cask justhide 2>/dev/null; brew update && brew install --cask benjustjammin/tap/justhide"
