"""Compose the Fringe repo header from a solved double-slit field (no text).

The interference fan behind a double slit rises out of the left edge on a slight upward
tilt. The slits sit off-frame and the first few micrometres are faded out, so the fan
enters already formed. Bright fringes glow Asympton yellow out of graphite through a warm
dark; the weaker outer fringes, which never reach yellow, stay cool slate.

usage: python compose.py FIELD.npy HERO.png HERO_SMALL.png
  FIELD.npy is the complex Ez field from `fringe-cli solve --npy` (with its .json sidecar).
  HERO.png is written at 2560 x 1280, HERO_SMALL.png at 1280 x 640; both RGB, no alpha.
"""
import json
import sys

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter, map_coordinates, maximum_filter

W, H = 2560, 1280

# weak features: deep graphite -> graphite -> slate -> grey-blue (never reaches yellow)
SLATE = [(0.00, 0x0B0D0F), (0.25, 0x16191C), (0.60, 0x3A4249), (1.00, 0x8E9CA8)]
# bright features: deep graphite -> warm dark -> Asympton yellow -> warm white
WARM = [(0.00, 0x0B0D0F), (0.22, 0x17150F), (0.50, 0x3A3220), (0.82, 0xF3C623), (1.00, 0xFFF6D8)]


def _rgb(h):
    return np.array([(h >> 16) & 255, (h >> 8) & 255, h & 255], dtype=np.float64) / 255.0


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def ramp(t, stops):
    """Map t in [0,1] to sRGB floats with smoothstep blending between stops."""
    t = np.clip(t, 0.0, 1.0)
    out = np.zeros(t.shape + (3,))
    for (ta, ha), (tb, hb) in zip(stops[:-1], stops[1:]):
        m = (t >= ta) & (t <= tb)
        f = (t[m] - ta) / (tb - ta)
        f = f * f * (3 - 2 * f)
        a, b = _rgb(ha), _rgb(hb)
        out[m] = a + (b - a) * f[:, None]
    return out


def sample_frame(a, meta, ox, oy, fx, fy, width_um, angle_deg, w=W, h=H):
    """Bicubically resample the field over a rotated frame: the scene point (ox, oy) um
    lands at fractional image position (fx, fy) (y down), the frame spans width_um across
    and the scene's +x axis tilts up by angle_deg."""
    g = meta["grid"]
    dx, gx0, gy0, ny = g["dx_um"], g["x0_um"], g["y0_um"], g["ny"]
    s = width_um / w
    U, V = np.meshgrid((np.arange(w) + 0.5 - fx * w) * s, -(np.arange(h) + 0.5 - fy * h) * s)
    th = np.radians(angle_deg)
    X = ox + U * np.cos(th) + V * np.sin(th)
    Y = oy - U * np.sin(th) + V * np.cos(th)
    rc = [(ny - 1) - (Y - gy0) / dx, (X - gx0) / dx]
    re = map_coordinates(a.real, rc, order=3, mode="nearest")
    im = map_coordinates(a.imag, rc, order=3, mode="nearest")
    return re + 1j * im, X, Y


def bloom(rgb, sigma, strength):
    """Soft additive (screen) glow from the bright parts."""
    lum = rgb.max(axis=2)
    hi = np.clip(lum - 0.55, 0, None)[..., None] * rgb
    glow = np.stack([gaussian_filter(hi[..., c], sigma) for c in range(3)], axis=2)
    return 1 - (1 - rgb) * (1 - np.clip(glow * strength, 0, 1))


def save(rgb, path, seed=7):
    """Dither with faint noise against banding in the dark gradients; save RGB PNG."""
    rng = np.random.default_rng(seed)
    noise = (rng.random(rgb.shape[:2]) - 0.5)[..., None] / 255.0 * 1.5
    out = np.clip((rgb + noise) * 255.0 + 0.5, 0, 255).astype(np.uint8)
    Image.fromarray(out, "RGB").save(path, optimize=True)


a = np.load(sys.argv[1])
meta = json.load(open(sys.argv[1] + ".json"))

# slits at (0, 0) sit ~6 um left of the frame, at 60 % of the height; fan tilts up 6 deg
E, X, Y = sample_frame(a, meta, 0.0, 0.0, -0.07, 0.60, 84.0, angle_deg=6.0)
I = np.abs(E) ** 2

# 2D cylindrical spreading: I ~ 1/r; lift it partly so the fringes carry to the right
# edge, and fade the slit near field so it is never the hottest spot
r = np.hypot(X, Y)
Ic = I * np.clip(r / 6.0, 0.35, None) ** 0.32 * smoothstep(5.0, 11.0, r)
Ic = Ic / np.percentile(Ic, 99.0)
t = 0.98 * (1 - np.exp(-1.6 * Ic)) ** 1.05

xn = (np.arange(W) + 0.5)[None, :] / W
t = t * (1 - 0.30 * smoothstep(0.75, 1.0, xn))

# hue path chosen per feature: the local peak (a fringe's crest, spread over its flanks)
# decides whether the whole fringe takes the warm path or stays slate
peak = gaussian_filter(maximum_filter(t, size=41), 14)
w = smoothstep(0.50, 0.72, peak)[..., None]
rgb = (1 - w) * ramp(t / 0.82, SLATE) * 0.92 + w * ramp(t, WARM)
rgb = bloom(rgb, 22, 0.7)

save(rgb, sys.argv[2])
small = Image.fromarray(np.clip(rgb * 255 + 0.5, 0, 255).astype(np.uint8), "RGB")
small.resize((W // 2, H // 2), Image.LANCZOS).save(sys.argv[3], optimize=True)
