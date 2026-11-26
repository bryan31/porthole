#!/bin/zsh
# Renders the app screenshots on the website, once per site language.
#   ./scripts/render-site-shots.sh           use the existing build/Porthole.app
#   ./scripts/render-site-shots.sh --build   rebuild the app first (./scripts/build-app.sh)
#
# Runs the app's offscreen snapshot mode (--render-snapshots: sample tunnels in memory, no
# window on screen, nothing saved) with each language and writes
#   build/site-shots/<zh-hans|zh-hant|en>/*.png        full-quality PNGs, kept for reference
#   website/assets/img/shots/<zh-hans|zh-hant|en>/*.webp  what the pages use
# The WebP files are lossless (same pixels, about a quarter of the size). The snapshots come
# out in the main display's colour profile, so they are converted to sRGB first: WebP files
# carry no profile and browsers read them as sRGB.
# The snapshots run from a temporary copy with its own bundle id, so they show default
# settings instead of your own Porthole preferences (language, Dock/menu bar, login item…).
# Run it again after changing the app's UI or its translations. Needs cwebp (brew install webp).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Porthole.app"
PNG="build/site-shots"
OUT="website/assets/img/shots"
SRGB="/System/Library/ColorSync/Profiles/sRGB Profile.icc"

command -v cwebp >/dev/null || { echo "Missing cwebp – install it with: brew install webp" >&2; exit 1; }

if [[ "${1:-}" == "--build" ]]; then
  ./scripts/build-app.sh
fi
[[ -x "$APP/Contents/MacOS/Porthole" ]] || { echo "Missing $APP – run ./scripts/build-app.sh first." >&2; exit 1; }

TMP=$(mktemp -d)
SNAP_ID="app.porthole.mac.site-shots"
trap 'defaults delete "$SNAP_ID" >/dev/null 2>&1 || true; rm -f ~/Library/Preferences/"$SNAP_ID".plist; rm -rf "$TMP"' EXIT

cp -R "$APP" "$TMP/Porthole.app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SNAP_ID" "$TMP/Porthole.app/Contents/Info.plist"
codesign --force --sign - "$TMP/Porthole.app" >/dev/null 2>&1

# Snapshots the pages use as they are
SHOTS=(editor-server editor-forwarding editor-forwarding-remote editor-connection-jump editor-advanced
       menubar prompt-hostkey prompt-password settings-general)

# site folder : app language
for pair in zh-hans:zh-Hans zh-hant:zh-Hant en:en; do
  dir=${pair%%:*}
  lang=${pair#*:}
  echo "==> $lang"
  defaults delete "$SNAP_ID" >/dev/null 2>&1 || true
  defaults write "$SNAP_ID" AppleLanguages -array "$lang"
  # (LaunchServices may print a harmless sandbox_extension warning for the temporary copy)
  "$TMP/Porthole.app/Contents/MacOS/Porthole" --render-snapshots "$TMP/$dir" >/dev/null 2> >(grep -v sandbox_extension >&2)
  mkdir -p "$PNG/$dir" "$OUT/$dir"
  for s in $SHOTS; do
    sips --matchTo "$SRGB" "$TMP/$dir/$s.png" --out "$PNG/$dir/$s.png" >/dev/null
  done
  # The detail pane on the right of the main window (2x pixels: from x 630, y 20)
  sips --matchTo "$SRGB" -c 960 1690 --cropOffset 20 630 "$TMP/$dir/main-dark.png" --out "$PNG/$dir/detail-dark.png" >/dev/null
  sips --matchTo "$SRGB" -c 960 1690 --cropOffset 20 630 "$TMP/$dir/main-light.png" --out "$PNG/$dir/detail-light-top.png" >/dev/null
  sips --matchTo "$SRGB" -c 1500 1690 --cropOffset 20 630 "$TMP/$dir/main-light.png" --out "$PNG/$dir/detail-light.png" >/dev/null

  rm -f "$OUT/$dir"/*.png "$OUT/$dir"/*.webp
  for f in "$PNG/$dir"/*.png; do
    cwebp -quiet -lossless -z 9 "$f" -o "$OUT/$dir/${${f:t}%.png}.webp"
  done
done

echo "==> Done: $OUT/{zh-hans,zh-hant,en} (PNGs in $PNG)"
