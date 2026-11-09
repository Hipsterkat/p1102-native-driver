#!/bin/bash
# Remove the native P1102 driver and its queue; restore the original generic queue if it
# was removed by finalize.sh.
#   sudo scripts/uninstall.sh
set -uo pipefail
cd "$(dirname "$0")/.."
NEW=HP_LaserJet_P1102_Native
OLD=HP_LaserJet_Professional_P1102
[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }

if lpstat -p "$NEW" >/dev/null 2>&1; then
    /usr/sbin/lpadmin -x "$NEW" && echo "removed queue $NEW"
fi
if ! lpstat -p "$OLD" >/dev/null 2>&1 && [ -f "backup/$OLD.ppd" ]; then
    URI=$(sed -n "s/^device for $OLD: //p" "backup/$OLD.settings.txt")
    /usr/sbin/lpadmin -p "$OLD" -v "$URI" -P "backup/$OLD.ppd" -D "HP LaserJet Professional P1102" \
        -L Macbook -E && echo "restored queue $OLD"
fi
lpstat -p "$OLD" >/dev/null 2>&1 && [ -z "$(lpstat -d 2>/dev/null | sed -n 's/^system default destination: //p')" ] \
    && /usr/sbin/lpadmin -d "$OLD"
if [ -x /Library/Printers/P1102Native/uninstall.sh ]; then
    /Library/Printers/P1102Native/uninstall.sh
else
    echo "driver files not installed"
fi
