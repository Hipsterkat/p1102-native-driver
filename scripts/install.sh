#!/bin/bash
# Install the native P1102 driver and add a print queue for it.
#   sudo scripts/install.sh [--queue NAME] [--no-queue]
# Leaves every existing queue and the default printer unchanged; see scripts/finalize.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
QUEUE=HP_LaserJet_P1102_Native
MAKE_QUEUE=1
while [ $# -gt 0 ]; do
    case "$1" in
        --queue) QUEUE="$2"; shift 2 ;;
        --no-queue) MAKE_QUEUE=0; shift ;;
        *) echo "usage: sudo $0 [--queue NAME] [--no-queue]" >&2; exit 2 ;;
    esac
done
die() { echo "ERROR: $*" >&2; exit 1; }

echo "== checks"
[ "$(id -u)" -eq 0 ] || die "run with sudo: sudo $0"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 11 ] || die "macOS 11 or newer required (found $(sw_vers -productVersion))"
[ -x /usr/libexec/cups/filter/cgpdftoraster ] || die "Apple's cgpdftoraster filter is missing"
PKG=$(ls dist/HP-LaserJet-P1102-Native-Driver-*.pkg 2>/dev/null | tail -1)
[ -n "$PKG" ] || die "no package in dist/ - run scripts/build.sh first (as your user, not root)"
shasum -a 256 -c "$PKG.sha256" >/dev/null || die "package checksum mismatch"
echo "  macOS $(sw_vers -productVersion) $(uname -m), package $PKG"

echo "== installing package"
installer -pkg "$PKG" -target / | sed 's/^/  /'
F=/Library/Printers/P1102Native/rastertop1102
[ "$(stat -f '%Su:%Sg %Lp' "$F")" = "root:wheel 755" ] || die "filter has wrong owner/mode"
lipo -archs "$F" | grep -qw "$(uname -m)" || die "filter lacks a $(uname -m) slice"

if [ $MAKE_QUEUE -eq 1 ]; then
    echo "== print queue $QUEUE"
    URI=$(/usr/libexec/cups/backend/usb 2>/dev/null | grep -iE 'P110[2-9]' | awk '{print $2}' | head -1)
    if [ -z "$URI" ]; then
        echo "  printer not found on USB: switch it on and re-run, or add it in System Settings"
    else
        TMPPPD=$(mktemp /tmp/p1102native.XXXXXX)
        gunzip -c "/Library/Printers/PPDs/Contents/Resources/HP LaserJet Professional P1100 Native.ppd.gz" > "$TMPPPD"
        DEFAULT_BEFORE=$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')
        /usr/sbin/lpadmin -p "$QUEUE" -v "$URI" -P "$TMPPPD" -D "HP LaserJet Professional P1102 (native)" \
            -L "USB" -o printer-is-shared=false -o printer-error-policy=retry-job \
            -o PageSize=A4 -o PageRegion=A4 -o InputSlot=Auto -E
        rm -f "$TMPPPD"
        /usr/sbin/cupsenable "$QUEUE"
        /usr/sbin/cupsaccept "$QUEUE"
        if [ -n "$DEFAULT_BEFORE" ] && [ "$(lpstat -d | sed -n 's/^system default destination: //p')" != "$DEFAULT_BEFORE" ]; then
            /usr/sbin/lpadmin -d "$DEFAULT_BEFORE"
        fi
        echo "  $QUEUE -> $URI"
        echo "  default printer unchanged: ${DEFAULT_BEFORE:-none}"
    fi
fi

echo "== diagnostics"
/Library/Printers/P1102Native/diagnose.sh --render | sed 's/^/  /'
