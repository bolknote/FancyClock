# FancyClock

FancyClock is a Flutter app for square Android displays. It shows local time as **HH:mm** (updates each minute). Each digit uses a random subset font from a bundled pool (digits `0–9` only) plus a contrasting color. The background switches between near-black and milk white using rear-camera luminance with hysteresis so bright rooms get a softer skin without flicker.

## Features

- **Random typography**: many Google Fonts families (subset to digits only), one random font per digit each minute.
- **Contrast**: digit colors are chosen for readability against the current background.
- **Ambient-aware skin**: rear camera estimates brightness; **dark** vs **milk** background with stable thresholds.
- **Fullscreen** immersive UI, portrait orientation.

## Requirements

- [Flutter](https://flutter.dev/) (stable channel)
- Android SDK / device with USB debugging for `flutter run` / `adb`

Optional: Python 3 + [fonttools](https://github.com/fonttools/fonttools) to regenerate font subsets (see below).

## Getting started

```bash
flutter pub get
```

Font subset binaries under `assets/fonts/` are not committed (they are large). After cloning, either run the font pipeline below or supply your own subset `.ttf` files matching `assets/fonts_manifest.json`.

### Generate font subsets

Uses the first *N* alphabetically sorted families from Google Fonts metadata, subsets to `U+0030–U+0039`, writes files under `assets/fonts/` and refreshes `assets/fonts_manifest.json`.

```bash
python3 -m venv scripts/.venv
scripts/.venv/bin/pip install -r scripts/requirements-fonts.txt
scripts/.venv/bin/python scripts/fetch_fonts.py --limit 1500
```

## Run on Android

```bash
flutter run
# or
flutter build apk --release
```

Grant **camera** permission when prompted so ambient background switching works.

## GitHub Releases (CI)

Workflow [`.github/workflows/release-apk.yml`](.github/workflows/release-apk.yml) builds a **release APK** and publishes a **GitHub Release**.

| Trigger | What happens |
|--------|----------------|
| **Manual** | **Actions** → **Release APK** → **Run workflow**. Creates a release with tag `release-YYMMDD-<run_id>` (UTC date). |
| **Tag push** | Push a tag matching `v*` (for example `v1.0.0`). The APK is attached to the release for that tag. |

Android **`versionName`** and **`versionCode`** are set to **YYMMDD** (UTC), e.g. `260509`.

The project currently signs release APKs with the **debug** keystore (same as local `flutter build apk --release`). For Play Store–style signing, configure your keystore and pass secrets in CI.

## Project layout

| Path | Purpose |
|------|---------|
| `lib/main.dart` | UI, clock logic, font loading, ambient light |
| `scripts/fetch_fonts.py` | Download & subset fonts, emit manifest |
| `assets/fonts_manifest.json` | List of subset font filenames |
| `assets/fonts/` | Subset `.ttf` files (generated; ignored by git) |

## License

This project is licensed under the [MIT License](LICENSE).

Copyright © 2026 Evgeny Stepanischev.
