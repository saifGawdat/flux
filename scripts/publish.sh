#!/bin/zsh
# Publishes what scripts/release.sh built as a GitHub release: the DMG and appcast.xml.
# Installed copies of Flux read releases/latest/download/appcast.xml, so publishing is
# what offers the update to everyone. The repository must be public for that to work.
#
#   FLUX_VERSION=1.0.0 scripts/publish.sh [notes.md]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${FLUX_VERSION:?Set FLUX_VERSION to the version release.sh built}"
REPO="${FLUX_REPO:-saifGawdat/Flux}"
DMG="build/Flux-${VERSION}.dmg"
NOTES="${1:-}"

[[ -f "$DMG" && -f build/appcast.xml ]] || { echo "Run scripts/release.sh first." >&2; exit 1; }
grep -q "Flux-${VERSION}.dmg" build/appcast.xml || { echo "build/appcast.xml is for another version." >&2; exit 1; }
codesign -dv build/Flux.app 2>&1 | grep -q "Authority=Developer ID Application" || {
  echo "Warning: this build isn't signed with a Developer ID; other Macs will block it." >&2
}

echo "About to publish Flux ${VERSION} to https://github.com/${REPO} (offered to every installed copy)."
read -q "REPLY?Continue? [y/N] " || { echo; exit 1; }
echo
if [[ -n "$NOTES" ]]; then
  gh release create "v${VERSION}" "$DMG" build/appcast.xml --repo "$REPO" --title "Flux ${VERSION}" --notes-file "$NOTES"
else
  gh release create "v${VERSION}" "$DMG" build/appcast.xml --repo "$REPO" --title "Flux ${VERSION}" --generate-notes
fi
