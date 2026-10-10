# Keymap for Mac

An offline Mac app for configuring the Keychron V3 Knob RGB (ANSI) keyboard: keys, knob, macros and lighting. No browser, no network.

## What it does
Keys on all four layers, the knob, macros, lighting (standard, per-key and Mix RGB), debounce, Snap Click, key test, and backup/restore.
Nothing is written to the keyboard until you press Apply; a backup is saved first and every write is read back.
Firmware update is deliberately not included: the app shows the installed firmware version at the bottom of the sidebar.
The Help menu opens the Quick Start Guide, the User Manual and the disassembly guide in a built-in viewer. The PDFs are Keychron's, so they are kept out of git: put them in a local `Help/` folder (`quick-start-guide.pdf`, `user-manual.pdf`, `disassembly-guide.pdf`) and `scripts/make-app.sh` bundles them.
Appearance (match system, light or dark) is the circle button beside Revert and Apply.

## Build and run
Needs macOS 26 or later and the Swift command line tools.

```bash
scripts/make-app.sh        # builds dist/Keymap.app
scripts/make-app.sh --dmg  # also builds dist/Keymap.dmg
swift test               # all tests, no keyboard needed
```

Allow Input Monitoring when macOS asks (the app talks to the keyboard over raw HID).

## Layout
- `Sources/ViaKit`: protocol, device, config, apply engine (no UI)
- `Sources/KeymapCore`: app model and SwiftUI views
- `Sources/KeymapApp`: the app

## Notes and credits
- Not affiliated with or endorsed by Keychron. "Keychron" and "Keychron V3" are trademarks of their owner and are used only to say which keyboard this works with.
- The app talks to the keyboard with the open VIA protocol plus Keychron's extra commands. It writes to your keyboard's settings: use it at your own risk. A backup is saved first, but check your keyboard's warranty terms.
- The key layout in `Sources/ViaKit/Resources/v3_ansi_encoder.json` comes from the keyboard definition in [QMK Firmware](https://github.com/qmk/qmk_firmware) (the V3 ANSI encoder definition).
- Keychron's PDF guides are not included.

## Licence
MIT. See `LICENSE`.
