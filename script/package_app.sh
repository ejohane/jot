#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${JOT_CONFIGURATION:-release}"
identity="${JOT_CODESIGN_IDENTITY:--}"
version="${JOT_VERSION:-0.1.0}"
build="${JOT_BUILD:-0}"
app="dist/Jot.app"
sparkle=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

if [[ "${JOT_DISTRIBUTION:-0}" == 1 ]]; then
  [[ "$identity" == 'Developer ID Application:'* ]] || { echo 'Developer ID Application identity required.' >&2; exit 1; }
  [[ "$build" =~ ^[1-9][0-9]*$ ]] || { echo 'A positive release build number is required.' >&2; exit 1; }
fi

[[ -d Web/node_modules ]] || npm --prefix Web ci
npm --prefix Web run build
swift package resolve --force-resolved-versions
mkdir -p dist
if [[ "${JOT_UNIVERSAL:-0}" == 1 ]]; then
  for arch in arm64 x86_64; do
    swift build -c "$configuration" --arch "$arch" --product Jot --force-resolved-versions
    bin_dir="$(swift build -c "$configuration" --arch "$arch" --show-bin-path)"
    cp "$bin_dir/Jot" "dist/Jot-$arch"
  done
  lipo -create dist/Jot-arm64 dist/Jot-x86_64 -output dist/Jot-binary
else
  swift build -c "$configuration" --product Jot --force-resolved-versions
  bin_dir="$(swift build -c "$configuration" --show-bin-path)"
  cp "$bin_dir/Jot" dist/Jot-binary
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Editor" "$app/Contents/Frameworks"
cp dist/Jot-binary "$app/Contents/MacOS/Jot"
ditto Web/dist "$app/Contents/Resources/Editor"
ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"
python3 - "$app" "$version" "$build" "${JOT_DISTRIBUTION:-0}" <<'PY'
import pathlib, plistlib, re, sys
app, version, build, distribution = sys.argv[1:]
if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not build.isdecimal():
    raise SystemExit('Expected a numeric three-part version and numeric build.')
public_key = pathlib.Path('Config/sparkle-public-key.txt').read_text().strip()
plist = {
    'CFBundleExecutable': 'Jot', 'CFBundleIdentifier': 'com.erikjohansson.Jot',
    'CFBundleName': 'Jot', 'CFBundleDisplayName': 'Jot', 'CFBundlePackageType': 'APPL',
    'CFBundleShortVersionString': version, 'CFBundleVersion': build,
    'LSMinimumSystemVersion': '14.0', 'LSUIElement': True,
    'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication',
    'JotUpdatesEnabled': distribution == '1',
    'SUFeedURL': 'https://github.com/ejohane/jot/releases/latest/download/appcast.xml',
    'SUPublicEDKey': public_key, 'SUEnableAutomaticChecks': True,
    'SUScheduledCheckInterval': 3600, 'SUAutomaticallyUpdate': False,
    'SUAllowsAutomaticUpdates': False, 'SUEnableSystemProfiling': False,
}
with open(f'{app}/Contents/Info.plist', 'wb') as output:
    plistlib.dump(plist, output)
PY

xattr -cr "$app"
# Sign nested executables and bundles inside out; do not use --deep to sign.
sign_args=(--force --sign "$identity")
if [[ "$identity" != '-' ]]; then
  sign_args+=(--options runtime --timestamp)
fi
framework="$app/Contents/Frameworks/Sparkle.framework"
for nested in "$framework"/Versions/B/XPCServices/*.xpc \
  "$framework/Versions/B/Updater.app" "$framework/Versions/B/Autoupdate"; do
  codesign "${sign_args[@]}" "$nested"
done
codesign "${sign_args[@]}" "$framework"
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"
echo "Built $app ($version, build $build)"
