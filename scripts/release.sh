#!/bin/zsh
# Builds build/Flux-<version>.dmg for distribution.
#
#   FLUX_VERSION=1.0.0 FLUX_BUILD=1 \
#   FLUX_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   FLUX_NOTARY_PROFILE=flux-notary \
#   scripts/release.sh
#
# FLUX_NOTARY_PROFILE names credentials saved once with
#   xcrun notarytool store-credentials flux-notary --apple-id … --team-id … --password <app-specific>
# Without FLUX_SIGN_IDENTITY the DMG is signed ad hoc: fine for testing on this Mac, but
# Gatekeeper blocks it elsewhere. Without FLUX_NOTARY_PROFILE it is signed but not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${FLUX_VERSION:-0.1.0}"
IDENTITY="${FLUX_SIGN_IDENTITY:--}"
PROFILE="${FLUX_NOTARY_PROFILE:-}"
APP="build/Flux.app"
DMG="build/Flux-${VERSION}.dmg"

if [[ -n "$PROFILE" && "$IDENTITY" == "-" ]]; then
  echo "Notarization needs a Developer ID: set FLUX_SIGN_IDENTITY too." >&2
  exit 2
fi

notarize() { # $1: file to submit (zip or dmg)
  echo "Notarizing $(basename "$1") (this takes a few minutes)…"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
}

FLUX_VERSION="$VERSION" FLUX_SIGN_IDENTITY="$IDENTITY" ./scripts/build-app.sh

if [[ -n "$PROFILE" ]]; then
  ZIP="build/Flux-${VERSION}-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
fi

# The disk image: Flux.app next to a link to /Applications.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Flux.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Flux ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

if [[ -n "$PROFILE" ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature -v "$DMG"
  echo "Ready to publish: $DMG"
elif [[ "$IDENTITY" != "-" ]]; then
  echo "Signed but not notarized: $DMG (set FLUX_NOTARY_PROFILE to notarize)"
else
  echo "Ad-hoc test build: $DMG (Gatekeeper will block it on other Macs)"
fi
shasum -a 256 "$DMG"

# The update feed: one item for this release, signed with the EdDSA key in the login
# Keychain (made once with .build/artifacts/sparkle/Sparkle/bin/generate_keys --account flux).
REPO="${FLUX_REPO:-saifGawdat/Flux}"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account flux "$DMG")"
cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Flux</title>
    <item>
      <title>Flux ${VERSION}</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/${REPO}/releases/tag/v${VERSION}</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/${REPO}/releases/download/v${VERSION}/Flux-${VERSION}.dmg"
                 type="application/octet-stream" ${SIGNATURE} />
    </item>
  </channel>
</rss>
XML
echo "Update feed: build/appcast.xml (publish with scripts/publish.sh)"
