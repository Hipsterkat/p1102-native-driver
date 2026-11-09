#!/bin/bash
# Build the native HP LaserJet Professional P1102 driver: CUPS filter, PPD, installer package.
#   scripts/build.sh            build everything into build/ and dist/
#   scripts/build.sh --clean    remove build/ and dist/ first
# Adapted from https://github.com/Pawlash/p1100-macos-driver (MIT, commit 68a1978).
# Needs only the Xcode Command Line Tools. No Homebrew, no Ghostscript, no Rosetta.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=1.3.1
ID=local.p1102native.driver
B=build
HP=hp

[ "${1:-}" = "--clean" ] && rm -rf "$B" dist
mkdir -p "$B" dist

# --- HP files (halftone screens, PPD, icon) --------------------------------------------
# Extracted from Apple's signed "HP Printer Drivers 5.1.1" package; never redistributed.
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
need() { # expected-sha file
    [ -f "$2" ] && [ "$(sha "$2")" = "$1" ]
}
if ! need efa8a8e8c49da4f6383e20b8cd3187327f4be325dc888956aa631d61bed44cce "$HP/sdtahs10.bin" ||
   ! need bee7e551104522f1ccb70f9d1808103d203bc9d97c4f2d1d38e6ffda3d6e2e51 "$HP/sdtahr10.bin" ||
   ! need 44e5ccb4e16a65fdc0f85fb50e391c3ea9cd3131abc1b6ebcf5acec206478d4c "$HP/hp1100.ppd.gz" ||
   ! need 4e57aeadfc9fd130ddadd2b9049c78f05a4ab35cd725f55db016cd5c1d4a5b50 "$HP/hp1100.icns"; then
    echo "== HP files missing or modified: fetching from Apple (584 MB, one time)"
    tools/fetch_hp_files.sh "$HP"
fi

echo "== tables"
python3 -I tools/gen_tables.py "$HP" "$B/screens.h"

echo "== filter (universal: arm64 + x86_64, links only system libcups)"
clang -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
    -I"$B" -o "$B/rastertop1102" src/rastertop1102.c -lcups
codesign -s - -f "$B/rastertop1102"
lipo -archs "$B/rastertop1102"

echo "== test tools"
clang -O2 -Wall -Wno-deprecated-declarations -o "$B/rastool" tools/rastool.c -lcups
# foo2zjs's independent ZjStream/JBIG decoder (GPL-2.0, test use only, not packaged)
clang -O2 -w -o "$B/zjsdecode" third_party/foo2zjs-verify/zjsdecode.c \
    third_party/foo2zjs-verify/jbig.c third_party/foo2zjs-verify/jbig_ar.c

echo "== PPD"
python3 -I ppd/make_ppd.py "$HP/hp1100.ppd.gz" "$B/P1100-native.ppd"
cupstestppd -W none "$B/P1100-native.ppd" 2>&1 | grep -E 'FAIL' \
    | grep -vE 'Missing (cupsFilter|APPrinterIconPath) file|^.*: FAIL$' && exit 1 || true

echo "== package"
ROOT="$B/root"
rm -rf "$ROOT"
install -d -m 755 "$ROOT/Library/Printers/P1102Native" "$ROOT/Library/Printers/PPDs/Contents/Resources"
install -m 755 "$B/rastertop1102" "$ROOT/Library/Printers/P1102Native/"
install -m 644 "$HP/hp1100.icns" "$ROOT/Library/Printers/P1102Native/printer.icns"
install -m 644 pkg/README.txt "$ROOT/Library/Printers/P1102Native/"
for s in use-hp-driver.sh use-native-driver.sh remove-hp-driver.sh uninstall.sh; do
    install -m 755 "pkg/support/$s" "$ROOT/Library/Printers/P1102Native/"
done
install -m 755 scripts/diagnose.sh "$ROOT/Library/Printers/P1102Native/diagnose.sh"
gzip -9 -n -c "$B/P1100-native.ppd" \
    > "$ROOT/Library/Printers/PPDs/Contents/Resources/HP LaserJet Professional P1100 Native.ppd.gz"
chmod 644 "$ROOT/Library/Printers/PPDs/Contents/Resources/"*.gz
chmod 755 pkg/scripts/postinstall
xattr -cr "$ROOT"

pkgbuild --root "$ROOT" --scripts pkg/scripts --identifier "$ID" --version "$VERSION" \
    --install-location / --ownership recommended "$B/component-raw.pkg" >/dev/null 2>&1
# pkgbuild stores extended attributes as AppleDouble "._" files and imposes its own
# directory modes; rebuild Payload + Bom so installing never changes /Library/Printers.
X="$B/component-x"
rm -rf "$X" "$B/component.pkg"
pkgutil --expand "$B/component-raw.pkg" "$X"
python3 -I tools/mkpayload.py "$ROOT" "$B/payload.mtree" "$B/payload.bomlist" >/dev/null
COPYFILE_DISABLE=1 tar --format odc --no-xattrs --no-mac-metadata -cf - "@$B/payload.mtree" \
    | gzip -9 > "$X/Payload"
rm -f "$X/Bom"
mkbom -i "$B/payload.bomlist" "$X/Bom"
nfiles=$(wc -l < "$B/payload.bomlist" | tr -d ' ')
kbytes=$(( ($(gunzip -c "$X/Payload" | wc -c) + 1023) / 1024 ))
sed -i '' -E "s/numberOfFiles=\"[0-9]+\"/numberOfFiles=\"$nfiles\"/; s/installKBytes=\"[0-9]+\"/installKBytes=\"$kbytes\"/" "$X/PackageInfo"
pkgutil --flatten "$X" "$B/component.pkg"
if lsbom -s "$X/Bom" | grep -q '/\._'; then echo "AppleDouble files in package" >&2; exit 1; fi
cat > "$B/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>HP LaserJet P1102 Native Driver $VERSION</title>
    <readme file="README.txt" mime-type="text/plain"/>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <volume-check><allowed-os-versions><os-version min="11.0"/></allowed-os-versions></volume-check>
    <domains enable_localSystem="true"/>
    <choices-outline><line choice="default"/></choices-outline>
    <choice id="default" title="HP LaserJet P1102 Native Driver"><pkg-ref id="$ID"/></choice>
    <pkg-ref id="$ID" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
EOF
mkdir -p "$B/resources"
cp pkg/README.txt "$B/resources/"
PKG="dist/HP-LaserJet-P1102-Native-Driver-$VERSION.pkg"
productbuild --distribution "$B/distribution.xml" --resources "$B/resources" \
    --package-path "$B" "$PKG" >/dev/null
shasum -a 256 "$PKG" > "$PKG.sha256"
ls -la dist/
