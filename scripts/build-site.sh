#!/bin/zsh
# Packages build/Porthole.app as a zip and refreshes the website's download section.
#   ./scripts/build-site.sh           use the existing build/Porthole.app
#   ./scripts/build-site.sh --build   rebuild the app first (./scripts/build-app.sh)
#
# Writes build/Porthole-<version>.zip (+ .sha256). The site does not host the zip: its
# download buttons point at the GitHub release asset (tag "release"), so upload the zip
# there under the same file name. The script updates every element marked
# data-release="version|size|date|sha256" and every GitHub release zip link in the site's
# pages (website/*.html: English, the default; and the language folders website/zh-hans/,
# website/zh-hant/). The site is plain static files: upload the website/ folder to any
# static host.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Porthole.app"
SITE="website"
RELEASE_BASE="https://github.com/bryan31/porthole/releases/download/release"

if [[ "${1:-}" == "--build" ]]; then
  ./scripts/build-app.sh
fi
[[ -d "$APP" ]] || { echo "Missing $APP – run ./scripts/build-app.sh first." >&2; exit 1; }

PLIST="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
ZIP="Porthole-${VERSION}.zip"
URL="${RELEASE_BASE}/${ZIP}"

# Reuse the zip if it is newer than the app; otherwise package again.
if [[ ! -f "build/$ZIP" || "$APP/Contents/MacOS/Porthole" -nt "build/$ZIP" || "$PLIST" -nt "build/$ZIP" ]]; then
  echo "==> Packaging build/$ZIP"
  rm -f "build/$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "build/$ZIP"
else
  echo "==> Reusing build/$ZIP"
fi
(cd build && shasum -a 256 "$ZIP" > "$ZIP.sha256")

SHA=$(cut -d' ' -f1 "build/$ZIP.sha256")
BYTES=$(stat -f%z "build/$ZIP")
SIZE=$(awk -v b="$BYTES" 'BEGIN { printf "%.1f MB", b / 1000000 }')
DATE=$(date -r "build/$ZIP" +%Y-%m-%d)

echo "==> Updating pages: version $VERSION, $SIZE, $DATE"
for page in "$SITE"/*.html "$SITE"/*/*.html; do
  sed -i '' -E \
    -e "s#${RELEASE_BASE}/Porthole-[0-9][0-9A-Za-z.+-]*\.zip#${URL}#g" \
    -e "s#(data-release=\"version\">)[^<]*#\1${VERSION}#g" \
    -e "s#(data-release=\"size\">)[^<]*#\1${SIZE}#g" \
    -e "s#(data-release=\"date\">)[^<]*#\1${DATE}#g" \
    -e "s#(data-release=\"sha256\">)[^<]*#\1${SHA}#g" \
    "$page"
done

# The pages show this zip's size and SHA-256, so the GitHub asset must be the same file.
# Only the size can be checked without downloading it.
REMOTE_BYTES=$(curl -sIL --max-time 15 "$URL" | awk 'tolower($1) == "content-length:" { n = $2 } END { gsub(/\r/, "", n); print n }' || true)
if [[ "$REMOTE_BYTES" == "$BYTES" ]]; then
  echo "==> GitHub release asset found, same size ($BYTES bytes)"
else
  echo "!!  $URL is ${REMOTE_BYTES:-unreachable} bytes, build/$ZIP is $BYTES bytes." >&2
  echo "!!  Upload build/$ZIP to the GitHub release \"release\" before publishing the site." >&2
fi

echo "==> Done. Preview: python3 -m http.server --directory $SITE 8765"
