"""Generate the Spektrafilm launcher icon from code.

The mark: a vertical 35mm film strip (the film), with a spectral gradient band
where the image gate would be (the spectral simulation). Amber #E0A458 matches
the in-app accent; the near-black #0B0C0F matches the app background.

Everything is drawn at 4x and downsampled, so edges stay clean at 48 px.

    python tool/gen-icon.py

Outputs (overwrites):
    design/icon/spektrafilm-1024.png           master / store listing
    android/app/src/main/res/mipmap-*/ic_launcher.png        legacy
    android/app/src/main/res/mipmap-*/ic_launcher_round.png  legacy round
    android/app/src/main/res/mipmap-*/ic_launcher_foreground.png  adaptive fg
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "android/app/src/main/res"
OUT = ROOT / "design/icon"

SS = 4  # supersample factor
BASE = 1024

BG = (11, 12, 15, 255)  # #0B0C0F
AMBER = (224, 164, 88, 255)  # #E0A458
GATE = (7, 8, 10, 255)  # #07080A

# Emblem geometry in the 1024 design space.
STRIP = (330, 158, 694, 866)
STRIP_RADIUS = 44
STRIP_STROKE = 16
GATE_BOX = (386, 220, 638, 804)
HOLE_W, HOLE_H, HOLE_R = 24, 34, 9
HOLES = 6
BAND = (386, 452, 638, 572)  # (x0, y0, x1, y1)

STOPS = [
    (0.00, (31, 182, 201)),
    (0.20, (95, 201, 138)),
    (0.45, (224, 164, 88)),
    (0.72, (224, 112, 60)),
    (1.00, (216, 56, 111)),
]


def _lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def _gradient(width, height):
    """Horizontal multi-stop gradient, one column per stop segment."""
    img = Image.new("RGB", (width, 1))
    px = img.load()
    for x in range(width):
        t = x / max(1, width - 1)
        for i in range(len(STOPS) - 1):
            p0, c0 = STOPS[i]
            p1, c1 = STOPS[i + 1]
            if p0 <= t <= p1:
                local = (t - p0) / (p1 - p0) if p1 > p0 else 0
                px[x, 0] = _lerp(c0, c1, local)
                break
        else:
            px[x, 0] = STOPS[-1][1]
    return img.resize((width, height), Image.BICUBIC)


def _draw_emblem(draw, scale):
    def s(box):
        return tuple(round(v * scale * SS) for v in box)

    # film strip body: dark fill so the strip reads as an object on any backdrop
    draw.rounded_rectangle(
        s(STRIP),
        radius=round(STRIP_RADIUS * scale * SS),
        fill=GATE,
        outline=AMBER,
        width=max(1, round(STRIP_STROKE * scale * SS)),
    )

    # sprocket holes along both edges
    x0, y0, x1, y1 = GATE_BOX
    left_cx = (STRIP[0] + x0) / 2
    right_cx = (x1 + STRIP[2]) / 2
    span = y1 - y0
    step = span / HOLES
    for i in range(HOLES):
        cy = y0 + step * (i + 0.5)
        for cx in (left_cx, right_cx):
            draw.rounded_rectangle(
                s(
                    (
                        cx - HOLE_W / 2,
                        cy - HOLE_H / 2,
                        cx + HOLE_W / 2,
                        cy + HOLE_H / 2,
                    )
                ),
                radius=round(HOLE_R * scale * SS),
                fill=AMBER,
            )


def render(size, *, with_background, emblem_scale=1.0):
    """Render one square icon. emblem_scale shrinks the mark inside the canvas."""
    canvas = size * SS
    img = Image.new(
        "RGBA", (canvas, canvas), BG if with_background else (0, 0, 0, 0)
    )
    draw = ImageDraw.Draw(img)

    if emblem_scale != 1.0:
        # draw the mark on its own layer, then paste centred at the new scale
        layer_px = round(canvas * emblem_scale)
        layer = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        _draw_emblem(ImageDraw.Draw(layer), 1.0)
        layer = layer.resize((layer_px, layer_px), Image.LANCZOS)
        off = (canvas - layer_px) // 2
        img.alpha_composite(layer, (off, off))
    else:
        _draw_emblem(draw, 1.0)

    band = _gradient(
        round((BAND[2] - BAND[0]) * SS),
        round((BAND[3] - BAND[1]) * SS),
    ).convert("RGBA")
    if emblem_scale != 1.0:
        # gradient belongs to the shrunken mark: rebuild it on the layer
        band_layer = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        band_layer.paste(
            band,
            (round(BAND[0] * SS), round(BAND[1] * SS)),
        )
        band_layer = band_layer.resize((layer_px, layer_px), Image.LANCZOS)
        img.alpha_composite(band_layer, (off, off))
    else:
        img.paste(band, (round(BAND[0] * SS), round(BAND[1] * SS)))

    return img.resize((size, size), Image.LANCZOS)


def main():
    OUT.mkdir(parents=True, exist_ok=True)

    master = render(BASE, with_background=True)
    master.save(OUT / "spektrafilm-1024.png")
    master.resize((512, 512), Image.LANCZOS).save(OUT / "spektrafilm-512.png")

    legacy = {
        "mdpi": 48,
        "hdpi": 72,
        "xhdpi": 96,
        "xxhdpi": 144,
        "xxxhdpi": 192,
    }
    adaptive = {
        "mdpi": 108,
        "hdpi": 162,
        "xhdpi": 216,
        "xxhdpi": 324,
        "xxxhdpi": 432,
    }
    for density, px in legacy.items():
        folder = RES / f"mipmap-{density}"
        folder.mkdir(parents=True, exist_ok=True)
        icon = render(px, with_background=True)
        icon.save(folder / "ic_launcher.png")
        icon.save(folder / "ic_launcher_round.png")
        print(f"mipmap-{density}: ic_launcher {px}px")

    # Adaptive foreground: 108dp canvas, mark kept inside the 66dp safe zone.
    for density, px in adaptive.items():
        folder = RES / f"mipmap-{density}"
        fg = render(px, with_background=False, emblem_scale=66 / 108)
        fg.save(folder / "ic_launcher_foreground.png")
        print(f"mipmap-{density}: foreground {px}px")


if __name__ == "__main__":
    main()
