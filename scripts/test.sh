#!/bin/zsh
# Runs the unit tests. Works with only the Command Line Tools installed (no Xcode):
# Swift Testing lives in a non-default framework folder there, and its Foundation
# cross-import overlay ships without a module, so overlays are disabled.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Checking translations"
python3 scripts/i18n.py check
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [[ -d "$FW/Testing.framework" ]] && ! xcode-select -p | grep -q Xcode.app; then
  exec swift test \
    -Xswiftc -F$FW -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -F$FW -Xlinker -rpath -Xlinker $FW \
    -Xswiftc -plugin-path -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing "$@"
fi
exec swift test "$@"
