#!/bin/bash
# Renders the website clips (fake data, offscreen, on pure black) into site/assets/media/:
# <name>.mp4 (H.264) + <name>.webm (VP9) + <name>-poster.png (first frame), plus og.png.
# Usage: bash tools/screenshots/clips.sh [name,...]
set -euo pipefail
cd "$(dirname "$0")/../.."
FFMPEG=${FFMPEG:-/opt/homebrew/bin/ffmpeg}
OUT=site/assets/media
FRAMES=.build/clipframes
mkdir -p "$OUT" .build
FILES=$(find Sources/Perch -name '*.swift' ! -path '*/Core/main.swift')
swiftc -Onone -D PERCH_PROBE -module-name Perch $FILES tools/screenshots/main.swift -o .build/perchshots
.build/perchshots --clips "$FRAMES" ${1:-}

for d in "$FRAMES"/*/; do
    name=$(basename "$d")
    if [ -n "${1:-}" ] && [[ ",$1," != *",$name,"* ]]; then continue; fi
    cp "$d/0000.png" "$OUT/$name-poster.png"
    "$FFMPEG" -loglevel error -y -framerate 30 -i "$d/%04d.png" \
        -c:v libx264 -pix_fmt yuv420p -crf 20 -preset slow -tune animation -movflags +faststart -an "$OUT/$name.mp4"
    "$FFMPEG" -loglevel error -y -framerate 30 -i "$d/%04d.png" \
        -c:v libvpx-vp9 -pix_fmt yuv420p -crf 32 -b:v 0 -row-mt 1 -deadline good -an "$OUT/$name.webm"
    echo "encoded $name"
done

swift tools/screenshots/og.swift docs/images/icon.png docs/images/home.png "$OUT/og.png"
ls -la "$OUT"
