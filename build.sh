#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ "$(xcode-select -p)" != *CommandLineTools* ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN=.build/apple/Products/Release/Relarm
else
    swift build -c release
    BIN=$(swift build -c release --show-bin-path)/Relarm
fi

rm -rf Relarm.app Relarm.zip
mkdir -p Relarm.app/Contents/MacOS Relarm.app/Contents/Resources
cp "$BIN" Relarm.app/Contents/MacOS/Relarm
cp Resources/Info.plist Relarm.app/Contents/Info.plist
cp Resources/AppIcon.icns Relarm.app/Contents/Resources/AppIcon.icns
codesign --force --sign - Relarm.app
ditto -c -k --keepParent Relarm.app Relarm.zip
echo "Built Relarm.app"
