# Native driver for the HP LaserJet Professional P1102 on macOS (Apple Silicon)

> [!WARNING]
> **This project is vibe coded.** The driver changes, scripts and the app were written with an
> AI coding assistant (Claude) and reviewed and tested by one person, on one printer. It works
> here, but it is not professionally audited software. Read the scripts before you run them
> with `sudo`, and use it at your own risk.

A CUPS driver for the HP LaserJet Professional P1102 that runs natively on Apple Silicon.
It needs no Rosetta, no Ghostscript, no Homebrew, no kernel extensions and no SIP changes.
Built and tested on macOS 27 on an Apple M3 Pro.

**Not affiliated with HP or Apple.** This is an unofficial, independent project, not made,
endorsed or supported by HP Inc. or Apple Inc. HP and LaserJet are trademarks of HP Inc.;
Apple, macOS and Apple Silicon are trademarks of Apple Inc. The names are used only to say
which printer and system this works with.

**No warranty.** The software is provided "as is", without warranty of any kind (see
[LICENSE](LICENSE)). The authors are not liable for any damage to your computer, printer,
paper, toner or data.

## What is in this repository (and what isn't)

No HP or Apple files are included. The repository has only the source code, scripts and tests.

- `scripts/build.sh` downloads Apple's public "HP Printer Drivers 5.1.1" package from Apple
  itself, checks its SHA-256, and extracts the few HP files the driver needs into `hp/` on
  **your own Mac**. Those files and the `.pkg` built from them are for your own use only. Don't
  redistribute them.
- The byte-for-byte comparison against HP's original filter needs reference outputs captured
  with HP's filter (`tests/capture_ref.sh`). They aren't included, so `scripts/test.sh` skips
  that step until you capture them yourself.
- The **P1102 Printer** app contains no HP files, so it is published as a DMG on the
  [Releases](../../releases) page. It controls this driver's print queue, so install the driver first.

## Why the printer needs this

The P1102 is a host-based printer. Its USB device ID is
`MFG:Hewlett-Packard;MDL:HP LaserJet Professional P1102;CMD:ZJS,PJL,ACL,HTTP`.
It understands only **ZjStream** (ZJS: PJL plus JBIG-compressed bitmaps). It has no PCL or
PostScript interpreter, so the generic "HP LaserJet Series PCL 4/5" driver can never work.
HP's own macOS filter (`rastertozjs` in Apple's HP 5.1.1 package) is Intel-only and needs
Rosetta.

The P1102 keeps its firmware in flash, so no firmware upload is needed. foo2zjs confirms
this: there's no `getweb` entry for the P1102, and its model flag is `-z2`.

## How it prints

```
app -> PDF -> cgpdftoraster (Apple, native) -> rastertop1102 (this driver, arm64) -> ZjStream -> usb backend
```

`rastertop1102` reads CUPS 8-bit gray raster at 600 dpi. It halftones the page with HP's
12x12 screens to 2 bits per pixel, JBIG-encodes it (ITU-T T.82), and wraps it in ZJS page
records. It links only `/usr/lib/libcups.2.dylib` and `libSystem`.

## Sources and licensing

