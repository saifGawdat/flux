#!/bin/zsh
# Builds an Apple Silicon release of Flux and wraps it in build/Flux.app, signed with the
# hardened runtime. FLUX_SIGN_IDENTITY="Developer ID Application: …" signs for distribution
# (with a secure timestamp); without it the app is signed ad hoc for local use.
# scripts/release.sh adds notarization and the DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${FLUX_VERSION:-0.1.0}"
BUILD="${FLUX_BUILD:-1}"
APP="build/Flux.app"

swift build -c release --arch arm64 --product Flux
swift build -c release --arch arm64 --product flux-cli
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/Flux"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/Flux"
# The command-line tool; Settings › General links it into the PATH as `flux`.
cp "$BIN_DIR/flux-cli" "$APP/Contents/Helpers/flux"
cp Resources/Brand/sky-halftone.jpg "$APP/Contents/Resources/"
cp Resources/Brand/Flux.icns "$APP/Contents/Resources/"   # regenerate: swift scripts/make-icon.swift

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Flux</string>
  <key>CFBundleDisplayName</key><string>Flux</string>
  <key>CFBundleIdentifier</key><string>app.flux.Flux</string>
  <key>CFBundleExecutable</key><string>Flux</string>
  <key>CFBundleIconFile</key><string>Flux</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Everything you download. Under control.</string>
  <!-- A download manager must fetch plain http:// links. This only permits cleartext
       HTTP; HTTPS certificate validation is unaffected. -->
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

IDENTITY="${FLUX_SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then TIMESTAMP="--timestamp=none"; else TIMESTAMP="--timestamp"; fi
# Inside out: the helper first, then the app. No entitlements: Flux needs no exceptions to
# the hardened runtime (it loads no third-party code and only launches other programs).
codesign --force --options runtime --sign "$IDENTITY" $TIMESTAMP "$APP/Contents/Helpers/flux"
codesign --force --options runtime --sign "$IDENTITY" $TIMESTAMP "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Flux"))"
