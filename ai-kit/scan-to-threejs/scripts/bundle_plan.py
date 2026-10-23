#!/usr/bin/env python3
"""Top-down plan of a House Capture bundle: walls, doors/windows, furniture boxes,
and every photo's camera position + view direction. Quick check of what was
captured (and what wasn't) before modeling.

usage: bundle_plan.py <bundle_dir> [-o plan.png] [--ppm 120]
Prints a summary per wall: length, height, confidence, openings, photos facing it.
"""
import argparse
import json
import math
import os

from PIL import Image, ImageDraw


def mat(t):  # column-major 16 → rows helper
    return [[t[c * 4 + r] for c in range(4)] for r in range(4)]


def col(m, c):
    return [m[0][c], m[1][c], m[2][c]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('bundle')
    ap.add_argument('-o', default=None)
    ap.add_argument('--ppm', type=float, default=120)
    ap.add_argument('--room', type=int, help='room index when the session is not finalized')
    a = ap.parse_args()
    source = 'structure.json' if a.room is None else f'rooms/room-{a.room}.json'
    S = json.load(open(os.path.join(a.bundle, source)))
    photos_path = os.path.join(a.bundle, 'photos/photos.json')
    photos = json.load(open(photos_path)) if os.path.exists(photos_path) else []
    if a.room is not None:
        photos = [p for p in photos if p.get('room') == a.room]

    def seg(el):
        m = mat(el['transform'])
        c, x = col(m, 3), col(m, 0)
        w = el['dimensions'][0] / 2
        return (c[0] - x[0] * w, c[2] - x[2] * w), (c[0] + x[0] * w, c[2] + x[2] * w), c

    walls = {w['identifier']: w for w in S['walls']}
    pts = [p for w in S['walls'] for p in seg(w)[:2]]
    minx, maxx = min(p[0] for p in pts) - 0.6, max(p[0] for p in pts) + 0.6
    minz, maxz = min(p[1] for p in pts) - 0.6, max(p[1] for p in pts) + 0.6
    W, H = int((maxx - minx) * a.ppm), int((maxz - minz) * a.ppm)
    img = Image.new('RGB', (W, H), (18, 18, 22))
    d = ImageDraw.Draw(img)
    P = lambda x, z: ((x - minx) * a.ppm, (z - minz) * a.ppm)

    # 0.5 m grid
    for gx in range(math.floor(minx * 2), math.ceil(maxx * 2) + 1):
        d.line([P(gx / 2, minz), P(gx / 2, maxz)], fill=(40, 40, 50) if gx % 2 else (60, 60, 75))
    for gz in range(math.floor(minz * 2), math.ceil(maxz * 2) + 1):
        d.line([P(minx, gz / 2), P(maxx, gz / 2)], fill=(40, 40, 50) if gz % 2 else (60, 60, 75))

    # furniture
    for o in S['objects']:
        m = mat(o['transform'])
        c, x, z = col(m, 3), col(m, 0), col(m, 2)
        hw, hd = o['dimensions'][0] / 2, o['dimensions'][2] / 2
        corners = [(c[0] + x[0] * sx * hw + z[0] * sz * hd, c[2] + x[2] * sx * hw + z[2] * sz * hd) for sx, sz in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        d.polygon([P(*p) for p in corners], outline=(230, 170, 60), fill=(70, 55, 30))
        d.text(P(c[0], c[2]), next(iter(o['category'])), fill=(255, 210, 120))

    # walls, colored by confidence
    conf_color = {'high': (235, 235, 235), 'medium': (240, 200, 60), 'low': (240, 80, 60)}
    for w in S['walls']:
        a0, a1, _ = seg(w)
        d.line([P(*a0), P(*a1)], fill=conf_color.get(next(iter(w['confidence'])), (255, 0, 255)), width=5)
    for kind, color in (('doors', (80, 200, 255)), ('windows', (120, 255, 160)), ('openings', (200, 120, 255))):
        for e in S.get(kind, []):
            a0, a1, _ = seg(e)
            d.line([P(*a0), P(*a1)], fill=color, width=9)

    # photos: dot + view direction (camera looks down -Z)
    for ph in photos:
        m = mat(ph['transform'])
        c, f = col(m, 3), col(m, 2)
        fx, fz = -f[0], -f[2]
        n = math.hypot(fx, fz) or 1
        p0 = P(c[0], c[2])
        p1 = P(c[0] + fx / n * 0.35, c[2] + fz / n * 0.35)
        d.line([p0, p1], fill=(255, 90, 160), width=2)
        d.ellipse([p0[0] - 3, p0[1] - 3, p0[0] + 3, p0[1] + 3], fill=(255, 90, 160))

    out = a.o or os.path.join(a.bundle, 'plan.png')
    img.save(out)

    # per-wall summary: which walls are seen head-on by some photo
    print(f'{len(S["walls"])} walls, {len(S["doors"])} doors, {len(S["windows"])} windows, {len(S["openings"])} openings, '
          f'{len(S["objects"])} objects, {len(photos)} photos')
    # same rule as the app's coverage map (Coverage.swift): 0.5 m wall segments; a photo
    # covers one if it's 0.3-4.5 m away, inside the central 60 deg, and within ~70 deg of head-on
    def sees(ph, p, n=None):
        pm = mat(ph['transform'])
        pc, f = col(pm, 3), col(pm, 2)
        v = [p[k] - pc[k] for k in range(3)]
        dist = math.sqrt(sum(x * x for x in v))
        if not 0.3 < dist < 4.5:
            return False
        fl = math.sqrt(sum(x * x for x in f)) or 1
        if sum(-f[k] * v[k] for k in range(3)) / dist / fl < math.cos(math.pi / 6):
            return False
        if n is not None and abs(sum(n[k] * v[k] for k in range(3)) / dist) < 0.35:
            return False
        return True

    for i, w in enumerate(S['walls']):
        m = mat(w['transform'])
        c, x, nrm = col(m, 3), col(m, 0), col(m, 2)
        width = w['dimensions'][0]
        nseg = max(1, round(width / 0.5))
        covered = 0
        for s in range(nseg):
            off = (s + 0.5) / nseg * width - width / 2
            p = [c[k] + x[k] * off for k in range(3)]
            covered += any(sees(ph, p, nrm) for ph in photos)
        kids = [k for kind in ('doors', 'windows', 'openings') for k in S.get(kind, []) if k.get('parentIdentifier') == w['identifier']]
        print(f'  wall {i:2d}: {width:.2f} x {w["dimensions"][1]:.2f} m  conf={next(iter(w["confidence"]))}'
              f'  openings={len(kids)}  photographed {covered}/{nseg} segments')
    print(out)


if __name__ == '__main__':
    main()
