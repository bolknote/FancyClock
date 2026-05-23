#!/usr/bin/env python3
"""Download Google Fonts families, subset to digits 0-9, emit manifest."""

from __future__ import annotations

import argparse
import json
import logging
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


METADATA_URL = "https://fonts.google.com/metadata/fonts"
META_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15 FancyClockFonts/1"
)
# Google's CSS endpoints return truetype URLs for legacy desktop / Windows NT user agents.
CSS_USER_AGENT = "Mozilla/5.0 (Windows NT 6.1; WOW64; rv:54.0) Gecko/20100101 Firefox/54.0"
REQUIRED_CODEPOINTS = {0x30 + i for i in range(10)}
BANNED_STEM_RE = re.compile(r"(_Guides$|Guides$|^Flow_|^Flow$|Barcode)", re.I)


def strip_jsonp(payload: str) -> str:
    p = payload.lstrip("\ufeff")
    if p.startswith(")]}'"):
        p = p[4:]
    return p


def fetch_metadata() -> dict:
    req = urllib.request.Request(METADATA_URL, headers={"User-Agent": META_USER_AGENT})
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read().decode("utf-8")
    return json.loads(strip_jsonp(raw))


def sorted_families(metadata: dict) -> list[str]:
    families_set: set[str] = set()
    for item in metadata.get("familyMetadataList", []):
        name = item.get("family")
        if isinstance(name, str) and name.strip():
            families_set.add(name.strip())
    if not families_set:
        raise RuntimeError("No families in metadata (unexpected JSON shape).")
    return sorted(families_set)


def sanitize_filename_slug(family: str) -> str:
    norm = unicodedata.normalize("NFKD", family)
    ascii_slug = "".join(c if c.isalnum() or c in "-_" else "_" for c in norm.encode("ascii", "ignore").decode())
    ascii_slug = re.sub(r"_+", "_", ascii_slug).strip("_")
    return ascii_slug or "font"


def is_banned_font_stem(stem: str) -> bool:
    """Reject generated families that do not render plain readable digits."""
    return bool(BANNED_STEM_RE.search(stem))


def css_url_for_family(family: str) -> str:
    q = urllib.parse.quote_plus(family)
    return f"https://fonts.googleapis.com/css2?family={q}&display=swap"


