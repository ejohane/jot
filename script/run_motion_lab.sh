#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOT_MOTION_LAB=1 "$ROOT_DIR/script/package_app.sh"
pkill -x JotMotionLab >/dev/null 2>&1 || true
LAB="$ROOT_DIR/dist/Jot Motion Lab.app"
rm -rf "$LAB"
mkdir -p "$LAB/Contents/MacOS" "$LAB/Contents/Resources"
cp "$ROOT_DIR/dist/Jot.app/Contents/MacOS/Jot" "$LAB/Contents/MacOS/JotMotionLab"
cp -R "$ROOT_DIR/dist/Jot.app/Contents/Resources/Editor" "$LAB/Contents/Resources/Editor"
if [ -d "$ROOT_DIR/dist/Jot.app/Contents/Frameworks" ]; then
  cp -R "$ROOT_DIR/dist/Jot.app/Contents/Frameworks" "$LAB/Contents/Frameworks"
fi
cat > "$LAB/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleExecutable</key><string>JotMotionLab</string>
<key>CFBundleIdentifier</key><string>com.erikjohansson.JotMotionLab</string>
<key>CFBundleName</key><string>Jot Motion Lab</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$LAB"
/usr/bin/open -n "$LAB"
