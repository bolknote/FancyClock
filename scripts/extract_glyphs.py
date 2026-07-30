#!/usr/bin/env python3
"""Extract digit glyph outlines from subset TTF files into JSON assets."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.ttLib import TTFont


DIGITS = "0123456789"


def _round_coord(value: float) -> int | float:
    rounded = round(value)
    if abs(value - rounded) < 0.001:
        return int(rounded)
    return round(value, 3)


def _point_tuple(point: tuple[float, float]) -> list[int | float]:
    return [_round_coord(point[0]), _round_coord(point[1])]


def _convert_qcurve(
    current: tuple[float, float] | None,
    points: tuple[tuple[float, float] | None, ...],
) -> tuple[list[list[int | float | str]], tuple[float, float] | None]:
    if current is None or len(points) < 2 or points[-1] is None:
        return [], current

    offcurves = points[:-1]
    end = points[-1]
    commands: list[list[int | float | str]] = []
    for index, control in enumerate(offcurves):
        if control is None:
            continue
        if index == len(offcurves) - 1:
            q_end = end
        else:
            next_control = offcurves[index + 1]
            if next_control is None:
                q_end = end
            else:
                q_end = (
                    (control[0] + next_control[0]) / 2,
                    (control[1] + next_control[1]) / 2,
                )
        commands.append(["Q", *_point_tuple(control), *_point_tuple(q_end)])
        current = q_end
    return commands, current


def _glyph_commands(glyph_set, glyph_name: str) -> list[list[int | float | str]]:
    pen = DecomposingRecordingPen(glyph_set)
    glyph_set[glyph_name].draw(pen)

    commands: list[list[int | float | str]] = []
    current: tuple[float, float] | None = None
    for op, points in pen.value:
        if op == "moveTo":
            current = points[0]
            commands.append(["M", *_point_tuple(points[0])])
        elif op == "lineTo":
            current = points[0]
            commands.append(["L", *_point_tuple(points[0])])
        elif op == "curveTo":
            p1, p2, p3 = points
            current = p3
            commands.append(["C", *_point_tuple(p1), *_point_tuple(p2), *_point_tuple(p3)])
        elif op == "qCurveTo":
            q_commands, current = _convert_qcurve(current, points)
            commands.extend(q_commands)
        elif op in ("closePath", "endPath"):
            commands.append(["Z"])
    return commands


def _glyph_bounds(glyph_set, glyph_name: str) -> list[int | float] | None:
    pen = BoundsPen(glyph_set)
    glyph_set[glyph_name].draw(pen)
    if pen.bounds is None:
        return None
    x_min, y_min, x_max, y_max = pen.bounds
    return [_round_coord(x_min), _round_coord(y_min), _round_coord(x_max), _round_coord(y_max)]


def extract_font(ttf: Path, out_path: Path, family: str) -> None:
    font = TTFont(ttf)
    glyph_set = font.getGlyphSet()
    cmap = font.getBestCmap() or {}
    hmtx = font["hmtx"].metrics
    hhea = font["hhea"]
    units_per_em = font["head"].unitsPerEm

    glyphs = {}
    for ch in DIGITS:
        glyph_name = cmap.get(ord(ch))
        if not glyph_name:
            raise RuntimeError(f"{ttf.name}: missing digit {ch}")
        advance, left_bearing = hmtx[glyph_name]
        commands = _glyph_commands(glyph_set, glyph_name)
        if not commands:
            raise RuntimeError(f"{ttf.name}: empty digit {ch}")
        glyphs[ch] = {
            "advance": _round_coord(advance),
            "leftBearing": _round_coord(left_bearing),
            "bounds": _glyph_bounds(glyph_set, glyph_name),
            "commands": commands,
        }

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(
            {
                "file": ttf.name,
                "fontFamily": family,
                "unitsPerEm": units_per_em,
                "ascent": _round_coord(hhea.ascent),
                "descent": _round_coord(hhea.descent),
                "glyphs": glyphs,
            },
            separators=(",", ":"),
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )


def run(manifest_path: Path, fonts_dir: Path, out_dir: Path) -> int:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if not isinstance(manifest, list):
        raise RuntimeError(f"{manifest_path} must contain a JSON list")

    written = 0
    for item in manifest:
        if not isinstance(item, dict):
            continue
        filename = item.get("file")
        family = item.get("fontFamily")
        if not isinstance(filename, str) or not isinstance(family, str):
            continue
        ttf = fonts_dir / filename
        if not ttf.exists():
            print(f"missing {ttf}")
            continue
        out_path = out_dir / f"{ttf.stem}.json"
        extract_font(ttf, out_path, family)
        written += 1

    print(f"wrote {written} glyph assets to {out_dir}")
    return 0 if written else 1


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=root / "assets" / "fonts_manifest.json")
    parser.add_argument("--fonts-dir", type=Path, default=root / "assets" / "fonts")
    parser.add_argument("--out-dir", type=Path, default=root / "assets" / "glyphs")
    args = parser.parse_args()
    raise SystemExit(run(args.manifest, args.fonts_dir, args.out_dir))


if __name__ == "__main__":
    main()