def fetch_css(css_url: str) -> str | None:
    req = urllib.request.Request(css_url, headers={"User-Agent": CSS_USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        logging.warning("CSS HTTPError %s for %s", e.code, css_url)
        return None
    except urllib.error.URLError as e:
        logging.warning("CSS URLError %s for %s", e.reason, css_url)
        return None
    return raw


def font_format_bonus(block: str) -> int:
    if re.search(r"format\s*\(\s*['\"]truetype['\"]\s*\)", block, re.I):
        return -200
    if re.search(r"format\s*\(\s*['\"]woff['\"]\s*\)", block, re.I):
        return -100
    if re.search(r"format\s*\(\s*['\"]woff2['\"]\s*\)", block, re.I):
        return 0
    return 40


def latin_block_score(block: str) -> int:
    m = re.search(r"unicode-range\s*:\s*([^;}]+)", block, re.I)
    if not m:
        return 500
    rng = m.group(1).lower()
    if "u+0000-00ff" in rng.replace(" ", ""):
        return 0
    if "u+0020" in rng.replace(" ", ""):
        return 100
    if "basic" in rng:
        return 200
    return 350


_face_re = re.compile(r"@font-face\s*\{([^}]*)\}", re.IGNORECASE | re.DOTALL)


def urls_from_css(css: str) -> list[str]:
    rows: list[tuple[int, int, str]] = []
    for idx, block in enumerate(_face_re.findall(css)):
        if re.search(r"font-style\s*:\s*italic", block, re.I):
            continue
        m = re.search(r"url\(\s*([^)]+\.[a-z0-9]+)\s*\)", block, re.I)
        if not m:
            m = re.search(r"url\(\s*([^)]+)\s*\)", block, re.I)
        if not m:
            continue
        url = re.sub(r"[\s\"\']+", "", m.group(1)).strip(",").strip()
        wg = block.lower()
        wscore = 0 if "font-weight:400" in wg.replace(" ", "") or "font-weight:400;" in wg else 10
        rows.append(
            (latin_block_score(block) + wscore + font_format_bonus(block), idx, url),
        )
    rows.sort(key=lambda t: (t[0], t[1]))
    return [u for _, _, u in rows]


def download_binary(url: str) -> bytes | None:
    req = urllib.request.Request(url, headers={"User-Agent": CSS_USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return resp.read()
    except urllib.error.HTTPError as e:
        logging.warning("Download HTTPError %s for %s…", e.code, url[:80])
        return None
    except urllib.error.URLError as e:
        logging.warning("Download URLError %s for %s…", e.reason, url[:80])
        return None


def subset_font_file(src: Path, dst: Path) -> bool:
    dst.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        sys.executable,
        "-m",
        "fontTools.subset",
        str(src),
        "--unicodes=U+0030-0039",
        "--layout-features=*",
        f"--output-file={dst}",
    ]
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        logging.debug("pyftsubset stderr: %s", proc.stderr[:500])
        return False
    return dst.exists() and dst.stat().st_size > 128


def read_font_family_name(ttf: Path) -> str | None:
    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        logging.error(
            "fonttools not installed — use scripts/.venv "
            "(see scripts/requirements-fonts.txt) or: python3 -m venv scripts/.venv && pip install fonttools",
        )
        raise
    font = TTFont(ttf, fontNumber=0)
    table = font["name"]
    buckets: dict[int, list[str]] = {16: [], 1: []}
    for rec in table.names:
        if rec.nameID not in (16, 1):
            continue
        try:
            s = rec.toUnicode().strip()
        except Exception:
            continue
        if s:
            buckets[rec.nameID].append(s)
    for nid in (16, 1):
        if buckets[nid]:
            return buckets[nid][0]
    return None


def verify_cmap(ttf: Path) -> bool:
    try:
        from fontTools.ttLib import TTFont

        font = TTFont(ttf, fontNumber=0)
        cmap = font.getBestCmap()
        if not cmap:
            return False
        present = set(cmap.keys())
        return REQUIRED_CODEPOINTS.issubset(present)
    except Exception:
        return False


def run(limit: int, out_dir: Path, manifest_out: Path, polite_delay_s: float) -> int:
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest: list[dict[str, str]] = []
    failed = 0
    skipped = 0

    md = fetch_metadata()
    families = sorted_families(md)

    logging.info(
        "Processing Google Fonts until %d usable digit fonts are written "
        "(available families=%d)",
        limit,
        len(families),
    )

    for i, family in enumerate(families, start=1):
        if len(manifest) >= limit:
            break
        slug = sanitize_filename_slug(family)
        if is_banned_font_stem(slug):
            skipped += 1
            logging.info("[%d/%d] %s → %s skipped by stem ban", i, len(families), family, slug)
            continue
        out_ttf = out_dir / f"{slug}.ttf"
        logging.info(
            "[%d/%d] %s → %s (usable=%d/%d)",
            i,
            len(families),
            family,
            out_ttf.name,
            len(manifest),
            limit,
        )

        css_url = css_url_for_family(family)
        css = fetch_css(css_url)
        time.sleep(polite_delay_s)
        if not css:
            failed += 1
            continue
        cand_urls = urls_from_css(css)
        if not cand_urls:
            logging.warning("%s — no font URLs parsed from CSS", family)
            failed += 1
            continue

        ok_any = False
        for u in cand_urls:
            blob = download_binary(u)
            time.sleep(polite_delay_s)
            if not blob or len(blob) < 512:
                continue

            if out_ttf.exists():
                try:
                    out_ttf.unlink()
                except OSError:
                    pass

            with tempfile.TemporaryDirectory(prefix="gfcss_") as tmp:
                src = Path(tmp) / "in.bin"
                src.write_bytes(blob)
                if subset_font_file(src, out_ttf) and verify_cmap(out_ttf):
                    fam_name = read_font_family_name(out_ttf) or family
                    if is_banned_font_stem(out_ttf.stem):
                        skipped += 1
                        ok_any = True
                        if out_ttf.exists():
                            try:
                                out_ttf.unlink()
                            except OSError:
                                pass
                        logging.info("%s skipped by output stem ban", out_ttf.name)
                        break
                    manifest.append({"file": out_ttf.name, "fontFamily": fam_name})
                    ok_any = True
                    break
                if out_ttf.exists():
                    try:
                        out_ttf.unlink()
                    except OSError:
                        pass

        if not ok_any:
            logging.warning("%s — no usable glyph subset (URLs tried=%d)", family, len(cand_urls))
            failed += 1

    manifest_out.parent.mkdir(parents=True, exist_ok=True)
    manifest_out.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    logging.info(
        "Done — %d subset fonts written, %d failed, %d skipped by ban. Manifest → %s",
        len(manifest),
        failed,
        skipped,
        manifest_out,
    )
    return 0 if manifest else 1


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    default_assets = root / "assets"
    parser = argparse.ArgumentParser(description="Fetch & subset Google Fonts for FancyClock.")
    parser.add_argument(
        "--limit",
        type=int,
        default=1500,
        help="Target number of usable digit-font subsets to write (default 1500).",
    )
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=default_assets / "fonts",
        help="Directory for subset .ttf files.",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=default_assets / "fonts_manifest.json",
        help="Path to fonts_manifest.json for Flutter.",
    )
    parser.add_argument(
        "--polite-delay",
        type=float,
        default=0.05,
        help="Sleep (seconds) after network calls to ease rate limits.",
    )
    parser.add_argument("-v", "--verbose", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(message)s",
    )

    sys.exit(run(args.limit, args.out_dir, args.manifest, args.polite_delay))


if __name__ == "__main__":
    main()
