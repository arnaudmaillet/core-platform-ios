#!/usr/bin/env python3
"""Rewrites wand/wand.svg. Argument: how far the wand bows from a straight line (px on 1024), or `half` for an exact half circle (the shipped one)."""
import math, sys
from pathlib import Path

ARG = sys.argv[1] if len(sys.argv) > 1 else "50"
OUT = Path(__file__).resolve().parent / "wand"
W = 1024
TIP, END = (W - 341, 358), (W - 802, 802)          # tip top-right, end bottom-left (mirrored layout)
HALF, WALL = 32.0, 16.0

# Circle through TIP and END bowing up-left by SAGITTA
mx, my = (TIP[0] + END[0]) / 2, (TIP[1] + END[1]) / 2
dx, dy = END[0] - TIP[0], END[1] - TIP[1]
c = math.hypot(dx, dy)
SAGITTA = c / 2 if ARG == "half" else float(ARG)
nx, ny = dy / c, -dx / c                            # normal pointing up-left
if nx > 0:
    nx, ny = -nx, -ny
R = (c * c / 4 + SAGITTA ** 2) / (2 * SAGITTA)
CX, CY = mx - nx * (R - SAGITTA), my - ny * (R - SAGITTA)
A0 = math.atan2(TIP[1] - CY, TIP[0] - CX)
A1 = math.atan2(END[1] - CY, END[0] - CX)
AP = math.atan2(my + ny * SAGITTA - CY, mx + nx * SAGITTA - CX)   # the apex, on the bowing side
D = (A1 - A0) % (2 * math.pi)                                    # one way round...
if abs(((A0 + D / 2) - AP + math.pi) % (2 * math.pi) - math.pi) > 1e-6:
    D -= 2 * math.pi                                             # ...or the other, whichever passes the apex
S1, S2 = A0 + 0.35 * D, A0 + 0.65 * D               # solid band in the middle third
fwd = 1 if D > 0 else 0                              # sweep flag for travelling tip -> end

def pt(r, a):
    return f"{CX + r * math.cos(a):.2f} {CY + r * math.sin(a):.2f}"

def arc(r, to, sweep):
    return f"A{r:.2f} {r:.2f} 0 0 {sweep} {to}"

ro, ri, h = R + HALF, R - HALF, HALF - WALL
hro, hri = R + h, R - h
AM = A0 + D / 2
wand = (f"M{pt(ro, A0)} {arc(ro, pt(ro, AM), fwd)} {arc(ro, pt(ro, A1), fwd)} {arc(HALF, pt(ri, A1), fwd)} "
        f"{arc(ri, pt(ri, AM), 1 - fwd)} {arc(ri, pt(ri, A0), 1 - fwd)} {arc(HALF, pt(ro, A0), fwd)} Z")
hole_tip = (f"M{pt(hro, S1)} {arc(hro, pt(hro, A0), 1 - fwd)} {arc(h, pt(hri, A0), 1 - fwd)} "
            f"{arc(hri, pt(hri, S1), fwd)} Z")
hole_end = (f"M{pt(hro, S2)} {arc(hro, pt(hro, A1), fwd)} {arc(h, pt(hri, A1), fwd)} "
            f"{arc(hri, pt(hri, S2), 1 - fwd)} Z")

def svg(body, comment):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">\n'
            f'  <!-- {comment} -->\n{body}\n</svg>\n')

wand_body = f'  <path fill="#000000" fill-rule="evenodd" d="{wand} {hole_tip} {hole_end}"/>'
(OUT / "wand.svg").write_text(svg(wand_body, "Wand: bent along an arc, tip top-right; hollow at both ends, solid band in the middle."))
bubbles = [l for n in ("bubble-large", "bubble-medium", "bubble-small")
           for l in (OUT / f"{n}.svg").read_text().splitlines() if "<circle" in l]
if "--with-bubbles" in sys.argv: (OUT / "all.svg").write_text(svg("\n".join([wand_body, *bubbles]), "Preview only: every element together. Each one also has its own file, on the same 1024 canvas."))
print(f"R={R:.0f} bow={SAGITTA:.0f}px end-tangent offset={math.degrees(4 * SAGITTA / c):.0f}°")