| Part | Source | License |
|---|---|---|
| `src/`, `ppd/`, `tools/`, `pkg/`, `tests/` | [Pawlash/p1100-macos-driver](https://github.com/Pawlash/p1100-macos-driver) @ `68a1978`, reviewed line by line, small fixes | MIT (`LICENSE.p1100-macos-driver`) |
| `third_party/foo2zjs-verify/` | foo2zjs `zjsdecode` + JBIG-KIT, **test-only** independent decoder, not installed | GPL-2.0 (`COPYING`) |
| `hp/` (not redistributable) | 2 halftone tables (24 KB), PPD and icon extracted from Apple's signed "HP Printer Drivers 5.1.1" package (SHA-256 `523836b6…9954133`, signed "Apple Software") | HP proprietary, personal use only |
| `scripts/`, `app/` | written for this project | MIT (`LICENSE`) |

Because of the HP files, **the built `.pkg` is for your own use; don't publish it.** Anyone
else can rebuild it with `scripts/build.sh`, which fetches and verifies the HP files itself.
The app's icon and test page are drawn by the app's own build scripts.

Also evaluated: [cragkhit/hp-p1102-macos](https://github.com/cragkhit/hp-p1102-macos)
(foo2zjs). It works, but it goes through PostScript and needs a ~75 MB private copy of
Ghostscript inside `/Library/Printers`, which isn't installed here. The native raster
filter is simpler and matches HP's output byte for byte.

## Build and test (no root)

```sh
scripts/build.sh        # -> build/rastertop1102 (arm64+x86_64), dist/HP-LaserJet-P1102-Native-Driver-1.3.1.pkg
scripts/test.sh         # automated tests, nothing is printed
```

`scripts/test.sh` checks:

1. **Binary.** arm64 slice present and running natively, valid ad-hoc signature, system libraries only.
2. **PPD.** `cupstestppd` passes; A4 default, 600 dpi, mono, printer-side copies, absolute filter path.
3. **Pipeline.** PDF → Apple `cgpdftoraster` → filter (arm64) → ZJS. The output is decoded by
   foo2zjs's independent `zjsdecode`, and the page header is checked: A4 = DMPAPER 9, 600 dpi,
   2 bpp, auto tray. Also checks 3 pages → 3 ZJS pages, copies=2 → one page with printer copies = 2,
   and Letter.
4. **HP comparison.** Output is byte-identical to HP's original filter on 85 cases: every paper
   size and media type, both resolutions, EconoMode, density, copies, duplex, and stress images.
   The references in `tests/ref/` were captured once with HP's binary under Rosetta
   (`HPF=… tests/capture_ref.sh`). Rosetta is never needed to print.
5. **Package.** Expected payload, `/Library/Printers` mode unchanged, no AppleDouble files.
6. **USB.** The P1102 is detected by the CUPS usb backend and reports `CMD:ZJS`.

`scripts/test.sh --installed` also runs the installed driver's self-check.

## Install (needs your admin password, typed into `sudo` yourself)

```sh
sudo scripts/install.sh      # installs the .pkg, adds queue HP_LaserJet_P1102_Native
```

This doesn't touch your existing queue `HP_LaserJet_Professional_P1102` or the default printer.
Print the test page and look at the paper:

```sh
lp -d HP_LaserJet_P1102_Native test-print/p1102-test-page.pdf
```

Expected result: sharp text from 4 to 14 pt, even hairlines, 11 gray steps getting darker one
by one, a smooth gradient, and three circles.

Once the page looks right:

```sh
sudo scripts/finalize.sh            # make the native queue the default, remove the generic-PCL queue
sudo scripts/finalize.sh --keep-old # same, but keep the old queue
```

The old queue's PPD and settings are saved in `backup/`.

## Print options

In the print dialog under "Printer Features":

- Paper size: A4 by default, plus Letter, Legal, A5, A6, B5, envelopes and custom sizes.
- Media type, Print Density 1–5, EconoMode, and Jam Recovery.
- Resolution: FastRes 600 (default) or FastRes 1200.
- Paper source: Automatically Select (default) or Manual Feed.
- Copies: the printer makes them.
- Two-sided printing: manual duplex. The backs print first, then the printer pauses; put the
  stack back printed side down.

## Diagnostics

```sh
/Library/Printers/P1102Native/diagnose.sh            # system, driver, USB, queues, CUPS log
/Library/Printers/P1102Native/diagnose.sh --render   # also renders a page through the filter (no printing)
```

For a failing job, turn on debug logging, print, and read the log:

```sh
cupsctl --debug-logging; lp -d HP_LaserJet_P1102_Native test-print/p1102-test-page.pdf
grep -a rastertop1102 /var/log/cups/error_log | tail -40; cupsctl --no-debug-logging
```

Common problems:

- **The printer blinks green and nothing prints.** A half-received job is stuck. Switch the
  printer off and on.
- **Red light after running out of paper.** Load paper and power-cycle the printer. The queue
  retries the job every 30 s.
- **Not found on USB.** Check power and the hub, then run `/usr/libexec/cups/backend/usb`.

## Printer app

`app/` contains **P1102 Printer**, a small SwiftUI utility. It shows connection and status,
offers quick print and test-page actions, holds your print settings, and manages the queue,
all on this driver's CUPS queue. Build it with `app/build.sh --install`. See
[app/README.md](app/README.md).

A ready-made DMG is on the [Releases](../../releases) page. It's signed only ad hoc (no Apple
developer certificate), so the first time you open it macOS blocks it. Open it once, then go to
**System Settings › Privacy & Security** and click **Open Anyway**.

## Uninstall

```sh
sudo scripts/uninstall.sh    # removes the queue and driver, restores the old queue from backup/ if it was removed
```

## Layout

```
src/            rastertop1102.c (filter), papers.h
ppd/            make_ppd.py (HP PPD -> native PPD)
pkg/            postinstall + helper scripts installed to /Library/Printers/P1102Native
scripts/        build.sh test.sh install.sh finalize.sh uninstall.sh diagnose.sh
tools/          fetch_hp_files.sh gen_tables.py mkpayload.py rastool.c zjsdump.py pgm2png.py
tests/          85 cases; HP reference outputs (ref/) and rasters (ras/) are created locally
third_party/    foo2zjs zjsdecode (test-only)
app/            P1102 Printer (SwiftUI utility)
test-print/     one-page physical test PDF
```

Created locally and kept out of git: `hp/` (HP files, not redistributable), `build/`,
`dist/` (the .pkg), `backup/` (your original queue's PPD and settings), `tests/ref/`,
`tests/ras/`, `tests/in/*.pdf`.
