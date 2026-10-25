#!/usr/bin/env python3
"""Traces the app icon's four pieces from `mark.png` into the Fourier table of
`AppLoaderGeometry.iconHarmonics` (#1744).

`mark.png` is the owner's 900x900 render of the mark, the held frame of the
#1744 reference renders (the loader's side is 660 px there, centred). Each
piece is found by its loader tone, its outline traced along rays from its
centroid at the anti-aliased 50 % coverage, then kept as the harmonics -12..12
of the closed outline in unit coordinates. The mark is re-centred and scaled
so it is inscribed in the disc of diameter = side, as the ring is.

    ./trace.py > table.swift    # needs numpy and ffmpeg
"""
import subprocess, sys
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
SIDE, ORIGIN, ORDER = 660.0, 120.0, 12
TONES = [(0xF3, 0x7A, 0xB4), (0xA7, 0x8B, 0xFA), (0xC0, 0x8B, 0xE6), (0xD9, 0x8A, 0xD0)]
NAMES = ["top-left, pink", "top-right, violet", "bottom-right, mauve", "bottom-left, orchid"]

raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(HERE / "mark.png"), "-f", "rawvideo",
                      "-pix_fmt", "rgb24", "-"], check=True, capture_output=True).stdout
img = np.frombuffer(raw, np.uint8).reshape(900, 900, 3).astype(float)
bg = np.array([255.0, 255, 255])
T = np.array(TONES, float)
dist = ((img[:, :, None, :] - T[None, None]) ** 2).sum(3)
label = np.argmin(dist, 2)
foreground = np.abs(img - bg).sum(2) > 200


def dilate(mask, k):
    out = mask.copy()
    for dy in range(-k, k + 1):
        for dx in range(-k, k + 1):
            out |= np.roll(np.roll(mask, dy, 0), dx, 1)
    return out


def bilinear(a, x, y):
    x0 = np.clip(np.floor(x).astype(int), 0, 898)
    y0 = np.clip(np.floor(y).astype(int), 0, 898)
    fx, fy = x - x0, y - y0
    return (a[y0, x0] * (1 - fx) * (1 - fy) + a[y0, x0 + 1] * fx * (1 - fy)
            + a[y0 + 1, x0] * (1 - fx) * fy + a[y0 + 1, x0 + 1] * fx * fy)


def resample(points, n):
    closed = np.vstack([points, points[:1]])
    cumulative = np.concatenate([[0], np.cumsum(np.hypot(*np.diff(closed, axis=0).T))])
    s = np.linspace(0, cumulative[-1], n, endpoint=False)
    return np.interp(s, cumulative, closed[:, 0]) + 1j * np.interp(s, cumulative, closed[:, 1])


series = []
for i, tone in enumerate(T):
    core = foreground & (label == i) & (dist[:, :, i] < 400)
    d = tone - bg
    alpha = np.clip(((bg - img) @ (-d)) / (d @ d), 0, 1) * dilate(core, 4)
    ys, xs = np.nonzero(core)
    cx, cy = xs.mean() + 0.5, ys.mean() + 0.5
    theta = np.linspace(0, 2 * np.pi, 2048, endpoint=False)
    r = np.arange(0, 420, 0.125)
    a = bilinear(alpha, cx + np.outer(np.cos(theta), r) - 0.5, cy + np.outer(np.sin(theta), r) - 0.5)
    outline = []
    for k in range(len(theta)):
        j = np.nonzero(a[k] < 0.5)[0][0]
        assert not (a[k][j:] >= 0.5).any(), "a piece is not star-shaped from its centroid"
        edge = r[j - 1] + (a[k][j - 1] - 0.5) / (a[k][j - 1] - a[k][j]) * (r[j] - r[j - 1])
        outline.append((cx + edge * np.cos(theta[k]), cy + edge * np.sin(theta[k])))
    z = resample((np.array(outline) - ORIGIN) / SIDE, 1024)
    f = np.fft.fft(z) / len(z)
    series.append({k: f[k] for k in range(-ORDER, ORDER + 1)})

# Inscribed in the disc: the centre that puts every piece's furthest point at
# the same distance, then that distance scaled to 0.5.
t = np.arange(4096) / 4096
curves = [sum(c * np.exp(2j * np.pi * k * t) for k, c in s.items()) for s in series]
grid = np.linspace(0.49, 0.51, 81)
_, centre = min((np.std([np.abs(z - (x + 1j * y)).max() for z in curves]), x + 1j * y)
                for x in grid for y in grid)
scale = 0.5 / np.mean([np.abs(z - centre).max() for z in curves])

for name, s in zip(NAMES, series):
    print(f"        // {name}\n        [")
    for k in range(-ORDER, ORDER + 1):
        c = s[k] * scale if k else (s[k] - centre) * scale + (0.5 + 0.5j)
        print("            %s, %s," % tuple(("%.5f" % v).replace("-0.00000", "0.00000") for v in (c.real, c.imag)))
    print("        ],")
print(f"centre {centre:.4f}, scale {scale:.5f}", file=sys.stderr)
