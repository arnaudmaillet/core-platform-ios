#!/usr/bin/env python3
"""Imports the world's country borders the map draws and unlocks.

    Scripts/import-country-borders.py ne_50m_admin_0_countries.geojson

Source: Natural Earth 1:50m "Admin 0 – Countries" (public domain), from
https://github.com/nvkelso/natural-earth-vector (geojson/ne_50m_admin_0_countries.geojson).

Writes `Packages/Features/Maps/Sources/Maps/Resources/countries.json`, the
file `CountryAtlas` reads: one entry per country with its ISO code, English
name, continent, population estimate, label point (Natural Earth's own
"where to write the name" point — inside the country, unlike a centroid for a
crescent or an archipelago) and its polygons.

The polygons are SIMPLIFIED (Douglas–Peucker, `TOLERANCE` degrees) and their
coordinates rounded to `DECIMALS` places: the map draws borders at country
scale, and the full-resolution file is three times the size for detail no one
sees at the zoom a country is shown whole. Rings that collapse below four
points (islets) are dropped, except that every country keeps its largest ring.
"""

import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Packages/Features/Maps/Sources/Maps/Resources/countries.json"
TOLERANCE = 0.02
DECIMALS = 3


def perpendicular(point, start, end):
    (x, y), (x1, y1), (x2, y2) = point, start, end
    dx, dy = x2 - x1, y2 - y1
    if dx == 0 and dy == 0:
        return math.hypot(x - x1, y - y1)
    return abs(dy * x - dx * y + x2 * y1 - y2 * x1) / math.hypot(dx, dy)


def simplify(points, tolerance):
    """Iterative Douglas–Peucker (recursion blows the stack on long coasts)."""
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        first, last = stack.pop()
        best, index = 0.0, None
        for i in range(first + 1, last):
            distance = perpendicular(points[i], points[first], points[last])
            if distance > best:
                best, index = distance, i
        if index is not None and best > tolerance:
            keep[index] = True
            stack.append((first, index))
            stack.append((index, last))
    return [p for p, k in zip(points, keep) if k]


def ring_area(ring):
    return abs(sum(x1 * y2 - x2 * y1 for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]))) / 2


def rounded(ring):
    out = []
    for x, y in ring:
        point = [round(x, DECIMALS), round(y, DECIMALS)]
        if not out or out[-1] != point:
            out.append(point)
    return out


def polygons_of(geometry):
    if geometry["type"] == "Polygon":
        return [geometry["coordinates"]]
    if geometry["type"] == "MultiPolygon":
        return geometry["coordinates"]
    return []


def shapes(geometry, tolerance):
    polygons, largest = [], None
    for polygon in polygons_of(geometry):
        rings = []
        for index, ring in enumerate(polygon):
            points = [tuple(p) for p in ring]
            simple = rounded(simplify(points, tolerance) if tolerance > 0 else points)
            if len(simple) >= 4:
                rings.append(simple)
            elif index == 0:
                rings = None
                break
        if rings:
            polygons.append(rings)
        outer = [tuple(p) for p in polygon[0]]
        if largest is None or ring_area(outer) > ring_area(largest):
            largest = outer
    if not polygons and largest:
        polygons = [[rounded(largest)]]
    return polygons


def ring_contains(ring, x, y):
    inside, j = False, len(ring) - 1
    for i in range(len(ring)):
        (xi, yi), (xj, yj) = ring[i], ring[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            inside = not inside
        j = i
    return inside


def contains(polygon, x, y):
    inside = False
    for ring in polygon:
        if ring_contains(ring, x, y):
            inside = not inside
    return inside


def inside_point(polygon):
    """A point certainly inside `polygon`: the middle of the widest stretch
    of a horizontal line through its outer ring's vertical middle, holes
    counted."""
    ys = [y for _, y in polygon[0]]
    best, point = -1.0, polygon[0][0]
    for fraction in (0.5, 0.35, 0.65, 0.2, 0.8):
        y = min(ys) + (max(ys) - min(ys)) * fraction
        crossings = []
        for ring in polygon:
            for (x1, y1), (x2, y2) in zip(ring, ring[1:] + ring[:1]):
                if (y1 > y) != (y2 > y):
                    crossings.append(x1 + (y - y1) * (x2 - x1) / (y2 - y1))
        crossings.sort()
        for left, right in zip(crossings[0::2], crossings[1::2]):
            if right - left > best:
                best, point = right - left, ((left + right) / 2, y)
    return point


def code_of(properties):
    for key in ("ISO_A2", "ISO_A2_EH", "WB_A2"):
        value = properties.get(key)
        if value and value != "-99" and len(value) == 2:
            return value.upper()
    return None


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    source = json.loads(Path(sys.argv[1]).expanduser().read_text())
    countries = {}
    for feature in source["features"]:
        properties = feature["properties"]
        code = code_of(properties)
        if code is None:
            continue
        label = (properties["LABEL_X"], properties["LABEL_Y"])
        polygons = shapes(feature["geometry"], TOLERANCE)
        # ⚠️ A microstate (the Vatican, Macau…) simplifies to nothing, or to a
        # shape its own label point falls outside — and the label point is
        # where the map puts the country's annotation. Those keep their
        # unsimplified outline, which costs a few hundred points in all.
        if not any(contains(polygon, *label) for polygon in polygons):
            polygons = shapes(feature["geometry"], 0)
        # And where even the source's label point is offshore (it is for a
        # handful), a point that is inside: see `inside_point`.
        if not any(contains(polygon, *label) for polygon in polygons):
            label = inside_point(max(polygons, key=lambda p: ring_area(p[0])))
        entry = countries.setdefault(code, {
            "code": code,
            "name": properties.get("NAME_EN") or properties.get("NAME"),
            "continent": properties.get("CONTINENT"),
            "population": int(properties.get("POP_EST") or 0),
            "label": [round(label[0], DECIMALS), round(label[1], DECIMALS)],
            "polygons": [],
        })
        entry["polygons"] += polygons
    ordered = sorted(countries.values(), key=lambda c: c["code"])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(ordered, separators=(",", ":"), ensure_ascii=False))
    points = sum(len(r) for c in ordered for p in c["polygons"] for r in p)
    print(f"{len(ordered)} countries, {points} points, {OUT.stat().st_size / 1_000_000:.2f} MB → {OUT}")


if __name__ == "__main__":
    main()
