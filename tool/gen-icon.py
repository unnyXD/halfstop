"""Generate the Halfstop launcher icon.

The mark is the pen-and-ink camera in `design/icon/artwork.png`, cropped to the
body: the paper and the wobbly line art are the artwork's own, and this script
only places it on the plate and writes every density a launcher asks for.

Composing a finished bitmap down (rather than re-rendering per size) is what
keeps the hatching identical across densities; the artwork is 1184 px wide, so
even the 432 px adaptive foreground is a downscale.

    python tool/gen-icon.py

Outputs (overwrites):
    design/icon/halfstop-1024.png                                master
    android/.../mipmap-*/ic_launcher.png                         legacy
    android/.../mipmap-*/ic_launcher_round.png                   legacy round
    android/.../mipmap-*/ic_launcher_foreground.png              adaptive fg
    android/.../mipmap-*/ic_launcher_monochrome.png              themed (13+)
"""

import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android/app/src/main/res"
OUT = ROOT / "design/icon"

# The artwork's own paper, sampled and rounded; `values/colors.xml` carries the
# same value as `ic_launcher_background`, so the plate and the picture agree.
PAPER = (242, 234, 220, 255)

# How much of the canvas the mark takes. Legacy plates can be generous; an
# adaptive foreground must stay inside the 66dp safe circle of its 108dp
# canvas, and this camera is ~1.4:1, so it shrinks by width.
LEGACY_SCALE = 0.92
ADAPTIVE_SCALE = 0.64

FEATHER = 0.05  # share of each edge that fades into the plate


def _artwork() -> Image.Image:
    return Image.open(OUT / "artwork.png").convert("RGB")


_ART = _artwork()


def _mark(width: int) -> Image.Image:
    """The camera on a feathered transparent field, exactly `width` wide.

    The artwork brings its own paper, so pasting it on a plate of the same
    colour looks seamless — except at the border, where the scan's vignette
    would draw a rectangle. Fading the outermost few percent hides that.
    """
    art = _ART
    height = max(1, round(width * art.size[1] / art.size[0]))
    layer = art.resize((width, height), Image.LANCZOS).convert("RGBA")

    mask = Image.new("L", (width, height), 255)
    d = ImageDraw.Draw(mask)
    fx = max(3, round(width * FEATHER))
    fy = max(3, round(height * FEATHER))
    for i in range(fx):
        v = round(255 * (i + 1) / fx)
        d.line([(i, 0), (i, height)], fill=v)
        d.line([(width - 1 - i, 0), (width - 1 - i, height)], fill=v)
    for j in range(fy):
        v = round(255 * (j + 1) / fy)
        d.line([(0, j), (width, j)], fill=v)
        d.line([(0, height - 1 - j), (width, height - 1 - j)], fill=v)
    mask = mask.filter(ImageFilter.GaussianBlur(max(1, fx // 3)))
    layer.putalpha(mask)
    return layer


def _mono(mark: Image.Image, colour=(255, 255, 255, 255)) -> Image.Image:
    """The line art as a single-colour silhouette: ink keeps its coverage."""
    grey = mark.convert("L")
    alpha = grey.point(lambda v: 255 - v)  # dark ink -> opaque
    out = Image.new("RGBA", mark.size, colour)
    out.putalpha(alpha)
    return out


def _paper(size: int) -> Image.Image:
    """Flat paper with a whisper of grain — enough to look printed, not noisy."""
    img = Image.new("RGB", (size, size), PAPER[:3])
    d = ImageDraw.Draw(img)
    rng = random.Random(7)
    step = max(2, size // 160)
    for y in range(0, size, step):
        for x in range(0, size, step):
            v = rng.randint(-3, 3)
            d.point((x, y), fill=(PAPER[0] + v, PAPER[1] + v, PAPER[2] + v))
    return img.convert("RGBA")


def render(
    size: int,
    *,
    with_background: bool,
    scale: float,
    tint=None,
) -> Image.Image:
    """One square icon with the camera centred at `scale` of the canvas."""
    ss = 4
    canvas = size * ss
    base = (
        _paper(canvas)
        if with_background
        else Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    )

    inner = max(1, round(canvas * scale))
    layer = _mark(inner)
    if tint is not None:
        layer = _mono(layer, tint)
    offset = ((canvas - layer.size[0]) // 2, (canvas - layer.size[1]) // 2)
    base.alpha_composite(layer, offset)
    return base.resize((size, size), Image.LANCZOS)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    master = render(1024, with_background=True, scale=LEGACY_SCALE)
    master.save(OUT / "halfstop-1024.png")
    master.resize((512, 512), Image.LANCZOS).save(OUT / "halfstop-512.png")

    legacy = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    adaptive = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

    for density, px in legacy.items():
        folder = RES / f"mipmap-{density}"
        folder.mkdir(parents=True, exist_ok=True)
        icon = render(px, with_background=True, scale=LEGACY_SCALE)
        icon.save(folder / "ic_launcher.png")
        icon.save(folder / "ic_launcher_round.png")
        print(f"mipmap-{density}: ic_launcher + round {px}px")

    # Adaptive foreground: transparent, camera inside the safe circle. The plate
    # colour lives in res/values/colors.xml (ic_launcher_background).
    for density, px in adaptive.items():
        folder = RES / f"mipmap-{density}"
        fg = render(px, with_background=False, scale=ADAPTIVE_SCALE)
        fg.save(folder / "ic_launcher_foreground.png")
        mono = render(px, with_background=False, scale=ADAPTIVE_SCALE, tint=(255, 255, 255, 255))
        mono.save(folder / "ic_launcher_monochrome.png")
        print(f"mipmap-{density}: foreground + monochrome {px}px")

    # Contact sheet: real launcher sizes, square and circle-masked.
    sheet = Image.new("RGBA", (700, 240), (26, 24, 21, 255))
    x = 24
    for px in (192, 96, 48):
        sheet.alpha_composite(render(px, with_background=True, scale=LEGACY_SCALE), (x, 24))
        x += px + 24
    x += 16
    for px in (96, 72, 48):
        icon = render(px, with_background=True, scale=LEGACY_SCALE)
        mask = Image.new("L", (px, px), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, px - 1, px - 1), fill=255)
        sheet.paste(icon, (x, 24), mask)
        x += px + 20
    sheet.save(OUT / "preview.png")
    print("wrote design/icon/preview.png")


if __name__ == "__main__":
    main()
