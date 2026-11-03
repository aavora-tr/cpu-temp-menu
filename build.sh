#!/bin/zsh
# Builds CPUTemp.app (menu bar) into ~/Applications and the cputemp CLI into ~/.local/bin.
set -euo pipefail
cd "$(dirname "$0")"
TARGET=arm64-apple-macos14.0
APP=build/CPUTemp.app
rm -rf build && mkdir -p "$APP/Contents/MacOS"
swiftc -O -target $TARGET -o "$APP/Contents/MacOS/CPUTemp" TempSensors.swift History.swift HardReset.swift App/main.swift
swiftc -O -target $TARGET -o build/cputemp TempSensors.swift History.swift CLI/main.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>CPUTemp</string>
  <key>CFBundleIdentifier</key><string>local.cputemp.menubar</string>
  <key>CFBundleExecutable</key><string>CPUTemp</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --force --sign - build/cputemp
mkdir -p ~/Applications ~/.local/bin
pkill -x CPUTemp 2>/dev/null && sleep 1 || true
rm -rf ~/Applications/CPUTemp.app && cp -R "$APP" ~/Applications/
cp build/cputemp ~/.local/bin/cputemp
open ~/Applications/CPUTemp.app
echo "Installed ~/Applications/CPUTemp.app and ~/.local/bin/cputemp"
