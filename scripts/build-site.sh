#!/bin/zsh
# Packages build/Porthole.app as a zip and refreshes the website's download.
#   ./scripts/build-site.sh           use the existing build/Porthole.app
#   ./scripts/build-site.sh --build   rebuild the app first (./scripts/build-app.sh)
#
# Writes website/downloads/Porthole-<version>.zip (+ .sha256) and updates every
# element marked data-release="version|size|date|sha256" and every
# downloads/Porthole-*.zip link in the site's pages (website/*.html: English, the default; and the language
# folders website/zh-hans/, website/zh-hant/). The site is plain static files: upload the
# website/ folder to any static host.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Porthole.app"
SITE="website"

if [[ "${1:-}" == "--build" ]]; then
  ./scripts/build-app.sh
fi
[[ -d "$APP" ]] || { echo "Missing $APP – run ./scripts/build-app.sh first." >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
ZIP="Porthole-${VERSION}.zip"

# Reuse the zip if it is newer than the app; otherwise package again.
if [[ ! -f "build/$ZIP" || "$APP/Contents/MacOS/Porthole" -nt "build/$ZIP" || "$PLIST" -nt "build/$ZIP" ]]; then
  echo "==> Packaging build/$ZIP"
  rm -f "build/$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "build/$ZIP"
else
  echo "==> Reusing build/$ZIP"
fi
(cd build && shasum -a 256 "$ZIP" > "$ZIP.sha256")

echo "==> Copying to $SITE/downloads"
mkdir -p "$SITE/downloads"
find "$SITE/downloads" -name 'Porthole-*.zip*' ! -name "$ZIP" ! -name "$ZIP.sha256" -delete
cp "build/$ZIP" "build/$ZIP.sha256" "$SITE/downloads/"

SHA=$(cut -d' ' -f1 "build/$ZIP.sha256")
BYTES=$(stat -f%z "build/$ZIP")
SIZE=$(awk -v b="$BYTES" 'BEGIN { printf "%.1f MB", b / 1000000 }')
DATE=$(date -r "build/$ZIP" +%Y-%m-%d)

echo "==> Updating pages: version $VERSION, $SIZE, $DATE"
for page in "$SITE"/*.html "$SITE"/*/*.html; do
  sed -i '' -E \
    -e "s#downloads/Porthole-[0-9][0-9A-Za-z.+-]*\.zip#downloads/${ZIP}#g" \
    -e "s#(data-release=\"version\">)[^<]*#\1${VERSION}#g" \
    -e "s#(data-release=\"size\">)[^<]*#\1${SIZE}#g" \
    -e "s#(data-release=\"date\">)[^<]*#\1${DATE}#g" \
    -e "s#(data-release=\"sha256\">)[^<]*#\1${SHA}#g" \
    "$page"
done

echo "==> Done. Preview: python3 -m http.server --directory $SITE 8765"
