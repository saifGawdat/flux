#!/bin/zsh
# Builds an Apple Silicon release of Flux and wraps it in build/Flux.app, signed with the
# hardened runtime. FLUX_SIGN_IDENTITY="Developer ID Application: …" signs for distribution
# (with a secure timestamp); without it the app is signed ad hoc for local use.
# scripts/release.sh adds notarization and the DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${FLUX_VERSION:-0.1.0}"
# Updates compare build numbers, so they must only ever go up: the commit count does.
BUILD="${FLUX_BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
REPO="${FLUX_REPO:-saifGawdat/Flux}"
# Sparkle reads the newest release's appcast.xml; GitHub redirects "latest" to it.
FEED="${FLUX_FEED_URL:-https://github.com/${REPO}/releases/latest/download/appcast.xml}"
ED_KEY="$(cat Resources/Sparkle/public-ed-key.txt)"
APP="build/Flux.app"

swift build -c release --arch arm64 --product Flux
swift build -c release --arch arm64 --product flux-cli
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
BIN="$BIN_DIR/Flux"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Flux"
# The command-line tool; Settings › General links it into the PATH as `flux`.
cp "$BIN_DIR/flux-cli" "$APP/Contents/Helpers/flux"
cp Resources/Brand/sky-halftone.jpg "$APP/Contents/Resources/"
cp Resources/Brand/Flux.icns "$APP/Contents/Resources/"   # regenerate: swift scripts/make-icon.swift
# Sparkle (in-app updates). Its XPC services are only for sandboxed apps; Flux isn't one.
SPARKLE=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

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
  <key>SUFeedURL</key><string>${FEED}</string>
  <key>SUPublicEDKey</key><string>${ED_KEY}</string>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
PLIST

IDENTITY="${FLUX_SIGN_IDENTITY:--}"
if [[ "$IDENTITY" == "-" ]]; then TIMESTAMP="--timestamp=none"; else TIMESTAMP="--timestamp"; fi
# Inside out: Sparkle's parts, the helper, then the app. Developer ID builds need no
# entitlements; ad-hoc builds get one (see Resources/Sparkle/adhoc.entitlements).
SP="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --sign "$IDENTITY" $TIMESTAMP "$SP/Versions/B/Autoupdate"
codesign --force --options runtime --sign "$IDENTITY" $TIMESTAMP "$SP/Versions/B/Updater.app"
codesign --force --options runtime --sign "$IDENTITY" $TIMESTAMP "$SP"
codesign --force --options runtime --sign "$IDENTITY" $TIMESTAMP "$APP/Contents/Helpers/flux"
if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --options runtime --sign - $TIMESTAMP --entitlements Resources/Sparkle/adhoc.entitlements "$APP"
else
  codesign --force --options runtime --sign "$IDENTITY" $TIMESTAMP "$APP"
fi
codesign --verify --strict --deep "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Flux"))"
