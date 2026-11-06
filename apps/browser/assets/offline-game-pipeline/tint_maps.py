"""The backgrounds' recolour maps: what game.js needs to repaint a scene in a profile colour.

Usage (from this folder; build_assets.py runs it too):
  uv run --with numpy --with pillow tint_maps.py

The recolour: every pixel's luminance,
stretched between the scene's 1st and 99.5th percentiles, runs a ramp from colour × 0.4 through colour × 0.78
to colour + (1 − colour) × 0.6, except two kinds of light. The lamps' gold stays (orange and yellow profiles get
their own gold): hue 0.06–0.13 with a wide median, narrow enough to leave a scene's lit grass alone. The moon keeps
its own silver in every profile: pale (saturation under 0.28), bright (value over 0.7) and in the top 30% of the
frame, its disc filled and everything smaller than it (cloud edges, a clothesline) dropped by the median.

The masks need median and Gaussian filters, too slow for the page, so they ship here: for each
assets/bg/<id>.webp, assets/bg-map/<id>.webp (half size, lossless, red = lamps, green = moon) and the background's
"tint": {lo, hi, sun} in manifest.js (the luminance stretch and the lamps' 70th-percentile luminance).
"""

import json
import re
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

GAME = Path(__file__).resolve().parent.parent / "offline-game" / "assets"
LUMA = np.array([0.2126, 0.7152, 0.0722])


def soft(mask: np.ndarray, median: int, blur: float) -> np.ndarray:
    img = Image.fromarray((mask * 255).astype(np.uint8)).filter(ImageFilter.MedianFilter(median))
    return np.array(img.filter(ImageFilter.GaussianBlur(blur))).astype(np.float32) / 255


def moon_mask(s: np.ndarray, v: np.ndarray) -> np.ndarray:
    top = np.zeros(v.shape, bool)
    top[: int(v.shape[0] * 0.3)] = True
    pale = Image.fromarray((((s < 0.28) & (v > 0.7) & top) * 255).astype(np.uint8))
    disc = pale.filter(ImageFilter.MedianFilter(15)).filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.MinFilter(9))
    return soft(np.array(disc) > 127, 3, 1.5)


def tint_map(path: Path):
    full = Image.open(path).convert("RGB")
    half = full.resize((full.width // 2, full.height // 2), Image.LANCZOS)
    hsv = np.array(half.convert("HSV")).astype(np.float32) / 255
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    sun = soft((h > 0.06) & (h < 0.13) & (s > 0.3) & (v > 0.6), 11, 1.5)
    moon = moon_mask(s, v)
    lum = (np.array(full).astype(np.float32) / 255) @ LUMA
    upscale = lambda m: np.array(Image.fromarray((m * 255).astype(np.uint8)).resize(full.size, Image.BILINEAR)) / 255
    sun_full, moon_full = upscale(sun), upscale(moon)
    plain = (sun_full < 0.1) & (moon_full < 0.1)
    lo, hi = np.percentile(lum[plain], 1), np.percentile(lum[plain], 99.5)
    sun_lum = np.percentile(lum[sun_full > 0.9], 70) if (sun_full > 0.9).any() else 1.0
    channels = [(sun * 255).astype(np.uint8), (moon * 255).astype(np.uint8), np.zeros(sun.shape, np.uint8)]
    return Image.fromarray(np.stack(channels, axis=-1), "RGB"), {
        "lo": round(float(lo), 4), "hi": round(float(hi), 4), "sun": round(float(sun_lum), 4)}


def main():
    manifest_path = GAME / "manifest.js"
    text = manifest_path.read_text()
    head, body = re.match(r"(.*?window\.GAME_MANIFEST = )(.*);\s*$", text, re.S).groups()
    manifest = json.loads(body)
    (GAME / "bg-map").mkdir(exist_ok=True)
    for bg in manifest["backgrounds"]:
        im, bg["tint"] = tint_map(GAME / "bg" / f"{bg['id']}.webp")
        im.save(GAME / "bg-map" / f"{bg['id']}.webp", "WEBP", lossless=True, quality=100, method=6)
        print(bg["id"], bg["tint"])
    manifest_path.write_text(head + json.dumps(manifest, indent=1) + ";\n")


if __name__ == "__main__":
    main()
