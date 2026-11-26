#!/bin/zsh
# Builds a native Apple-silicon Porthole.app into ./build
#   ./scripts/build-app.sh            release build
#   ./scripts/build-app.sh --install  also copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Porthole"
VERSION="1.0.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
OUT="build/${APP_NAME}.app"

echo "==> Compiling (release, arm64)"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/${APP_NAME}"

echo "==> Assembling ${OUT}"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp "$BIN" "$OUT/Contents/MacOS/${APP_NAME}"

ICON_DIR="build/icon"
if [[ ! -f "$ICON_DIR/AppIcon.icns" || scripts/make-icon.swift -nt "$ICON_DIR/AppIcon.icns" \
      || design/logo/porthole.svg -nt "$ICON_DIR/AppIcon.icns" || design/logo/porthole-small.svg -nt "$ICON_DIR/AppIcon.icns" ]]; then
  echo "==> Rendering icon"
  rm -rf "$ICON_DIR" && mkdir -p "$ICON_DIR"
  # Rendered from design/logo/*.svg; 16 and 32 px use the simplified artwork rather than a downscale.
  swift scripts/make-icon.swift "$ICON_DIR/AppIcon.iconset" >/dev/null
  cp "$ICON_DIR/AppIcon.iconset/icon_512x512@2x.png" "$ICON_DIR/AppIcon-1024.png"
  iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$ICON_DIR/AppIcon.icns"
fi
cp "$ICON_DIR/AppIcon.icns" "$OUT/Contents/Resources/AppIcon.icns"

echo "==> Compiling translations"
python3 scripts/i18n.py compile "$OUT/Contents/Resources" >/dev/null
LOCALIZATIONS=""
for d in "$OUT"/Contents/Resources/*.lproj; do
  LOCALIZATIONS+="    <string>$(basename "$d" .lproj)</string>"$'\n'
done

cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleLocalizations</key>
  <array>
${LOCALIZATIONS}  </array>
  <key>CFBundleIdentifier</key><string>app.porthole.mac</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>Porthole – SSH tunnels for macOS</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$OUT"

file "$OUT/Contents/MacOS/${APP_NAME}"
echo "==> Built $(pwd)/${OUT}"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to /Applications"
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "$OUT" "/Applications/${APP_NAME}.app"
  echo "==> Installed /Applications/${APP_NAME}.app"
fi
