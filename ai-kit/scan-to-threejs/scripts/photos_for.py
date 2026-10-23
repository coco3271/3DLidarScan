#!/usr/bin/env python3
"""Which photos show a room-coordinate point, best first (close + head-on + in frame).

usage: photos_for.py <room.json from bundle_to_room.py> x y z [--n 8]
Prints photo index, distance, where in the (upright) image the point lands (fractions),
so you can open the right photo and read the detail you need.
"""
import sys, json, math, numpy as np
path, x, y, z, *rest = sys.argv[1:]
n = int(rest[rest.index('--n') + 1]) if '--n' in rest else 8
r = json.load(open(path)); p = np.array([float(x), float(y), float(z)])
out = []
for i, ph in enumerate(r['photos']):
    pos, f, up = np.array(ph['position']), np.array(ph['forward']), np.array(ph['up'])
    right = np.cross(f, up)
    v = p - pos; d = np.dot(v, f)
    if d <= 0.2: continue
    th = math.tan(math.radians(ph['fovY'] / 2)); tw = th * ph['aspect']
    sx, sy = np.dot(v, right) / d / tw, np.dot(v, up) / d / th
    if abs(sx) > 1 or abs(sy) > 1: continue
    dist = np.linalg.norm(v)
    out.append((dist * (1 + 0.5 * (sx * sx + sy * sy)), i, dist, (sx + 1) / 2, (1 - sy) / 2))
for s, i, dist, fx, fy in sorted(out)[:n]:
    print(f'photo {i:3d}  dist {dist:.2f} m  at ({fx:.2f}, {fy:.2f}) of the upright image  ({r["photos"][i]["file"]})')
