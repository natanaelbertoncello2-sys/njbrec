"""Genera el logo, el icono de la app y los iconos de bandeja de NJB Rec.

Uso:  python tool/make_branding.py
Salida:
  assets/branding/logo_mark.png        (1024x1024, isotipo)
  assets/branding/logo_wordmark.png    (isotipo + texto "NJB REC")
  assets/branding/tray_idle.ico        (bandeja, reposo)
  assets/branding/tray_rec.ico         (bandeja, grabando)
  assets/branding/tray_pause.ico       (bandeja, en pausa)
  windows/runner/resources/app_icon.ico
"""
from __future__ import annotations

import math
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "branding"
OUT.mkdir(parents=True, exist_ok=True)

BG_TOP = (29, 26, 54)
BG_BOTTOM = (12, 10, 24)
VIOLET = (124, 92, 255)
CYAN = (53, 208, 255)
RED = (255, 77, 109)
WHITE = (255, 255, 255)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def vertical_gradient(size, top, bottom):
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        c = lerp(top, bottom, y / (size - 1))
        for x in range(size):
            px[x, y] = c
    return img


def angular_ring(size, cx, cy, r_out, r_in, c0, c1):
    """Anillo con degradado angular (c0 -> c1 -> c0)."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = img.load()
    for y in range(size):
        for x in range(size):
            dx, dy = x - cx, y - cy
            d = math.hypot(dx, dy)
            if r_in - 1 <= d <= r_out + 1:
                ang = (math.atan2(dy, dx) + math.pi) / (2 * math.pi)
                t = 1 - abs(2 * ang - 1)
                col = lerp(c0, c1, t)
                # antialias en bordes
                a = 1.0
                if d > r_out:
                    a = max(0.0, 1 - (d - r_out))
                elif d < r_in:
                    a = max(0.0, 1 - (r_in - d))
                px[x, y] = (*col, int(255 * a))
    return img


def make_mark(size: int, with_bg: bool = True, dot_color=RED, paused=False) -> Image.Image:
    S = size * 2  # supersample
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    if with_bg:
        grad = vertical_gradient(S, BG_TOP, BG_BOTTOM).convert("RGBA")
        mask = Image.new("L", (S, S), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.23), fill=255)
        base.paste(grad, (0, 0), mask)

        # brillo sutil arriba a la izquierda
        glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        gd = ImageDraw.Draw(glow)
        gd.ellipse([-S * 0.2, -S * 0.35, S * 0.7, S * 0.45], fill=(*VIOLET, 70))
        glow = glow.filter(ImageFilter.GaussianBlur(S * 0.12))
        base = Image.alpha_composite(base, Image.composite(glow, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask))

    cx = cy = S / 2
    r_out = S * 0.36
    r_in = S * 0.285

    # sombra del anillo
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).ellipse([cx - r_out, cy - r_out + S * 0.02, cx + r_out, cy + r_out + S * 0.02], fill=(0, 0, 0, 120))
    shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.03))
    base = Image.alpha_composite(base, shadow)

    ring = angular_ring(S, cx, cy, r_out, r_in, VIOLET, CYAN)
    base = Image.alpha_composite(base, ring)

    # punto central (grabar) con resplandor
    r_dot = S * 0.17
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse([cx - r_dot * 1.4, cy - r_dot * 1.4, cx + r_dot * 1.4, cy + r_dot * 1.4], fill=(*dot_color, 110))
    glow = glow.filter(ImageFilter.GaussianBlur(S * 0.05))
    base = Image.alpha_composite(base, glow)

    d = ImageDraw.Draw(base)
    if paused:
        bw = r_dot * 0.55
        gap = r_dot * 0.25
        d.rounded_rectangle([cx - gap - bw, cy - r_dot, cx - gap, cy + r_dot], radius=bw * 0.3, fill=dot_color)
        d.rounded_rectangle([cx + gap, cy - r_dot, cx + gap + bw, cy + r_dot], radius=bw * 0.3, fill=dot_color)
    else:
        d.ellipse([cx - r_dot, cy - r_dot, cx + r_dot, cy + r_dot], fill=dot_color)
        # reflejo
        hl = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(hl).ellipse([cx - r_dot * 0.55, cy - r_dot * 0.8, cx + r_dot * 0.1, cy - r_dot * 0.15], fill=(255, 255, 255, 130))
        hl = hl.filter(ImageFilter.GaussianBlur(S * 0.012))
        base = Image.alpha_composite(base, hl)

    return base.resize((size, size), Image.LANCZOS)


def find_font(bold=True):
    candidates = [
        r"C:\Windows\Fonts\segoeuib.ttf" if bold else r"C:\Windows\Fonts\segoeui.ttf",
        r"C:\Windows\Fonts\arialbd.ttf" if bold else r"C:\Windows\Fonts\arial.ttf",
    ]
    for c in candidates:
        if os.path.exists(c):
            return c
    return None


def make_wordmark():
    mark = make_mark(512)
    font_path = find_font(True)
    font_big = ImageFont.truetype(font_path, 300) if font_path else ImageFont.load_default()
    font_small = ImageFont.truetype(font_path, 120) if font_path else ImageFont.load_default()

    tmp = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    w1 = tmp.textbbox((0, 0), "NJB", font=font_big)
    w2 = tmp.textbbox((0, 0), "REC", font=font_small)
    text_w = max(w1[2] - w1[0], w2[2] - w2[0])

    pad = 60
    W = 512 + pad + text_w + pad
    H = 512
    img = Image.new("RGBA", (int(W), H), (0, 0, 0, 0))
    img.paste(mark, (0, 0), mark)
    d = ImageDraw.Draw(img)
    x = 512 + pad
    d.text((x - w1[0], 70 - w1[1]), "NJB", font=font_big, fill=WHITE)
    # "REC" en rojo con un punto
    d.text((x - w2[0], 360 - w2[1]), "REC", font=font_small, fill=RED)
    dot_r = 26
    rx = x + (w2[2] - w2[0]) + 40
    d.ellipse([rx, 360 + 30, rx + dot_r * 2, 360 + 30 + dot_r * 2], fill=RED)
    img.save(OUT / "logo_wordmark.png")


def save_ico(img: Image.Image, path: Path):
    sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    img.save(path, format="ICO", sizes=sizes)


def main():
    mark = make_mark(1024)
    mark.save(OUT / "logo_mark.png")
    make_wordmark()

    save_ico(make_mark(256), ROOT / "windows" / "runner" / "resources" / "app_icon.ico")
    save_ico(make_mark(256), OUT / "tray_idle.ico")
    save_ico(make_mark(256, dot_color=(255, 40, 70)), OUT / "tray_rec.ico")
    save_ico(make_mark(256, dot_color=(255, 190, 60), paused=True), OUT / "tray_pause.ico")
    print("Listo:", OUT)


if __name__ == "__main__":
    main()
