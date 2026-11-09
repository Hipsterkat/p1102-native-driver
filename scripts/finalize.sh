#!/bin/bash
# After a confirmed good physical print: make the native queue the default printer and
# remove the old queue that uses the generic "HP LaserJet Series PCL 4/5" driver.
#   sudo scripts/finalize.sh [--keep-old]
# The old queue's PPD and settings are in backup/; scripts/uninstall.sh restores them.
set -euo pipefail
cd "$(dirname "$0")/.."
NEW=HP_LaserJet_P1102_Native
OLD=HP_LaserJet_Professional_P1102
[ "$(id -u)" -eq 0 ] || { echo "run with sudo: sudo $0" >&2; exit 1; }
lpstat -p "$NEW" >/dev/null 2>&1 || { echo "queue $NEW does not exist - run scripts/install.sh" >&2; exit 1; }

/usr/sbin/lpadmin -d "$NEW"
echo "default printer: $NEW"
if [ "${1:-}" != "--keep-old" ] && lpstat -p "$OLD" >/dev/null 2>&1; then
    if grep -q 'HP LaserJet Series PCL 4/5' "/etc/cups/ppd/$OLD.ppd" 2>/dev/null; then
        [ -f "backup/$OLD.ppd" ] || cp "/etc/cups/ppd/$OLD.ppd" "backup/$OLD.ppd"
        /usr/sbin/lpadmin -x "$OLD"
        echo "removed old generic-PCL queue $OLD (backup in backup/$OLD.ppd)"
    else
        echo "kept $OLD: it does not use the generic PCL driver"
    fi
fi
lpstat -d -p
