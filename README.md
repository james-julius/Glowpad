# Glowpad

A tiny macOS app for the PS5 DualSense light bar. Turn it off, pick a solid colour, or run an animation — over Bluetooth or USB, no drivers.

**Modes:** Off · Solid · Breathe · Rainbow · Police · Fire

- Brightness and speed controls, plus the centre player LED on/off
- Kills the blue "just connected" glow
- Remembers your setting and re-applies it every time the controller connects (while Glowpad is open)
- Works with the DualSense and DualSense Edge
- One Swift file, no dependencies

## Install

Download `Glowpad.zip` from [Releases](../../releases), unzip, and drag `Glowpad.app` to Applications.

The app is ad-hoc signed, not notarized, so the first launch is blocked by Gatekeeper. Either right-click → **Open**, or run:

```sh
xattr -dr com.apple.quarantine /Applications/Glowpad.app
```

Requires macOS 13 or later (Apple Silicon or Intel).

## Build from source

Needs the Xcode command-line tools (`xcode-select --install`).

```sh
./build.sh
```

This compiles a universal binary, generates the icon if missing, signs it ad-hoc, and installs to `/Applications/Glowpad.app`.

## How it works

Glowpad finds the controller through IOKit HID (Sony VID `0x054C`) and writes DualSense output reports directly: report `0x02` over USB, and report `0x31` with a CRC32 trailer over Bluetooth. The byte layout follows the Linux kernel's `hid-playstation` driver.

## License

MIT
