"""Porthole logo, design A "海天一线": a white porthole frame on coral, looking out at
sky, sea and a rising sun. Flat colours only.

Writes into design/logo/:
  porthole.svg        app icon artwork (1024 canvas, Apple icon grid: 824-pt rounded square)
  porthole-small.svg  the same, simplified for 16 and 32 px (no rivets, waves or reflection)
  porthole-mark.svg   round badge without the square, for the website header and favicon
Run: python3 design/logo/logo.py
"""
import math, os

HERE = os.path.dirname(os.path.abspath(__file__))

CORAL = "#FF6B4A"
WHITE = "#FFFFFF"
SKY = "#AEE0FF"
SEA = "#1F55E0"
SUN = "#FFD23F"

def squircle(cx=512, cy=512, r=412, n=5.0, steps=240):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append(f"{cx + r * math.copysign(abs(c) ** (2 / n), c):.1f} {cy + r * math.copysign(abs(s) ** (2 / n), s):.1f}")
    return "M" + " L".join(pts) + " Z"

def porthole(cx, cy, ring_r, glass_r, small, rivet_fill, uid):
    """Frame, glass and the view through it, centred on (cx, cy)."""
    k = glass_r / 205.0                      # the view was drawn for a 205-pt glass
    hz = cy + 36 * k                         # horizon, a little below centre
    x0, y0, w = cx - glass_r, cy - glass_r, 2 * glass_r
    view = (f'<rect x="{x0:.1f}" y="{y0:.1f}" width="{w:.1f}" height="{hz - y0:.1f}" fill="{SKY}"/>'
            f'<circle cx="{cx:.1f}" cy="{hz:.1f}" r="{(96 if small else 84) * k:.1f}" fill="{SUN}"/>'
            f'<rect x="{x0:.1f}" y="{hz:.1f}" width="{w:.1f}" height="{cy + glass_r - hz:.1f}" fill="{SEA}"/>')
    if not small:
        # the sun's reflection and two small waves
        for dy, half in ((34, 60), (70, 36), (106, 16)):
            view += (f'<rect x="{cx - half * k:.1f}" y="{hz + dy * k:.1f}" width="{2 * half * k:.1f}" height="{16 * k:.1f}" '
                     f'rx="{8 * k:.1f}" fill="{SUN}"/>')
        for wx, wy in ((-182, 52), (86, 96)):
            x, y = cx + wx * k, hz + wy * k
            view += (f'<path d="M{x:.1f} {y:.1f} q{24 * k:.1f} {-18 * k:.1f} {48 * k:.1f} 0 t{48 * k:.1f} 0" fill="none" '
                     f'stroke="{WHITE}" stroke-width="{14 * k:.1f}" stroke-linecap="round"/>')
    out = (f'<defs><clipPath id="{uid}"><circle cx="{cx:.1f}" cy="{cy:.1f}" r="{glass_r:.1f}"/></clipPath></defs>'
           f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{ring_r:.1f}" fill="{WHITE}"/>'
           f'<g clip-path="url(#{uid})">{view}</g>')
    if not small:
        mid = (ring_r + glass_r) / 2
        for i in range(8):
            a = math.radians(22.5 + i * 45)
            out += f'<circle cx="{cx + mid * math.cos(a):.1f}" cy="{cy + mid * math.sin(a):.1f}" r="{15 * k:.1f}" fill="{rivet_fill}"/>'
    return out

def svg(body, label="Porthole"):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="{label}">{body}</svg>\n'

files = {
    "porthole.svg": svg(f'<path d="{squircle()}" fill="{CORAL}"/>' + porthole(512, 512, 300, 205, False, CORAL, "g")),
    "porthole-small.svg": svg(f'<path d="{squircle()}" fill="{CORAL}"/>' + porthole(512, 512, 316, 205, True, CORAL, "g")),
    "porthole-mark.svg": svg(f'<circle cx="512" cy="512" r="500" fill="{CORAL}"/>' + porthole(512, 512, 400, 286, True, CORAL, "m")),
}
for name, data in files.items():
    open(os.path.join(HERE, name), "w").write(data)
    print("wrote", os.path.join("design/logo", name))
