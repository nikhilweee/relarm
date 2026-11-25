#!/bin/bash
# Regenerates docs/alarms-*.png and docs/form-*.png. Run from anywhere.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# One module instead of the SPM pair: main.swift is swapped for the renderer,
# and RelarmCore's types become local, so its import has to go.
for file in Sources/Relarm/*.swift Sources/RelarmCore/*.swift; do
    [[ "$(basename "$file")" == main.swift ]] && continue
    sed '/^import RelarmCore$/d' "$file" > "$WORK/$(basename "$file")"
done
cp scripts/screenshots.swift "$WORK/main.swift"

swiftc -O -o "$WORK/relarm-screenshots" "$WORK"/*.swift
"$WORK/relarm-screenshots" "$PWD/docs"
