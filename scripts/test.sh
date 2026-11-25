#!/bin/zsh
# Runs the test suite. With only the Command Line Tools installed (no Xcode), SwiftPM
# doesn't find Testing.framework on its own, so point the compiler and linker at it.
set -euo pipefail
cd "$(dirname "$0")/.."
FW="$(xcode-select -p)/Library/Developer/Frameworks"
LIB="$(xcode-select -p)/Library/Developer/usr/lib"
if [[ -d "$FW/Testing.framework" && ! -d "$(xcode-select -p)/Platforms" ]]; then
  exec swift test -Xswiftc -F -Xswiftc "$FW" -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" "$@"
fi
exec swift test "$@"
