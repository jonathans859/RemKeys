#!/usr/bin/env python3
"""Generate the RemKeys app icon into both asset catalogs.

    python3 scripts/make-app-icon.py

The mark is one keycap with a right-pointing arrow on it: "a key, sent
somewhere else". Deliberately a single shape — the previous placeholder put
two letters and a rule on a gradient, and at the 60 pt the home screen
actually draws, letter pairs turn to mush while one silhouette survives.

Colours are the app's accent (Assets.xcassets/AccentColor.colorset): indigo
#4B3FD6, deepened to #2E1F9E for the gradient's far corner so the plate has
some direction to it without becoming a two-tone stripe.

iOS gets one flattened 1024x1024 RGB image — the marketing icon must carry no
alpha channel, and iOS applies the squircle mask itself. macOS gets the
rounded-square-on-transparent shape at every size Apple asks for, inset to the
proportions of the system icons so it doesn't tower over its neighbours in the
Dock.
"""

from __future__ import annotations

import os

from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

ACCENT = (0x4B, 0x3F, 0xD6)
ACCENT_DEEP = (0x2E, 0x1F, 0x9E)
KEYCAP_FACE = (0xFF, 0xFF, 0xFF)
KEYCAP_EDGE = (0xE4, 0xE1, 0xFF)

# Everything is authored at 4x the 1024 canvas and downsampled, which is what
# keeps the diagonals of the arrowhead and the corner radii clean — PIL has no
# antialiased polygon fill.
SS = 4


def _gradient(size: int) -> Image.Image:
    """Diagonal accent plate. Drawn small and scaled up: a gradient has no
    edges to alias, so there is nothing to gain from supersampling it."""
    small = Image.new("RGB", (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            # Distance along the top-left -> bottom-right diagonal.
            t = (x + y) / 126.0
            px[x, y] = tuple(
                round(ACCENT[i] + (ACCENT_DEEP[i] - ACCENT[i]) * t) for i in range(3)
            )
    return small.resize((size, size), Image.LANCZOS)


def _mark(size: int) -> Image.Image:
    """The keycap and its arrow, on transparency, sized to `size`."""
    s = size * SS
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    def u(v: float) -> float:
        """Fraction of the canvas -> pixels."""
        return v * s

    # Soft drop shadow, so the keycap sits *on* the plate instead of being
    # pasted onto it. Drawn on its own layer and blurred, offset downward only.
    shadow = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [u(0.225), u(0.240), u(0.775), u(0.800)],
        radius=u(0.125),
        fill=(0x14, 0x0C, 0x4A, 150),
    )
    layer.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(u(0.026))))

    # Keycap: an outer plate with a slightly inset face, which is the whole
    # reason it reads as a key rather than as a rounded square.
    d.rounded_rectangle(
        [u(0.220), u(0.212), u(0.780), u(0.788)],
        radius=u(0.128),
        fill=KEYCAP_EDGE,
    )
    d.rounded_rectangle(
        [u(0.252), u(0.238), u(0.748), u(0.752)],
        radius=u(0.100),
        fill=KEYCAP_FACE,
    )

    # Arrow, in the accent, centred on the face. Kept slim: a fat head reads
    # as clip art, and at home-screen size the silhouette is all that lands.
    mid = u(0.495)
    shaft_h = u(0.056)
    d.rounded_rectangle(
        [u(0.330), mid - shaft_h / 2, u(0.600), mid + shaft_h / 2],
        radius=shaft_h / 2,
        fill=ACCENT,
    )
    head = u(0.082)
    d.polygon(
        [(u(0.672), mid), (u(0.564), mid - head), (u(0.564), mid + head)],
        fill=ACCENT,
    )

    return layer.resize((size, size), Image.LANCZOS)


def ios_icon(size: int = 1024) -> Image.Image:
    """Full-bleed and flattened: App Store Connect rejects a marketing icon
    that carries an alpha channel, and iOS masks the corners itself."""
    plate = _gradient(size)
    plate.paste(_mark(size), (0, 0), _mark(size))
    return plate.convert("RGB")


def macos_icon(size: int) -> Image.Image:
    """Rounded square on transparency, inset the way Apple's own icons are
    (roughly 80% of the tile, with the shadow's room left empty)."""
    s = size * SS
    canvas = Image.new("RGBA", (s, s), (0, 0, 0, 0))

    inset = round(s * 0.098)
    side = s - 2 * inset
    plate = _gradient(side).convert("RGBA")

    mask = Image.new("L", (side, side), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, side - 1, side - 1], radius=round(side * 0.225), fill=255
    )
    canvas.paste(plate, (inset, inset), mask)

    mark = _mark(side)
    canvas.paste(mark, (inset, inset), mark)
    return canvas.resize((size, size), Image.LANCZOS)


def main() -> None:
    ios_dir = os.path.join(ROOT, "apps", "iOS", "Assets.xcassets", "AppIcon.appiconset")
    mac_dir = os.path.join(ROOT, "apps", "macOS", "Assets.xcassets", "AppIcon.appiconset")

    ios_path = os.path.join(ios_dir, "AppIcon.png")
    ios_icon().save(ios_path)
    print("wrote", ios_path)

    for size in (16, 32, 64, 128, 256, 512, 1024):
        path = os.path.join(mac_dir, "mac%d.png" % size)
        macos_icon(size).save(path)
        print("wrote", path)


if __name__ == "__main__":
    main()
