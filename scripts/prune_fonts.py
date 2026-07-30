#!/usr/bin/env python3
"""Remove generated font files that are not referenced by fonts_manifest.json."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def run(manifest_path: Path, fonts_dir: Path, dry_run: bool) -> int:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, list):
        raise RuntimeError(f"{manifest_path} must contain a JSON list")

    referenced = {
        item["file"]
        for item in manifest
        if isinstance(item, dict) and isinstance(item.get("file"), str)
    }
    removed = 0
    for path in sorted(fonts_dir.iterdir()):
        if path.suffix.lower() not in (".ttf", ".otf"):
            continue
        if path.name in referenced:
            continue
        print(("would remove " if dry_run else "remove ") + str(path))
        if not dry_run:
            path.unlink()
        removed += 1

    print(f"{'would remove' if dry_run else 'removed'} {removed} stale font files")
    return 0


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=root / "assets" / "fonts_manifest.json",
    )
    parser.add_argument(
        "--fonts-dir",
        type=Path,
        default=root / "assets" / "fonts",
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    raise SystemExit(run(args.manifest, args.fonts_dir, args.dry_run))


if __name__ == "__main__":
    main()
