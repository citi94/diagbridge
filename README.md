# DiagBridge

**Run VCDS natively on Apple Silicon Macs.** No virtual machine, no Windows
licence, no emulation of the main application — a self-contained Mac app
built on a [natively ported Wine](https://github.com/citi94/wine-macos-arm64).

DiagBridge contains **no Ross-Tech software** and is not affiliated with or
endorsed by Ross-Tech LLC. You need your own genuine VCDS licence and
interface (e.g. HEX-NET) — DiagBridge unpacks the official installer you
download from Ross-Tech and runs it. VCDS is a product and trademark of
Ross-Tech LLC.

## Download

Grab the latest `DiagBridge-x.y.z.dmg` from
[**Releases**](https://github.com/citi94/diagbridge/releases/latest),
open it, and drag DiagBridge to Applications. The app is signed and
notarized.

## Requirements

- Apple Silicon Mac (M1 or later) running **macOS 26 or later**
- A genuine VCDS installer from Ross-Tech, **version 25.x or later**
  (the first release with ARM64 binaries)
- A **current** Ross-Tech interface: **HEX-NET** (USB + WiFi, tested) or
  **HEX-V2** (USB). Older FTDI-based interfaces (HEX-USB+CAN, KII-USB,
  Micro-CAN, serial cables) are **not supported** — they need a Windows
  kernel driver that cannot run under Wine.
- Optional: Rosetta 2, only for the small Intel-only helper tools
  (Long Coding helper, interface config). VCDS itself runs fully native.

## First run

1. Download the VCDS installer from Ross-Tech (don't run it).
2. Open DiagBridge — it asks you to select that installer, unpacks it
   (the Windows installer program itself is never executed), and sets up
   a private Windows environment. One-time, a few minutes.
3. VCDS opens. Plug in your interface and drive.

Your scan logs land in `~/Documents/VCDS Logs` like a proper Mac app.

## Updating VCDS

Download the newer Ross-Tech installer, then hold **Option** while opening
DiagBridge — it offers to update in place. Your settings, serial and logs
are preserved.

## Troubleshooting

**No WiFi interface / no update check on first run?** When macOS asks to
allow DiagBridge to access the local network and you accept, the permission
only applies to freshly started processes — quit DiagBridge and open it
again, and the network side comes to life. (USB is unaffected.)

Session logs live in
`~/Library/Application Support/DiagBridge/logs/` — attach `session.log`
when [opening an issue](https://github.com/citi94/diagbridge/issues).

## How it works / building from source

DiagBridge is Wine 11.10 with ~40 patches making it run natively on ARM64
macOS (TEB/x18 signal handling, W^X page management, Apple Silicon address
space, a Rosetta 2 hybrid slice for i386/x86_64 helper programs, and more).
The complete Wine source is at
[citi94/wine-macos-arm64](https://github.com/citi94/wine-macos-arm64)
(LGPL 2.1+). The packaging scripts in [`app/`](app/) turn a build of that
tree into this .app — see the comments in `make-app.sh`.

## Licences

- The packaging scripts in this repository: [MIT](LICENSE)
- Wine: LGPL 2.1 or later — [complete corresponding source](https://github.com/citi94/wine-macos-arm64)
- Bundled: 7-Zip (LGPL), FreeType, GnuTLS and friends, libusb — full licence
  texts and a component manifest ship inside the app under
  `Contents/Resources/licenses/`, and the exact source tarballs for the
  LGPL libraries are attached to every release
