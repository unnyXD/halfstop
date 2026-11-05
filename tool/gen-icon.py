"""Generate the Halfstop launcher icon from code.

The mark is a vertical 35mm strip with a half-filled aperture in the gate: the
strip says "film", the half disc says "half a stop" — the name of the app.

Everything is drawn once in a 1024-unit design space at 2x, then scaled down
with LANCZOS. Scaling a finished layer (rather than re-drawing at each size) is
what keeps the thin strokes and the perforations identical across densities.

    python tool/gen-icon.py

Outputs (overwrites):
    design/icon/halfstop-1024.png                                master
    android/.../mipmap-*/ic_launcher.png                         legacy
    android/.../mipmap-*/ic_launcher_round.png                   legacy round
    android/.../mipmap-*/ic_launcher_foreground.png              adaptive fg
    android/.../mipmap-*/ic_launcher_monochrome.png              themed (13+)
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android/app/src/main/res"
OUT = ROOT / "design/icon"

DESIGN = 1024  # design space, all geometry below is in these units
DRAW_SCALE = 2  # render the master layer at 2x, then downsample

# Darkroom palette, same values as lib/editor_page.dart.
BG = (10, 9, 8, 255)  # #0A0908 warm black
AMBER = (227, 163, 92, 255)  # #E3A35C safelight

# Strip geometry: a landscape 35mm segment. Landscape, not portrait — a
# portrait strip with dots down the sides reads as a phone at launcher size.
STRIP = (12, 142, 1012, 882)  # x0, y0, x1, y1
STRIP_RADIUS = 40
STROKE = 28

GATE = (92, 232, 932, 792)  # 840 x 560, i.e. 3:2 — a real 135 frame
HOLE_W, HOLE_H, HOLE_R = 48, 30, 9
HOLES = 6

# Half disc inside the gate: left half solid, right half outlined.
DISC_CX, DISC_CY, DISC_R = 512, 512, 132
DISC_STROKE = 22


def _px(box, k):
    return tuple(round(v * k) for v in box)


def build_master() -> Image.Image:
    """The mark on a transparent 1024 canvas, drawn at DRAW_SCALE."""
    px = DESIGN * DRAW_SCALE
    img = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = DRAW_SCALE

    # --- strip: outline only, so it sits on any backdrop ---
    d.rounded_rectangle(
        _px(STRIP, k),
        radius=round(STRIP_RADIUS * k),
        outline=AMBER,
        width=round(STROKE * k),
    )

    # --- perforations along the top and bottom rebates (35mm has them on the
    # long edges, not the ends) ---
    x0, y0, x1, y1 = GATE
    top_cy = (STRIP[1] + y0) / 2
    bottom_cy = (y1 + STRIP[3]) / 2
    step = (x1 - x0) / HOLES
    for i in range(HOLES):
        cx = x0 + step * (i + 0.5)
        for cy in (top_cy, bottom_cy):
            d.rounded_rectangle(
                _px(
                    (
                        cx - HOLE_W / 2,
                        cy - HOLE_H / 2,
                        cx + HOLE_W / 2,
                        cy + HOLE_H / 2,
                    ),
                    k,
                ),
                radius=round(HOLE_R * k),
                fill=AMBER,
            )

    # --- gate outline, thin: the rebate is thick, the gate is precise ---
    d.rounded_rectangle(
        _px(GATE, k),
        radius=round(18 * k),
        outline=AMBER,
        width=round(10 * k),
    )

    # --- half disc: solid left, ringed right ---
    box = (DISC_CX - DISC_R, DISC_CY - DISC_R, DISC_CX + DISC_R, DISC_CY + DISC_R)
    d.ellipse(_px(box, k), outline=AMBER, width=round(DISC_STROKE * k))
    d.pieslice(_px(box, k), start=90, end=270, fill=AMBER)

    return img


_MASTER = build_master()


def render(
    size: int,
    *,
    with_background: bool,
    scale: float,
    background=BG,
    tint=None,
) -> Image.Image:
    """One square icon.

    `scale` is the mark's size as a fraction of the canvas. Legacy icons can be
    generous (0.74); adaptive foregrounds must stay inside the 66dp safe circle
    of their 108dp canvas, which works out to about 0.48 for this 1.35:1 mark
    once its corners are accounted for.
    """
    ss = 4
    canvas = size * ss
    base = Image.new(
        "RGBA", (canvas, canvas), background if with_background else (0, 0, 0, 0)
    )

    master = _MASTER
    if tint is not None:
        # Themed icons are a single-colour silhouette: keep alpha, swap colour.
        master = Image.new("RGBA", _MASTER.size, tint)
        master.putalpha(_MASTER.getchannel("A"))

    inner = max(1, round(canvas * scale))
    layer = master.resize((inner, inner), Image.LANCZOS)
    offset = (canvas - inner) // 2
    base.alpha_composite(layer, (offset, offset))
    return base.resize((size, size), Image.LANCZOS)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    master = render(1024, with_background=True, scale=0.74)
    master.save(OUT / "halfstop-1024.png")
    master.resize((512, 512), Image.LANCZOS).save(OUT / "halfstop-512.png")

    legacy = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    adaptive = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}

    for density, px in legacy.items():
        folder = RES / f"mipmap-{density}"
        folder.mkdir(parents=True, exist_ok=True)
        icon = render(px, with_background=True, scale=0.74)
        icon.save(folder / "ic_launcher.png")
        icon.save(folder / "ic_launcher_round.png")
        print(f"mipmap-{density}: ic_launcher + round {px}px")

    # Adaptive foreground: transparent, mark inside the safe circle.
    for density, px in adaptive.items():
        folder = RES / f"mipmap-{density}"
        fg = render(px, with_background=False, scale=0.48)
        fg.save(folder / "ic_launcher_foreground.png")
        mono = render(px, with_background=False, scale=0.48, tint=(255, 255, 255, 255))
        mono.save(folder / "ic_launcher_monochrome.png")
        print(f"mipmap-{density}: foreground + monochrome {px}px")

    # Contact sheet: real launcher sizes, square and circle-masked.
    sheet = Image.new("RGBA", (700, 240), (26, 24, 21, 255))
    x = 24
    for px in (192, 96, 48):
        sheet.alpha_composite(render(px, with_background=True, scale=0.74), (x, 24))
        x += px + 24
    x += 16
    for px in (96, 72, 48):
        icon = render(px, with_background=True, scale=0.74)
        mask = Image.new("L", (px, px), 0)
        ImageDraw.Draw(mask).ellipse((0, 0, px - 1, px - 1), fill=255)
        sheet.paste(icon, (x, 24), mask)
        x += px + 20
    sheet.save(OUT / "preview.png")
    print("wrote design/icon/preview.png")


if __name__ == "__main__":
    main()
