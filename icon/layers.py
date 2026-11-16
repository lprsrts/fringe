"""Writes the SVG layers of icon/AppIcon.icon: a double slit seen from above and
the fan of interference maxima behind it.

The rays leave the midpoint between the slits at the true double-slit maxima,
sin θ = m λ/d, with λ/d = 0.3: the central order and the first orders in yellow,
the second orders shorter and grey, as the intensity envelope falls off.
"""

import math
import os

ASSETS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "AppIcon.icon", "Assets")

LAMBDA_OVER_D = 0.30
ORIGIN = (512, 786)  # midpoint between the slits, in the 1024 pt icon canvas
RAY_START = 92  # rays begin this far from the origin, clear of the screen

YELLOW = ("#FFE77F", "#F7C928")  # Asympton yellow, lighter at the slits
GREY = ("#DCE2E8", "#8E9CA8")  # brand greys
SCREEN = "#E6EBF0"

# Per order |m|: ray length, width at the start and width at the rounded tip.
RAY_SIZE = {0: (600, 22, 80), 1: (560, 20, 72), 2: (470, 18, 60)}


def svg(body, defs=""):
    return (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
        f"<defs>{defs}</defs>{body}</svg>\n"
    )


def ray(m):
    """A tapered ray for order m with a round tip, and its start and end points."""
    length, w_start, w_end = RAY_SIZE[abs(m)]
    theta = math.asin(m * LAMBDA_OVER_D)
    ux, uy = math.sin(theta), -math.cos(theta)  # up the canvas is -y
    px, py = -uy, ux
    ox, oy = ORIGIN
    x0, y0 = ox + ux * RAY_START, oy + uy * RAY_START
    x1, y1 = ox + ux * length, oy + uy * length
    corners = [
        (x0 + px * w_start / 2, y0 + py * w_start / 2),
        (x1 + px * w_end / 2, y1 + py * w_end / 2),
        (x1 - px * w_end / 2, y1 - py * w_end / 2),
        (x0 - px * w_start / 2, y0 - py * w_start / 2),
    ]
    r = w_end / 2
    path = "M%.1f %.1f L%.1f %.1f A%.1f %.1f 0 0 0 %.1f %.1f L%.1f %.1f Z" % (
        corners[0] + corners[1] + (r, r) + corners[2] + corners[3]
    )
    return path, (x0, y0, x1, y1)


def gradient(gid, colors, x0, y0, x1, y1):
    return (
        f'<linearGradient id="{gid}" gradientUnits="userSpaceOnUse" '
        f'x1="{x0:.1f}" y1="{y0:.1f}" x2="{x1:.1f}" y2="{y1:.1f}">'
        f'<stop offset="0" stop-color="{colors[0]}" stop-opacity="1"/>'
        f'<stop offset="1" stop-color="{colors[1]}" stop-opacity="0.92"/></linearGradient>'
    )


def write_rays(orders, colors, name):
    body = defs = ""
    for m in orders:
        path, ends = ray(m)
        gid = "g%d" % (m + 5)
        defs += gradient(gid, colors, *ends)
        body += f'<path d="{path}" fill="url(#{gid})"/>'
    with open(os.path.join(ASSETS, name), "w") as f:
        f.write(svg(body, defs))


def write_screen():
    """The opaque screen: three rounded bars, leaving two 24 pt slits 120 pt apart."""
    slit, height = 24, 44
    ox, oy = ORIGIN
    y = oy - height / 2
    left, right = ox - 60, ox + 60  # slit centres
    bars = [(208, left - slit / 2), (left + slit / 2, right - slit / 2), (right + slit / 2, 816)]
    body = "".join(
        '<rect x="%.1f" y="%.1f" width="%.1f" height="%d" rx="14" fill="%s"/>' % (a, y, b - a, height, SCREEN)
        for a, b in bars
    )
    with open(os.path.join(ASSETS, "slit.svg"), "w") as f:
        f.write(svg(body))


if __name__ == "__main__":
    os.makedirs(ASSETS, exist_ok=True)
    write_rays([0, -1, 1], YELLOW, "rays_yellow.svg")
    write_rays([-2, 2], GREY, "rays_grey.svg")
    write_screen()
