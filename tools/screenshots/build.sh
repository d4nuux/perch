#!/bin/bash
# Renders the README screenshots (fake data, offscreen) into docs/images/.
# Usage: tools/screenshots/build.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
FILES=$(find Sources/Perch -name '*.swift' ! -path '*/Core/main.swift')
swiftc -Onone -D PERCH_PROBE -module-name Perch $FILES tools/screenshots/main.swift -o .build/perchshots
.build/perchshots docs/images
