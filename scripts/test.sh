#!/bin/bash
# Automated tests for the native P1102 driver. Nothing is sent to the printer.
#   scripts/test.sh             test the build in build/ (runs scripts/build.sh if needed)
#   scripts/test.sh --installed also check the installed driver and queue (after install.sh)
set -uo pipefail
cd "$(dirname "$0")/.."
B=build
T=$B/test
fails=0
ok()   { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else fail "$d"; fi; }

[ -x $B/rastertop1102 ] && [ -x $B/zjsdecode ] || scripts/build.sh >/dev/null || exit 1
rm -rf $T && mkdir -p $T
FILTER=$PWD/$B/rastertop1102
PPD=$B/P1100-native.ppd

echo "== 1. ARM64 binary"
check "universal binary contains arm64" sh -c "lipo -archs $FILTER | grep -qw arm64"
check "code signature valid" codesign -v "$FILTER"
bad=$(otool -arch arm64 -L "$FILTER" | grep '^	' | awk '{print $1}' | grep -vE '^/usr/lib/|^/System/')
[ -z "$bad" ] && ok "links only system libraries (libcups, libSystem)" || fail "non-system libs: $bad"
arch -arm64 "$FILTER" >/dev/null 2>&1; [ $? -eq 1 ] && ok "arm64 slice runs natively (no Rosetta)" \
    || fail "arm64 slice does not run"

echo "== 2. PPD"
out=$(cupstestppd -W none "$PPD" 2>&1 | grep FAIL | grep -vE 'Missing (cupsFilter|APPrinterIconPath) file|: FAIL$')
[ -z "$out" ] && ok "cupstestppd: no errors (filter/icon paths checked after install)" || fail "cupstestppd: $out"
for want in '^\*DefaultPageSize: A4' '^\*ColorDevice: False' '^\*cupsManualCopies: False' \
            '^\*Product: "\(HP LaserJet Professional P1102\)"' \
            '^\*cupsFilter: "application/vnd.cups-raster 100 /Library/Printers/P1102Native/rastertop1102"' \
            '^\*Resolutions 600x400dpi/' '^\*PageSize A4/'; do
    check "PPD has ${want//\\/}" grep -qE "$want" "$PPD"
done

echo "== 3. CUPS pipeline: PDF -> Apple cgpdftoraster -> rastertop1102 (arm64) -> ZjStream"
python3 -I tests/make_testpage.py $T/page.pdf
render() { # name options... ; renders $T/page.pdf (or $T/$name.pdf when present)
    local n=$1 src=$T/page.pdf; shift
    [ -f "$T/$n.pdf" ] && src=$T/$n.pdf
    local o=(); for x in "$@"; do o+=(-o "$x"); done
    cupsfilter -p "$PPD" -m application/vnd.cups-raster "${o[@]}" "$src" > "$T/$n.ras" 2>/dev/null
}
filt() { # name copies options
    PPD=$PPD arch -arm64 "$FILTER" 1 test "$1" "$2" "$3" "$T/$1.ras" > "$T/$1.zjs" 2> "$T/$1.log"
}
decode() { # name -> $T/$name.dec.txt and $T/$name-NN-1.pgm (foo2zjs's independent decoder)
    python3 -I -c 'import sys; d=open(sys.argv[1],"rb").read(); open(sys.argv[2],"wb").write(d.replace(b"@PJL ENTER LANGUAGE=ZJS\r\n", b"@PJL ENTER LANGUAGE = ZJS\r\n", 1))' \
        "$T/$1.zjs" "$T/$1.norm"
    $B/zjsdecode -d "$T/$1" < "$T/$1.norm" > "$T/$1.dec.txt" 2>&1
}
item() { grep -a "^	$2," "$T/$1.dec.txt" | head -1 | awk '{print $2}'; }

render a4 PageSize=A4
check "Apple cgpdftoraster rendered A4 raster" test -s $T/a4.ras
filt a4 1 "PageSize=A4"
check "filter exit status 0" test -s $T/a4.zjs
check "PJL header enters ZJS" grep -aq '@PJL ENTER LANGUAGE=ZJS' $T/a4.zjs
decode a4
check "foo2zjs zjsdecode parses the stream to ZJT_END_DOC" grep -q '^ZJT_END_DOC' $T/a4.dec.txt
[ "$(item a4 ZJI_DMPAPER)" = 9 ] && ok "page header paper = A4 (DMPAPER 9)" || fail "paper code $(item a4 ZJI_DMPAPER)"
[ "$(item a4 ZJI_RESOLUTION_X)" = 600 ] && ok "600 dpi" || fail "resolution $(item a4 ZJI_RESOLUTION_X)"
[ "$(item a4 ZJI_VIDEO_BPP)" = 2 ] && ok "2 bits/pixel monochrome" || fail "bpp $(item a4 ZJI_VIDEO_BPP)"
[ "$(item a4 ZJI_DMDEFAULTSOURCE)" = 7 ] && ok "tray = auto select" || fail "tray $(item a4 ZJI_DMDEFAULTSOURCE)"
if [ -f $T/a4-01-1.pgm ]; then
    dims=$(head -c 40 $T/a4-01-1.pgm | tr -s ' \n' ' ' | cut -d' ' -f2,3)
    ok "JBIG image decoded: $dims pixels"
    python3 -I tools/pgm2png.py $T/a4-01-1.pgm $T/a4-decoded.png 8 && ok "preview: $T/a4-decoded.png"
    # the page must contain both black and white, and white top margin
    python3 -I -c '
