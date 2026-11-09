#!/bin/bash
# Build "P1102 Printer.app" (SwiftUI, arm64) with the Command Line Tools; Xcode not needed.
#   app/build.sh             build into app/build/ and package into dist/
#   app/build.sh --install   also copy the app to /Applications (no root for admin users)
#   app/build.sh --test      also run the app's CUPS self-test (holds and cancels a job; prints nothing)
set -euo pipefail
cd "$(dirname "$0")"
NAME="P1102 Printer"
EXE=P1102Printer
VERSION=1.0.0
ID=local.p1102native.printer-utility
MIN_OS=15.0
B=build
APP="$B/$NAME.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" ../dist

echo "== compile (arm64, macOS $MIN_OS+, Liquid Glass on macOS 26+)"
swiftc -O -swift-version 5 -target "arm64-apple-macos$MIN_OS" -parse-as-library \
    -I Sources/CCups -framework IOKit \
    -o "$APP/Contents/MacOS/$EXE" Sources/P1102Utility/*.swift

echo "== resources"
[ -f ../test-print/p1102-test-page.pdf ] || python3 -I ../tests/make_testpage.py ../test-print/p1102-test-page.pdf
cp ../test-print/p1102-test-page.pdf "$APP/Contents/Resources/TestPage.pdf"
if [ ! -f "$B/AppIcon.icns" ] || [ Tools/MakeIcon.swift -nt "$B/AppIcon.icns" ]; then
    rm -rf "$B/AppIcon.iconset"
    swift Tools/MakeIcon.swift "$B/AppIcon.iconset"
    iconutil -c icns -o "$B/AppIcon.icns" "$B/AppIcon.iconset"
fi
cp "$B/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$NAME</string>
    <key>CFBundleDisplayName</key><string>$NAME</string>
    <key>CFBundleIdentifier</key><string>$ID</string>
    <key>CFBundleExecutable</key><string>$EXE</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>© 2026 Hipsterkat. MIT license. Not affiliated with or endorsed by HP Inc.</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "== sign (ad hoc)"
codesign --force --sign - --options runtime --timestamp=none "$APP"
codesign --verify --strict "$APP"
lipo -archs "$APP/Contents/MacOS/$EXE"

echo "== package"
rm -f "../dist/$NAME.zip"
ditto -c -k --keepParent "$APP" "../dist/$NAME.zip"
ls -la "../dist/$NAME.zip"

for arg in "$@"; do
    case "$arg" in
        --test) "$APP/Contents/MacOS/$EXE" --selftest ;;
        --install)
            echo "== install to /Applications"
            rm -rf "/Applications/$NAME.app"
            ditto "$APP" "/Applications/$NAME.app"
            echo "installed /Applications/$NAME.app" ;;
    esac
done
