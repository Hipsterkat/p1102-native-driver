#!/bin/bash
# Diagnostics for the native HP LaserJet P1102 driver. Read-only, no root needed.
#   diagnose.sh            check the system, driver, queues and printer
#   diagnose.sh --render   also render a test page through the installed filter (no printing)
# Exit status: 0 = all checks passed, 1 = at least one FAIL.
set -u
DIR=/Library/Printers/P1102Native
FILTER=$DIR/rastertop1102
PPDGZ="/Library/Printers/PPDs/Contents/Resources/HP LaserJet Professional P1100 Native.ppd.gz"
fails=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }

echo "== system"
ok "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(uname -m)"
ok "CUPS $(cups-config --version 2>/dev/null || echo '?')"
[ -x /usr/libexec/cups/filter/cgpdftoraster ] && ok "Apple cgpdftoraster present" \
    || fail "cgpdftoraster missing (macOS PDF -> raster filter)"
if arch -x86_64 /usr/bin/true 2>/dev/null; then ok "Rosetta installed (not needed by this driver)"
else ok "Rosetta not installed (not needed by this driver)"; fi

echo "== driver files"
if [ -x "$FILTER" ]; then
    archs=$(lipo -archs "$FILTER" 2>/dev/null)
    case " $archs " in *" $(uname -m) "*) ok "filter $FILTER ($archs)" ;;
        *) fail "filter has no $(uname -m) slice ($archs)" ;; esac
    perm=$(stat -f '%Su:%Sg %Lp' "$FILTER")
    [ "$perm" = "root:wheel 755" ] && ok "filter owner/mode $perm" \
        || fail "filter owner/mode $perm (CUPS requires root:wheel 755)"
    codesign -v "$FILTER" 2>/dev/null && ok "filter code signature valid" \
        || fail "filter code signature invalid (Apple Silicon refuses to run it)"
    bad=$(otool -arch "$(uname -m)" -L "$FILTER" | grep '^	' | awk '{print $1}' \
        | grep -vE '^/usr/lib/|^/System/' || true)
    [ -z "$bad" ] && ok "filter links only system libraries" || fail "non-system libraries: $bad"
else
    fail "filter not installed ($FILTER)"
fi
[ -f "$PPDGZ" ] && ok "PPD installed" || fail "PPD not installed ($PPDGZ)"
pkgutil --pkg-info local.p1102native.driver >/dev/null 2>&1 \
    && ok "package receipt $(pkgutil --pkg-info local.p1102native.driver | awk '/^version/ {print $2}')" \
    || warn "no package receipt (local.p1102native.driver)"

echo "== printer on USB"
dev=$(/usr/libexec/cups/backend/usb 2>/dev/null | grep -iE 'P110[2-9]' | head -1)
if [ -n "$dev" ]; then
    uri=$(echo "$dev" | awk '{print $2}')
    ok "$uri"
    echo "$dev" | grep -q 'CMD:ZJS' && ok "device speaks ZjStream (CMD:ZJS)" || warn "no CMD:ZJS in device ID"
else
    fail "no P1100-series printer found by the CUPS usb backend (power, cable, hub?)"
fi

echo "== queues"
native=0
for f in /etc/cups/ppd/*.ppd; do
    [ -f "$f" ] || continue
    q=$(basename "$f" .ppd)
    model=$(sed -n 's/^\*ModelName: *"\(.*\)"/\1/p' "$f" | head -1)
    filt=$(sed -n 's/^\*cupsFilter2\{0,1\}: *"\(.*\)"/\1/p' "$f" | grep raster | head -1)
    turi=$(lpstat -v "$q" 2>/dev/null | sed 's/^device for [^:]*: //')
    state=$(lpstat -p "$q" 2>/dev/null | head -1)
    if grep -q "$FILTER" "$f"; then
        native=$((native + 1))
        ok "$q: native driver ($model)"
        [ -n "${uri:-}" ] && [ "$turi" != "$uri" ] && warn "$q: URI $turi differs from detected $uri"
        echo "$state" | grep -q disabled && fail "$q: queue is disabled ($state)"
    elif echo "$turi" | grep -qi 'P110[2-9]'; then
        warn "$q: P1102 queue NOT using the native driver ($model; ${filt:-no raster filter})"
    fi
done
[ $native -gt 0 ] || fail "no queue uses the native driver"
def=$(lpstat -d 2>/dev/null | sed 's/.*: //')
ok "default printer: ${def:-none}"

echo "== recent CUPS log for P1102 queues"
grep -aE 'P1102|rastertop1102' /var/log/cups/error_log 2>/dev/null | tail -n 8 | sed 's/^/        /' \
    || true

if [ "${1:-}" = "--render" ] && [ -x "$FILTER" ] && [ -f "$PPDGZ" ]; then
    echo "== render test (no printing)"
    T=$(mktemp -d "${TMPDIR:-/tmp}/p1102diag.XXXXXX")
    gunzip -c "$PPDGZ" > "$T/p.ppd"
    # not starting with "P1": that is the PBM image signature and makes CUPS treat it as an image
    printf 'Diagnostic page for the native HP LaserJet P1102 driver\n' > "$T/t.txt"
    if cupsfilter -i text/plain -p "$T/p.ppd" -m application/vnd.cups-raster -o PageSize=A4 "$T/t.txt" \
           > "$T/t.ras" 2>"$T/cf.log" && [ -s "$T/t.ras" ]; then
        ok "macOS rendered the page to CUPS raster ($(wc -c < "$T/t.ras" | tr -d ' ') bytes)"
        if PPD="$T/p.ppd" "$FILTER" 1 diag diag 1 "" "$T/t.ras" > "$T/t.zjs" 2>"$T/f.log" &&
           head -c 600 "$T/t.zjs" | grep -aq 'ENTER LANGUAGE=ZJS' && grep -aq 'JZJZ' "$T/t.zjs"; then
            ok "filter produced $(wc -c < "$T/t.zjs" | tr -d ' ') bytes of ZjStream"
        else
            fail "filter did not produce ZjStream:"; sed 's/^/        /' "$T/f.log"
        fi
    else
        fail "cupsfilter could not render a raster:"; tail -5 "$T/cf.log" | sed 's/^/        /'
    fi
    rm -rf "$T"
fi

echo
[ $fails -eq 0 ] && echo "All checks passed." || echo "$fails check(s) failed."
[ $fails -eq 0 ]
