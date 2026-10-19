#!/bin/zsh
# Renders the website stills and control animations (see Curves/MarketingExport.swift).
#
#   Curves/Tools/export-marketing.sh [photo] [output dir]
#
# photo       drives histograms/scopes/hue backdrops and the Detail close-up (default: falls.jpg)
# output dir  default: <repo>/marketing-export
#
# Env: SCALE (stills, default 4), VIDEO_SCALE (default 2), FPS (default 60), ONLY=name,name,
#      POINTER=1 to draw the cursor in the videos
set -euo pipefail

HERE=${0:A:h}
ROOT=${HERE:h}
PHOTO=${1:-"$HOME/Code/goodnight-photo-web-2/Photography Website/src/assets/gen/falls.jpg"}
OUT=${2:-"${ROOT:h}/marketing-export"}
DERIVED="$ROOT/.build/marketing-derived"

command -v ffmpeg >/dev/null || { echo "ffmpeg is required (brew install ffmpeg)"; exit 1; }

echo "› Building Curves (Release)…"
(cd "$ROOT" && xcodegen generate --quiet)
xcodebuild -project "$ROOT/Curves.xcodeproj" -scheme Curves -configuration Release \
  -derivedDataPath "$DERIVED" build -quiet

echo "› Rendering stills and encoding videos…"
args=(--export-marketing "$OUT" --marketing-photo "$PHOTO" --marketing-ffmpeg "$(command -v ffmpeg)"
      --marketing-scale "${SCALE:-4}" --marketing-video-scale "${VIDEO_SCALE:-2}" --marketing-fps "${FPS:-60}")
[[ -n "${ONLY:-}" ]] && args+=(--marketing-only "$ONLY")
[[ -n "${POINTER:-}" ]] && args+=(--marketing-pointer)
"$DERIVED/Build/Products/Release/Curves.app/Contents/MacOS/Curves" "${args[@]}" 2>&1 | grep '^\[marketing\]\|fail'

echo "✓ Done → $OUT"
