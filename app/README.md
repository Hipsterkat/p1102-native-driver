# P1102 Printer: a small macOS utility for the native P1102 driver

A single-window SwiftUI app that lets you check the printer, adjust print options, and print
a document in a couple of clicks. On macOS 26 and later it uses Liquid Glass (`glassEffect`,
`GlassEffectContainer`, `.glass` buttons); on macOS 15 it falls back to standard materials.
The window is translucent and follows Light and Dark Mode. Built for Apple Silicon (arm64).

## What it does

| Area | Details |
|---|---|
| Overview | Connection (USB, read from IOKit: HP vendor 0x03F0, "P110x" product); status from CUPS: Ready / Printing / Offline / Error, with the printer's own message (paper out, jam, door open…); the queue in use; the driver (native version, or a warning for the old generic PCL queue) |
| Quick actions | **Print…** (file picker: PDF, images, plain text; ⌘P) · **Test Page** · **Queue** (opens the macOS queue window if it exists, otherwise Printers & Scanners) · **Refresh** (⌘R). The app also refreshes every 2 s on its own |
| Settings | Paper (A4/Letter), Quality (FastRes 600/1200), Copies, Pages (e.g. `1-3, 5`). Under Advanced: Density 1–5, EconoMode, manual two-sided printing. Saved in the app's preferences (`UserDefaults`). Each control is enabled only if the queue's PPD supports it |
| Print queue | Active jobs plus the 5 most recent finished ones, with state, the printer's message, and a progress bar from the driver ("Printing page 1, 40%"). **Cancel** active jobs; **retry** held, stopped, canceled or failed jobs (CUPS Release-Job / Restart-Job) |

It never makes anything up: there's no toner or page-count display, because this printer
doesn't report them over USB.

## How it talks to the printer

- **CUPS:** through the system `libcups` (`Sources/CCups` module map): IPP Get-Printer-Attributes,
  Get-Jobs, Restart-Job and Release-Job, plus `cupsPrintFile2` and `cupsCancelJob2`. Jobs go to the
  same queue and native driver as every other app, so no administrator rights are needed.
- **USB:** IOKit registry lookup, read-only.
- **Structure (MVVM):** `PrinterService` (an actor; all blocking CUPS and IOKit calls) →
  `PrinterViewModel` (`@MainActor`, publishes snapshots, handles actions) → SwiftUI views
  (`ContentView.swift`, with the glass helpers in `Glass.swift`).

## Build, test, install

Needs the Xcode Command Line Tools only:

```sh
app/build.sh             # -> app/build/P1102 Printer.app and dist/P1102 Printer.zip
app/build.sh --test      # also run the CUPS self-test
app/build.sh --install   # also copy the app to /Applications
```

The self-test (`"P1102 Printer.app/Contents/MacOS/P1102Printer" --selftest`):

- checks the queue, driver, PPD options and option mapping;
- submits a test page **on hold**, so it never prints;
- checks that the job is listed, cancels it, and restarts it (only while the printer is
  disconnected, so nothing can print);
- cancels it again.

Notes:
- The app is ad-hoc signed. If Gatekeeper complains on another Mac, right-click it and choose Open.
- `@State` isn't used: in this SDK it's a macro whose plugin ships only with Xcode.
  View state uses `@AppStorage` instead.

## Files

```
app/Sources/CCups/            module map exposing <cups/cups.h> to Swift
app/Sources/P1102Utility/     App, Models, PrinterService, PrinterViewModel, ContentView, Glass, SelfTest
app/Tools/MakeIcon.swift      draws the app icon (printer glyph on a frosted squircle)
app/build.sh                  compile, bundle, icon, sign, zip, optional test/install
```