import re, sys
d=open(sys.argv[1],"rb").read()
m=re.match(rb"P5\s+(\d+)\s+(\d+)\s+(\d+)\s", d)
w=int(m.group(1)); px=d[m.end():]; top=px[:w*40]
assert min(px)==0 and max(px)==3, "no ink or no paper"
assert set(top)=={3}, "top margin not white"' $T/a4-01-1.pgm && ok "decoded page has ink, white top margin" \
        || fail "decoded page content looks wrong"
else
    fail "JBIG image not decoded"
fi

# multiple pages
printf 'Page one\n\fPage two\n\fPage three\n' > $T/three.txt
cupsfilter -m application/pdf $T/three.txt > $T/multi.pdf 2>/dev/null
render multi PageSize=A4
filt multi 1 "PageSize=A4"; decode multi
n=$(grep -c '^ZJT_START_PAGE' $T/multi.dec.txt)
[ "$n" = 3 ] && ok "3-page PDF -> 3 ZJS pages" || fail "3-page PDF -> $n pages"

# copies: printer-side (cupsManualCopies False): one page image, DMCOPIES = 2
render copies PageSize=A4 copies=2
filt copies 2 "PageSize=A4 copies=2"; decode copies
n=$(grep -c '^ZJT_START_PAGE' $T/copies.dec.txt)
[ "$n" = 1 ] && [ "$(item copies ZJI_DMCOPIES)" = 2 ] && ok "copies=2 -> 1 page image, printer copies 2 (no N*N)" \
    || fail "copies=2 -> $n pages, DMCOPIES $(item copies ZJI_DMCOPIES)"

# Letter still works
render letter PageSize=Letter
filt letter 1 "PageSize=Letter"; decode letter
[ "$(item letter ZJI_DMPAPER)" = 1 ] && ok "Letter -> DMPAPER 1" || fail "Letter paper code $(item letter ZJI_DMPAPER)"

echo "== 4. Byte-for-byte comparison with HP's original driver"
if ls tests/ref/*.zjs >/dev/null 2>&1; then
    printf '#!/bin/sh\nexec arch -arm64 "%s" "$@"\n' "$FILTER" > $T/filter-arm64
    chmod +x $T/filter-arm64
    res=$(tests/run_tests.sh "$PWD/$T/filter-arm64" 2>&1 | tail -1)
    echo "$res" | grep -q 'failed: 0' && ok "HP reference cases: $res" || fail "HP reference cases: $res"
else
    echo "  skip  no HP references (run tests/capture_ref.sh with HPF=... while Rosetta exists)"
fi

echo "== 5. Package"
PKG=$(ls dist/*.pkg | head -1)
X=$T/pkgx; pkgutil --expand "$PKG" $X
files=$(lsbom -s $X/component.pkg/Bom 2>/dev/null)
for f in ./Library/Printers/P1102Native/rastertop1102 ./Library/Printers/P1102Native/diagnose.sh \
         "./Library/Printers/PPDs/Contents/Resources/HP LaserJet Professional P1100 Native.ppd.gz"; do
    echo "$files" | grep -qxF "$f" && ok "pkg contains $f" || fail "pkg missing $f"
done
lsbom -p MUGf $X/component.pkg/Bom | grep -E '\./Library/Printers$' | grep -q '^dr-xr-xr-x' \
    && ok "pkg keeps /Library/Printers mode r-xr-xr-x" || fail "pkg would change /Library/Printers mode"
echo "$files" | grep -q '/\._' && fail "AppleDouble files in pkg" || ok "no AppleDouble files"

echo "== 6. USB printer detection"
dev=$(/usr/libexec/cups/backend/usb 2>/dev/null | grep -i 'P1102')
[ -n "$dev" ] && ok "$(echo "$dev" | awk '{print $2}')" || fail "P1102 not found on USB"
echo "$dev" | grep -q 'CMD:ZJS' && ok "device ID reports CMD:ZJS" || fail "device ID lacks CMD:ZJS"

if [ "${1:-}" = "--installed" ]; then
    echo "== 7. Installed driver and queue"
    /Library/Printers/P1102Native/diagnose.sh --render | sed 's/^/  /'
    [ "${PIPESTATUS[0]}" -eq 0 ] && ok "diagnose.sh --render" || fail "diagnose.sh --render"
fi

echo
[ $fails -eq 0 ] && echo "ALL TESTS PASSED" || echo "$fails TEST(S) FAILED"
[ $fails -eq 0 ]
