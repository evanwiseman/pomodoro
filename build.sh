#!/bin/sh
set -e
cd "$(dirname "$0")"
APP=Pomodoro.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/"
swiftc -O -parse-as-library -target arm64-apple-macos14 Pomodoro.swift -o "$APP/Contents/MacOS/Pomodoro"
codesign --force --sign - "$APP"
echo "Built $APP"
