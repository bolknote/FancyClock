# FancyClock

FancyClock is a Flutter app for square Android displays. It shows local time as **HH:mm** (updates each minute). Each digit uses a random Google Fonts-derived outline asset plus a contrasting color. The background switches between near-black and milk white using rear-camera luminance with hysteresis so bright rooms get a softer skin without flicker.

<img width="1000" height="562" src="https://github.com/user-attachments/assets/f3d0a310-642a-4f1e-809d-9cac5f094a90" />


## Features

- **Random typography**: many Google Fonts families converted to digit outlines, one random font per digit each minute.
- **Contrast**: digit colors are chosen for readability against the current background.
- **Ambient-aware skin**: rear camera estimates brightness; **dark** vs **milk** background with stable thresholds.
- **Fullscreen** immersive UI, portrait orientation.

## Requirements

- [Flutter](https://flutter.dev/) (stable channel)
- Android SDK / device with USB debugging for `flutter run` / `adb`

Optional: Python 3 + [fonttools](https://github.com/fonttools/fonttools) to regenerate font subsets and digit outlines (see below).

## Getting started

```bash
flutter pub get
```

Generated font binaries under `assets/fonts/` and digit outline JSON files under `assets/glyphs/` are not committed. After cloning, run the font pipeline below or supply your own subset `.ttf` files matching `assets/fonts_manifest.json`, then extract glyph outlines.

### Generate font subsets

Walks alphabetically sorted families from Google Fonts metadata until *N* usable digit-font subsets are written. Fonts known to render helpers, bars, or other non-digit shapes are skipped. Each accepted font is subset to `U+0030–U+0039`, written under `assets/fonts/`, and listed in `assets/fonts_manifest.json`.

```bash
python3 -m venv scripts/.venv
scripts/.venv/bin/pip install -r scripts/requirements-fonts.txt
scripts/.venv/bin/python scripts/fetch_fonts.py --limit 1500
scripts/.venv/bin/python scripts/prune_fonts.py
scripts/.venv/bin/python scripts/extract_glyphs.py
```

## Run on Android

```bash
flutter run
# or
flutter build apk --release
```

Grant **camera** permission when prompted so ambient background switching works.

## Project layout

| Path | Purpose |
|------|---------|
| `lib/main.dart` | UI, clock logic, glyph loading, ambient light |
| `scripts/fetch_fonts.py` | Download & subset fonts, emit manifest |
| `scripts/prune_fonts.py` | Remove generated fonts not referenced by the manifest |
| `scripts/extract_glyphs.py` | Convert digit glyphs from generated fonts to JSON outlines |
| `assets/fonts_manifest.json` | List of subset font filenames |
| `assets/fonts/` | Subset `.ttf` files (generated; ignored by git) |
| `assets/glyphs/` | Digit outline JSON files (generated; ignored by git) |

## License

This project is licensed under the [MIT License](LICENSE).

Copyright © 2026 Evgeny Stepanischev.
