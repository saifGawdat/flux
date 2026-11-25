#!/bin/zsh
# Builds an Apple Silicon release of Flux and wraps it in build/Flux.app (ad-hoc signed).
# Developer ID signing, notarization and DMG packaging come in Phase 7.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${FLUX_VERSION:-0.1.0}"
BUILD="${FLUX_BUILD:-1}"
APP="build/Flux.app"

swift build -c release --arch arm64 --product Flux
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Flux"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Flux"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Flux</string>
  <key>CFBundleDisplayName</key><string>Flux</string>
  <key>CFBundleIdentifier</key><string>app.flux.Flux</string>
  <key>CFBundleExecutable</key><string>Flux</string>
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

codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Flux"))"
