# Aula F75 Max Bar

Independent macOS menu bar utility for the Aula F75 Max keyboard.

First known public macOS utility for F75 Max battery status, RGB control, performance settings, Game Mode, and 128 x 128 screen image/GIF upload.

This project is not affiliated with Aula, Epomaker, or the official Windows driver. It does not include official driver binaries, extracted assets, or vendor artwork.

## Features

- Menu bar battery status for the 2.4 GHz dongle
- Connection status for 2.4 GHz and wired USB modes
- RGB lighting modes, brightness, speed, direction, colorful/fixed color
- Screen image/GIF upload in wired USB mode
- Screen time sync in wired USB mode
- Key response level and sleep timeout controls
- Game Mode toggle
- Launch at Login

<img width="351" height="348" alt="Screenshot 2026-05-07 at 1 24 28 pm" src="https://github.com/user-attachments/assets/84729a99-90f4-4394-9c5a-6cf29f37ca9f" />


## Requirements

- macOS 14 or newer
- Xcode Command Line Tools
- Aula F75 Max keyboard
- Input Monitoring permission for raw HID acknowledgements

Screen uploads require wired USB mode. Battery, RGB, performance, and Game Mode use the 2.4 GHz dongle path.

## Compatibility

Tested hardware:

- Aula F75 Max with 2.4 GHz dongle `05AC:024F`
- Aula F75 Max wired USB mode `0C45:800A`

Other F75 variants may work only if they expose the same HID IDs and vendor endpoints. Variants with different USB IDs, no 128 x 128 screen, or a different screen protocol are currently unsupported until someone captures and validates their HID reports.

## Reverse Engineering

Protocol support was independently reverse engineered on owned hardware by inspecting macOS USB/HID descriptors, observing the official Windows driver as a black box, and validating small HID reports on the keyboard.

## Current Limits

- Bluetooth control is not implemented.
- Screen upload targets the keyboard's image/GIF screen slot, not the boot animation.
- Releases are locally/ad-hoc signed unless a maintainer notarizes a build.
- Other F75 variants need separate HID captures before they can be marked supported.

## Contributing Variant Support

Reports for other F75 variants are welcome. Useful details include the exact model name, USB product IDs in wired and 2.4 GHz modes, macOS version, which endpoints appear in IORegistry, and which features were tested.

## Build

```sh
make all
open build/AulaF75Bar.app
```

The build creates `build/AulaF75Bar.app` and bundles the `F75Probe` helper inside the app.

## Privacy

The app reads and writes local HID reports for the keyboard. It does not send telemetry or network requests.

## License

MIT. See `LICENSE`.
