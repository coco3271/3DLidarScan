#!/usr/bin/env python3
"""Turn a 3D LiDAR Scan export (house-capture/5 bundle, folder or .zip) into a clean, measured
3D model of the property: the "architectural dollhouse" look, with thick cut-away walls, framed
doors and windows, floors textured from your photos, furniture in its real place, size and
color, soft shadows, on a blueprint grid. It opens offline in any browser.

usage: make_model.py <bundle-folder-or-zip> [-o house-model] [--max-photos 60] [--no-colors]
       make_model.py <house-model-folder>       (rebuild model.html after editing model.json)

Writes a folder:
  model.json   everything the viewer draws (rooms, walls, openings, furniture, materials,
               photo cameras). Edit it, by hand or with an AI, then run the second form.
  textures/    floor swatches cut out of your photos
  photos/      the photos, for the viewer's photo-compare mode
  model.html   one offline file with all of the above embedded

The walls, doors, windows and furniture come from Apple RoomPlan (already measured); colors and
floor textures come from the photos, checked against each photo's LiDAR depth so a sofa in
front of a wall never paints the wall. Colors need numpy and Pillow; without them the model is
built with neutral colors.
"""
import argparse
import base64
import io
import json
import math
import os
import sys
import zlib

sys.dont_write_bytecode = True  # this folder ships inside the zip: keep it clean
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_walkthrough import THREE, TEMPLATE, Bundle, evenly, html_escape, shrink_jpeg  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
VIEWER = os.path.join(HERE, 'model', 'house.js')

try:
    import numpy as np
    from PIL import Image, ImageFilter
except ImportError:  # colors and textures are skipped
    np = None

# RoomPlan object categories → house.js builders (same names, listed so new ones fall back)
TYPES = {'storage', 'refrigerator', 'stove', 'bed', 'sink', 'washerDryer', 'toilet', 'bathtub', 'oven',
         'dishwasher', 'table', 'sofa', 'chair', 'fireplace', 'television', 'stairs'}
DEFAULT_COLORS = {'bed': '#d8d2c8', 'sofa': '#8f8a83', 'chair': '#4b4b50', 'table': '#9a6b43', 'storage': '#e8e3da'}


# ---- small linear algebra (column-major 4x4 lists, like ARKit) ------------------------------------

def rows(t):
    return [[t[c * 4 + r] for c in range(4)] for r in range(4)]


def col(m, c):
    return [m[0][c], m[1][c], m[2][c]]


def mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def apply(m, p, w=1.0):
    v = [p[0], p[1], p[2], w]
    return [sum(m[i][k] * v[k] for k in range(4)) for i in range(3)]


def colmajor(m):
    return [m[r][c] for c in range(4) for r in range(4)]


def r4(v, n=4):
    return [round(x, n) for x in v]


def kind_of(e):
    return next(iter(e.get('category') or {'unknown': {}}))


# ---- the model frame: floor at y = 0, walls along x/z, house centered --------------------------------

def model_frame(walls, floors):
    """world → model transform (rows), like bundle_to_room.py but for the whole house"""
    if floors:
        ys = sorted(rows(f['transform'])[1][3] for f in floors)
        floor_y = ys[len(ys) // 2]
    elif walls:
        floor_y = min(rows(w['transform'])[1][3] - w['dimensions'][1] / 2 for w in walls)
    else:
        floor_y = 0.0
    sx = sy = 0.0
    for w in walls:
        x = col(rows(w['transform']), 0)
        ang = math.atan2(x[2], x[0]) * 4  # ×4 folds the 90° symmetry of a floor plan
        sx += math.cos(ang) * w['dimensions'][0]
        sy += math.sin(ang) * w['dimensions'][0]
    theta = math.atan2(sy, sx) / 4 if walls else 0.0
    c, s = math.cos(-theta), math.sin(-theta)
    R = [[c, 0, -s, 0], [0, 1, 0, 0], [s, 0, c, 0], [0, 0, 0, 1]]
    ends = []
    for w in walls:
        m = rows(w['transform'])
        ctr, x = col(m, 3), col(m, 0)
        for sgn in (-1, 1):
            ends.append(apply(R, [ctr[0] + x[0] * sgn * w['dimensions'][0] / 2, 0, ctr[2] + x[2] * sgn * w['dimensions'][0] / 2]))
    cx = (min(e[0] for e in ends) + max(e[0] for e in ends)) / 2 if ends else 0
    cz = (min(e[2] for e in ends) + max(e[2] for e in ends)) / 2 if ends else 0
    return mul([[1, 0, 0, -cx], [0, 1, 0, -floor_y], [0, 0, 1, -cz], [0, 0, 0, 1]], R)


# ---- rooms, walls, openings, furniture -------------------------------------------------------------

def inside(poly, x, z):
    hit = False
    for i in range(len(poly)):
        (x1, z1), (x2, z2) = poly[i], poly[(i + 1) % len(poly)]
        if (z1 > z) != (z2 > z) and x < x1 + (z - z1) * (x2 - x1) / (z2 - z1):
            hit = not hit
    return hit


def area(poly):
    return abs(sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1] for i in range(len(poly)))) / 2


def room_polygon(R, W2R):
    """the floor outline in model x/z from RoomPlan's floor (or its walls when it has none)"""
    for f in R.get('floors') or []:
        fm = rows(f['transform'])
        corners = f.get('polygonCorners') or []
        if len(corners) < 3:
            w, d = f['dimensions'][0] / 2, f['dimensions'][1] / 2
            corners = [[-w, -d, 0], [w, -d, 0], [w, d, 0], [-w, d, 0]]
        pts = [apply(W2R, apply(fm, p)) for p in corners]
        return [[round(p[0], 4), round(p[2], 4)] for p in pts]
    ends = []
    for w in R.get('walls') or []:
        m = rows(w['transform'])
        ctr, x = apply(W2R, col(m, 3)), apply(W2R, col(m, 0), 0.0)
        for s in (-1, 1):
            ends.append((ctr[0] + x[0] * s * w['dimensions'][0] / 2, ctr[2] + x[2] * s * w['dimensions'][0] / 2))
    if len(ends) < 3:
        return None
    cx, cz = sum(e[0] for e in ends) / len(ends), sum(e[1] for e in ends) / len(ends)
    ends.sort(key=lambda e: math.atan2(e[1] - cz, e[0] - cx))
    return [[round(x, 4), round(z, 4)] for x, z in ends]


def wall_segments(R, W2R):
    """RoomPlan walls → {a, b, height, openings (u along a→b, v above the floor)}"""
    kids = {}
    for kind in ('doors', 'windows', 'openings'):
        for e in R.get(kind) or []:
            kids.setdefault(e.get('parentIdentifier'), []).append(e)
    out = []
    for w in R.get('walls') or []:
        m = rows(w['transform'])
        ctr, u = apply(W2R, col(m, 3)), apply(W2R, col(m, 0), 0.0)
        L, H = w['dimensions'][0], w['dimensions'][1]
        a = [ctr[0] - u[0] * L / 2, ctr[2] - u[2] * L / 2]
        b = [ctr[0] + u[0] * L / 2, ctr[2] + u[2] * L / 2]
        ops = []
        for e in kids.get(w['identifier'], []):
            ec = apply(W2R, col(rows(e['transform']), 3))
            du = (ec[0] - a[0]) * u[0] + (ec[2] - a[1]) * u[2]
            ew, eh = e['dimensions'][0], e['dimensions'][1]
            kind = kind_of(e)
            v0 = ec[1] - eh / 2
            op = {'kind': kind if kind in ('door', 'window') else 'opening', 'u0': du - ew / 2, 'u1': du + ew / 2,
                  'v0': 0.0 if v0 < 0.08 else v0, 'v1': ec[1] + eh / 2}
            if kind == 'door' and (e['category']['door'] or {}).get('isOpen'):
                op['open'] = True
            ops.append(op)
        out.append({'a': a, 'b': b, 'height': H, 'openings': ops})
    return out


def merge_walls(walls):
    """Two rooms scan the two faces of the wall between them: make that one wall, centered
    between the faces and as thick as the gap. Also folds duplicate scans of one wall."""
    walls = [dict(w) for w in walls]
    changed = True
    while changed:
        changed = False
        for i in range(len(walls)):
            for j in range(i + 1, len(walls)):
                m = try_merge(walls[i], walls[j])
                if m:
                    walls[i] = m
                    del walls[j]
                    changed = True
                    break
            if changed:
                break
    return walls


def seg(w):
    ax, az = w['a']
    dx, dz = w['b'][0] - ax, w['b'][1] - az
    L = math.hypot(dx, dz)
    return ax, az, dx / L, dz / L, L


def try_merge(A, B):
    ax, az, ux, uz, LA = seg(A)
    bx, bz, vx, vz, LB = seg(B)
    if LA < 0.05 or LB < 0.05 or abs(ux * vx + uz * vz) < 0.985:
        return None
    nx, nz = -uz, ux
    t = lambda x, z: (x - ax) * ux + (z - az) * uz
    tb0, tb1 = t(*B['a']), t(*B['b'])
    lo, hi = min(tb0, tb1), max(tb0, tb1)
    overlap = min(LA, hi) - max(0.0, lo)
    if overlap < 0.5 * min(LA, LB):
        return None
    mid = ((B['a'][0] + B['b'][0]) / 2, (B['a'][1] + B['b'][1]) / 2)
    sep = (mid[0] - ax) * nx + (mid[1] - az) * nz
    if abs(sep) > 0.45:
        return None
    t0, t1 = min(0.0, lo), max(LA, hi)
    off = sep / 2
    a = [ax + ux * t0 + nx * off, az + uz * t0 + nz * off]
    b = [ax + ux * t1 + nx * off, az + uz * t1 + nz * off]
    ops = [dict(o, u0=o['u0'] - t0, u1=o['u1'] - t0) for o in A['openings']]
    s = 1 if ux * vx + uz * vz > 0 else -1
    for o in B['openings']:
        p0, p1 = tb0 + s * o['u0'] - t0, tb0 + s * o['u1'] - t0
        ops.append(dict(o, u0=min(p0, p1), u1=max(p0, p1)))
    merged = {'a': a, 'b': b, 'height': max(A['height'], B['height']), 'openings': merge_openings(ops), 'centered': True}
    gap = abs(sep)
    if gap > 0.06 or A.get('thickness') or B.get('thickness'):
        merged['thickness'] = round(min(0.35, max(0.1, gap, A.get('thickness', 0), B.get('thickness', 0))), 3)
    return merged


def merge_openings(ops):
    """one door seen from both rooms is one door"""
    out = []
    for o in sorted(ops, key=lambda o: o['u0']):
        last = out[-1] if out else None
        if last and last['kind'] == o['kind'] and o['u0'] < last['u1'] - 0.05:
            last.update(u1=max(last['u1'], o['u1']), v0=min(last['v0'], o['v0']), v1=max(last['v1'], o['v1']))
            if o.get('open'):
                last['open'] = True
        else:
            out.append(dict(o))
    return out


def orient_walls(walls, polys):
    """n points into the room; a wall with rooms on both sides straddles its line"""
    for w in walls:
        ax, az, ux, uz, L = seg(w)
        nx, nz = -uz, ux
        mx, mz = ax + ux * L / 2, az + uz * L / 2
        T = w.get('thickness', 0.12)
        probe = max(0.15, T / 2 + 0.1)
        front = any(inside(p, mx + nx * probe, mz + nz * probe) for p in polys)
        back = any(inside(p, mx - nx * probe, mz - nz * probe) for p in polys)
        if front and back:
            w['centered'] = True
        elif back and not w.get('centered'):
            w['a'], w['b'] = w['b'], w['a']
            w['openings'] = [dict(o, u0=L - o['u1'], u1=L - o['u0']) for o in w['openings']]
        w['openings'] = sorted(w['openings'], key=lambda o: o['u0'])
    return walls


def furniture(objects, W2R):
    items = []
    for o in objects:
        m = rows(o['transform'])
        ctr = apply(W2R, col(m, 3))
        f = apply(W2R, col(m, 2), 0.0)
        w, h, d = o['dimensions']
        if ctr[1] - h / 2 < 0.06:
            ctr[1] = h / 2  # resting on the floor
        cat = kind_of(o)
        items.append({'type': cat if cat in TYPES else 'box', 'category': cat, 'center': r4(ctr, 3), 'size': r4([w, h, d], 3),
                      'rotY': round(math.atan2(f[0], f[2]), 4)})
    # the same object seen from two rooms
    out = []
    for it in sorted(items, key=lambda i: -i['size'][0] * i['size'][1] * i['size'][2]):
        if not any(o['category'] == it['category'] and math.dist(o['center'], it['center']) < 0.35 for o in out):
            out.append(it)
    return out


# ---- colors and textures from the photos, checked against each photo's LiDAR depth ------------------

class Views:
    """The photos that have a paired depth frame, in the model frame."""

    def __init__(self, bundle, photos, frames, W2R, edge=768):
        self.views = []
        self.bundle = bundle
        by_file = {f['file']: f for f in frames}
        Wm = np.array(W2R, dtype=np.float64)
        for p in photos:
            fr = by_file.get(p.get('depthFrame'))
            if not fr or not bundle.has(p['file']) or not bundle.has(fr['file']):
                continue
            try:
                raw = bundle.read(fr['file'])
                if fr['file'].endswith('.f16z'):
                    raw = zlib.decompress(raw, -15)
                depth = np.frombuffer(raw, '<f2').astype(np.float32).reshape(fr['height'], fr['width'])
                conf = None
                if fr.get('confidence') and bundle.has(fr['confidence']):
                    conf = np.frombuffer(bundle.read(fr['confidence']), np.uint8).reshape(fr['height'], fr['width'])
                img = Image.open(io.BytesIO(bundle.read(p['file'])))  # sensor orientation, like the intrinsics
                img.draft('RGB', (edge, edge))
                img = img.convert('RGB')
            except Exception as e:  # a damaged file only loses that view
                print(f'  skipping {p["file"]}: {e}')
                continue
            scale = img.width / p['width']
            K = p['intrinsics']
            self.views.append({
                'file': p['file'], 'full': (p['width'], p['height']), 'size': img.size,
                # a little blur so one sample reads a few pixels; uint8 keeps 100+ photos in memory
                'pix': np.asarray(img.filter(ImageFilter.BoxBlur(2))), 'K': (K[0] * scale, K[4] * scale, K[6] * scale, K[7] * scale),
                'cam': Wm @ np.array(rows(p['transform'])), 'depth': depth, 'conf': conf,
                'dK': (fr['intrinsics'][0], fr['intrinsics'][4], fr['intrinsics'][6], fr['intrinsics'][7]),
                'dcam': Wm @ np.array(rows(fr['transform'])),
            })
        for v in self.views:
            v['inv'], v['dinv'] = np.linalg.inv(v['cam']), np.linalg.inv(v['dcam'])

    @staticmethod
    def project(inv, K, pts):
        """model points → (u, v, distance) for a camera (inverse pose) looking down -z, y up"""
        c = pts @ inv[:3, :3].T + inv[:3, 3]
        d = -c[:, 2]
        with np.errstate(divide='ignore', invalid='ignore'):
            u = K[0] * c[:, 0] / d + K[2]
            v = K[3] - K[1] * c[:, 1] / d
        return u, v, d

    def surface(self, view, pts):
        """Where each point's depth ray actually hits (the nearest surface), or nan"""
        u, v, d = self.project(view['dinv'], view['dK'], pts)
        h, w = view['depth'].shape
        ok = (d > 0.1) & (u >= 0) & (u < w - 0.5) & (v >= 0) & (v < h - 0.5)
        hit = np.full(pts.shape, np.nan)
        iu, iv = np.clip(np.round(u), 0, w - 1).astype(int), np.clip(np.round(v), 0, h - 1).astype(int)
        D = view['depth'][iv, iu]
        if view['conf'] is not None:
            ok &= view['conf'][iv, iu] >= 1
        ok &= np.isfinite(D) & (D > 0.1)
        cam = view['dcam']
        local = np.stack([(u - view['dK'][2]) / view['dK'][0] * D, -(v - view['dK'][3]) / view['dK'][1] * D, -D], 1)
        world = local @ cam[:3, :3].T + cam[:3, 3]
        hit[ok] = world[ok]
        return hit, d

    def sample(self, pts, boxes, groups):
        """Color per group from every photo that sees its points unoccluded.
        boxes: per point (center xyz, rotY, half sizes xyz): the depth hit must land in it."""
        acc = {}
        if not len(pts):
            return {}
        ctr, rot, half = boxes[:, :3], boxes[:, 3], boxes[:, 4:]
        cs, sn = np.cos(-rot), np.sin(-rot)
        for view in self.views:
            hit, dist = self.surface(view, pts)
            rel = hit - ctr
            lx, lz = rel[:, 0] * cs + rel[:, 2] * sn, -rel[:, 0] * sn + rel[:, 2] * cs
            ok = (np.abs(lx) <= half[:, 0]) & (np.abs(rel[:, 1]) <= half[:, 1]) & (np.abs(lz) <= half[:, 2])
            if not ok.any():
                continue
            u, v, d = self.project(view['inv'], view['K'], np.nan_to_num(hit))
            H, W = view['pix'].shape[:2]
            ok &= (d > 0.1) & (u >= 0) & (u < W - 1) & (v >= 0) & (v < H - 1)
            idx = np.nonzero(ok)[0]
            if not len(idx):
                continue
            rgb = view['pix'][v[idx].astype(int), u[idx].astype(int)].astype(np.float32)
            wgt = 1 / (1 + d[idx] ** 2)
            for g in np.unique(groups[idx]):
                sel = groups[idx] == g
                acc.setdefault(int(g), []).append((rgb[sel], wgt[sel]))
        out = {}
        for g, parts in acc.items():
            rgb = np.concatenate([p[0] for p in parts])
            wgt = np.concatenate([p[1] for p in parts])
            if len(rgb) < 6:
                continue
            # drop highlights and deep shadows, then a weighted mean
            lum = rgb @ np.array([0.299, 0.587, 0.114])
            lo, hi = np.percentile(lum, [20, 80])
            keep = (lum >= lo) & (lum <= hi)
            if keep.sum() < 3:
                keep[:] = True
            out[g] = (np.average(rgb[keep], axis=0, weights=wgt[keep]), int(len(rgb)))
        return out

    def floor_swatch(self, poly, out_path, min_res, size_px=512):
        """Cut the best-photographed square of floor out of one photo, flattened, for tiling"""
        xs, zs = [p[0] for p in poly], [p[1] for p in poly]
        span = min(max(xs) - min(xs), max(zs) - min(zs))
        here = [v for v in self.views if inside(poly, v['cam'][0, 3], v['cam'][2, 3])]
        # prefer photos taken in the room; photos through a doorway only when those can't do it
        for views in (here, [v for v in self.views if not any(v is h for h in here)]):
            best = None
            for S in (1.2, 0.9, 0.6):
                if S > span - 0.3:
                    continue
                g = np.linspace(-S / 2, S / 2, 7)
                grid = np.array([(x, 0.0, z) for x in g for z in g])
                centers = [(x, z) for x in np.arange(min(xs) + S / 2 + 0.15, max(xs) - S / 2 - 0.15 + 1e-6, 0.4)
                           for z in np.arange(min(zs) + S / 2 + 0.15, max(zs) - S / 2 - 0.15 + 1e-6, 0.4)
                           if all(inside(poly, x + dx, z + dz) for dx in (-S / 2, S / 2) for dz in (-S / 2, S / 2))]
                for cx, cz in centers:
                    pts = grid + [cx, 0, cz]
                    for view in views:
                        hit, _ = self.surface(view, pts)
                        if np.isnan(hit).any() or np.abs(hit[:, 1]).max() > 0.04 or np.abs(hit[:, [0, 2]] - pts[:, [0, 2]]).max() > 0.08:
                            continue  # not all floor: furniture or a wall in the way
                        u, v, d = self.project(view['inv'], view['K'], pts)
                        if (d < 0.2).any():
                            continue
                        fw, fh = view['full']
                        sc = fw / view['size'][0]
                        if u.min() < 0 or v.min() < 0 or u.max() * sc >= fw - 1 or v.max() * sc >= fh - 1:
                            continue
                        res = math.sqrt(abs((u.max() - u.min()) * (v.max() - v.min()))) * sc / S  # pixels per meter
                        if res >= min_res and (not best or res * S > best[0]):
                            best = (res * S, S, cx, cz, view)
                if best:
                    break  # the biggest square that some photo shows sharply enough
            if best:
                break
        if not best:
            return None
        _, S, cx, cz, view = best
        full = Image.open(io.BytesIO(self.bundle.read(view['file']))).convert('RGB')
        sc = full.width / view['size'][0]
        # column → +x, row (top to bottom) → +z: the orientation house.js maps floor UVs to
        t = (np.arange(size_px) + 0.5) / size_px * S - S / 2
        X, Z = np.meshgrid(cx + t, cz + t)
        pts = np.stack([X.ravel(), np.zeros(X.size), Z.ravel()], 1)
        u, v, _ = self.project(view['inv'], view['K'], pts)
        src = np.asarray(full, dtype=np.float32)
        tex = bilinear(src, u * sc, v * sc).reshape(size_px, size_px, 3)
        # flatten the light falloff so the swatch tiles without a bright spot
        im = Image.fromarray(np.clip(tex, 0, 255).astype(np.uint8))
        blur = np.asarray(im.filter(ImageFilter.GaussianBlur(size_px / 6)), dtype=np.float32)
        lum = blur @ np.array([0.299, 0.587, 0.114])
        tex = tex * (lum.mean() / np.maximum(lum, 1))[:, :, None]
        Image.fromarray(np.clip(tex, 0, 255).astype(np.uint8)).save(out_path, 'JPEG', quality=88)
        return S


def bilinear(img, u, v):
    h, w = img.shape[:2]
    u, v = np.clip(u - 0.5, 0, w - 1.001), np.clip(v - 0.5, 0, h - 1.001)
    x0, y0 = u.astype(int), v.astype(int)
    fx, fy = (u - x0)[:, None], (v - y0)[:, None]
    return (img[y0, x0] * (1 - fx) * (1 - fy) + img[y0, x0 + 1] * fx * (1 - fy)
            + img[y0 + 1, x0] * (1 - fx) * fy + img[y0 + 1, x0 + 1] * fx * fy)


def hexcolor(rgb, k=1.0):
    return '#' + ''.join(f'{int(max(0, min(255, round(c * k)))):02x}' for c in rgb)


def colorize(spec, views, out_dir, textures=True, min_res=120):
    """Fill in wall, floor and furniture colors (and floor textures) from the photos"""
    pts, boxes, groups, names = [], [], [], {}

    def target(name, points, box):
        gid = names.setdefault(name, len(names))
        for p in points:
            pts.append(p)
            boxes.append(box(p) if callable(box) else box)
            groups.append(gid)

    # walls: points on each face that has a room in front of it (between the openings)
    for wi, w in enumerate(spec['walls']):
        ax, az, ux, uz, L = seg(w)
        nx, nz = -uz, ux
        T = w.get('thickness', 0.12)
        faces = [T / 2, -T / 2] if w.get('centered') else [0.0]
        rot = math.atan2(ux, uz) - math.pi / 2  # box x along the wall
        for off in faces:
            ps = []
            for t in np.arange(0.2, L - 0.15, 0.25):
                for h in np.arange(0.4, w['height'] - 0.3, 0.3):
                    if any(o['u0'] - 0.1 < t < o['u1'] + 0.1 and o['v0'] - 0.1 < h < o['v1'] + 0.1 for o in w['openings']):
                        continue
                    ps.append((ax + ux * t + nx * off, h, az + uz * t + nz * off))
            target(f'wall:{wi}', ps, lambda p: (p[0], p[1], p[2], rot, 0.2, 0.2, 0.08 if not w.get('centered') else max(0.08, T / 2 + 0.03)))
    # floors
    for ri, r in enumerate(spec['rooms']):
        poly = r['polygon']
        xs, zs = [p[0] for p in poly], [p[1] for p in poly]
        ps = [(x, 0.0, z) for x in np.arange(min(xs) + 0.1, max(xs), 0.2) for z in np.arange(min(zs) + 0.1, max(zs), 0.2) if inside(poly, x, z)]
        target(f'floor:{ri}', ps, lambda p: (p[0], 0.0, p[2], 0.0, 0.12, 0.04, 0.12))
    # furniture: the top and the sides (the depth hit must land inside the object's box)
    for ii, it in enumerate(spec['items']):
        (cx, cy, cz), (w, h, d), ry = it['center'], it['size'], it['rotY']
        c, s = math.cos(ry), math.sin(ry)
        local = lambda x, y, z: (cx + x * c + z * s, cy + y, cz - x * s + z * c)
        # the boxes stop short of the back and sides, where a wall or a neighbor often touches
        g = np.linspace(-0.4, 0.4, 5)
        target(f'item:{ii}:top', [local(x * w, h / 2, z * d) for x in g for z in g],
               (cx, cy, cz, ry, max(0.02, w / 2 - 0.03), h / 2 + 0.04, max(0.02, d / 2 - 0.03)))
        fx, fz = local(0, 0, 0.04)[0] - cx, local(0, 0, 0.04)[2] - cz
        target(f'item:{ii}:side', [local(x * w, y * h, d / 2) for x in g for y in g],
               (cx + fx, cy, cz + fz, ry, max(0.02, w / 2 - 0.03), h / 2 + 0.04, d / 2))

    found = views.sample(np.array(pts, dtype=np.float64), np.array(boxes, dtype=np.float64), np.array(groups))
    by = {n: found.get(g) for n, g in names.items()}

    # one exposure fix for the whole house: white-ish walls should read as white-ish
    wall_samples = [v for n, v in by.items() if n.startswith('wall:') and v]
    k = 1.0
    if wall_samples:
        cols, counts = np.array([v[0] for v in wall_samples]), np.array([v[1] for v in wall_samples], dtype=float)
        # the house's wall paint: the wall color closest to all the others (accent walls don't pull it)
        rgb = cols[np.argmin([(np.linalg.norm(cols - c, axis=1) * counts).sum() for c in cols])]
        neutral = (cols.max(1) - cols.min(1)) < 30
        if counts[neutral].sum() > 0.5 * counts.sum():
            lum = np.average(cols[neutral], axis=0, weights=counts[neutral]) @ np.array([0.299, 0.587, 0.114])
            k = float(np.clip(225 / max(lum, 1), 1.0, 1.35))
        spec['style']['wallColor'] = hexcolor(rgb, k)
        for wi, w in enumerate(spec['walls']):
            v = by.get(f'wall:{wi}')
            if v and v[1] >= 20 and np.linalg.norm(v[0] - rgb) > 35:
                w['color'] = hexcolor(v[0], k)  # an accent wall or tiles
    os.makedirs(os.path.join(out_dir, 'textures'), exist_ok=True)
    for ri, r in enumerate(spec['rooms']):
        name = f'floor-{ri}'
        mat = {'roughness': 0.6}
        v = by.get(f'floor:{ri}')
        if v:
            mat['color'] = hexcolor(v[0], k)
        if textures:
            rel = f'textures/{name}.jpg'
            S = views.floor_swatch(r['polygon'], os.path.join(out_dir, rel), min_res)
            if S:
                mat.update(map=rel, tile=round(S, 3))
        if 'color' in mat or 'map' in mat:
            spec['materials'][name] = mat
            r['floor'] = name
    for ii, it in enumerate(spec['items']):
        top, side = by.get(f'item:{ii}:top'), by.get(f'item:{ii}:side')
        both = [x for x in (top, side) if x]
        if not both:
            continue
        mix = np.average([x[0] for x in both], axis=0, weights=[x[1] for x in both])
        it['color'] = hexcolor(side[0] if side and it['type'] in ('storage', 'refrigerator', 'stove', 'oven', 'dishwasher') else
                               top[0] if top and it['type'] in ('table', 'desk') else mix, k)
        if it['type'] == 'bed' and top:
            it['colors'] = {'blanket': hexcolor(top[0], k)}
            if side:
                it['color'] = hexcolor(side[0], k)
    print(f'  colors from {len(views.views)} photos: walls {spec["style"]["wallColor"]}, '
          f'{sum(1 for r in spec["rooms"] if spec["materials"].get(r.get("floor"), {}).get("map"))} floor textures, '
          f'{sum(1 for it in spec["items"] if "color" in it)}/{len(spec["items"])} furniture colors')


# ---- building -----------------------------------------------------------------------------------------

def build_spec(b, out_dir, max_photos, colors=True, textures=True, min_res=120):
    manifest = b.json('manifest.json') or {}
    if not str(manifest.get('format', '')).startswith('house-capture/'):
        sys.exit(f"unsupported bundle format: {manifest.get('format')}")
    room_recs = manifest.get('rooms') or []
    captured = [(r, b.json(r.get('file'))) for r in room_recs]
    captured = [(r, R) for r, R in captured if R]
    if not captured and manifest.get('structure'):
        S = b.json(manifest['structure'])
        captured = [({'name': 'House'}, S)] if S else []
    if not captured:
        sys.exit('no RoomPlan rooms in this bundle (rooms/room-N.json): rescan and tap "Save room" for each room')

    all_walls = [w for _, R in captured for w in R.get('walls') or []]
    all_floors = [f for _, R in captured for f in R.get('floors') or []]
    W2R = model_frame(all_walls, all_floors)

    rooms = []
    for r, R in captured:
        poly = room_polygon(R, W2R)
        if poly:
            rooms.append({'name': r.get('name') or f'Room {len(rooms) + 1}', 'polygon': poly})
    walls = []
    for _, R in captured:
        walls += wall_segments(R, W2R)
    walls = orient_walls(merge_walls(walls), [r['polygon'] for r in rooms])
    for w in walls:
        w['a'], w['b'], w['height'] = r4(w['a']), r4(w['b']), round(w['height'], 3)
        w['openings'] = [{k: (round(v, 3) if isinstance(v, float) else v) for k, v in o.items()} for o in w['openings']]
    items = furniture([o for _, R in captured for o in R.get('objects') or []], W2R)
    for it in items:
        if it['category'] in DEFAULT_COLORS:
            it['color'] = DEFAULT_COLORS[it['category']]

    total = sum(area(r['polygon']) for r in rooms)
    when = (manifest.get('createdAt') or '')[:10]
    spec = {
        'name': (manifest.get('property') or {}).get('name') or manifest.get('houseName') or 'Property',
        'subtitle': f'{len(rooms)} room{"s" if len(rooms) != 1 else ""} · {total:.0f} m² ({total * 10.7639:.0f} ft²)' + (f' · scanned {when}' if when else ''),
        'style': {'wallColor': '#eceae4', 'wallThickness': 0.12},
        'rooms': rooms, 'walls': walls, 'items': items, 'materials': {}, 'photos': [],
        'source': {'format': manifest.get('format'), 'worldToModel': colmajor(W2R),
                   'note': 'model = worldToModel × ARKit world (column-major). Units meters, +Y up, floor at 0.'},
    }

    photos_path = manifest.get('photos') or 'photos/photos.json'
    photos = sorted(b.json(photos_path) or [], key=lambda p: p.get('timestamp', 0))
    frames = b.json(manifest.get('depthFrames') or 'depth/frames.json') or []
    if colors and np is not None and photos and frames:
        views = Views(b, evenly([p for p in photos if p.get('depthFrame')], 120), frames, W2R)
        if views.views:
            colorize(spec, views, out_dir, textures, min_res)
    elif colors and np is None:
        print('  note: install numpy and Pillow (pip3 install numpy pillow) to color the model from the photos')

    # photos for the viewer's compare mode, with their cameras in the model frame
    manual = [p for p in photos if p.get('manual')]
    keep = evenly(manual if len(manual) >= 2 else photos, max_photos)
    os.makedirs(os.path.join(out_dir, 'photos'), exist_ok=True)
    for p in keep:
        if not b.has(p['file']):
            continue
        name = 'photos/' + os.path.basename(p['file'])
        with open(os.path.join(out_dir, name), 'wb') as f:
            f.write(shrink_jpeg(b.read(p['file']), 1600))
        spec['photos'].append({'file': name, 'transform': r4(colmajor(mul(W2R, rows(p['transform']))), 5),
                               'width': p['width'], 'height': p['height'], 'fx': p['intrinsics'][0],
                               'room': p.get('room'), 'manual': bool(p.get('manual'))})
    return spec


def write_html(out_dir, html_path=None):
    """Embed model.json and every file it references into one offline model.html"""
    spec_path = os.path.join(out_dir, 'model.json')
    spec = json.load(open(spec_path, encoding='utf-8'))
    files = {'model.json': open(spec_path, 'rb').read()}
    refs = [m.get('map') for m in (spec.get('materials') or {}).values()] + [p.get('file') for p in spec.get('photos') or []]
    for ref in refs:
        if not ref or ref in files:
            continue
        path = os.path.normpath(os.path.join(out_dir, ref))
        if not path.startswith(os.path.normpath(out_dir) + os.sep):
            sys.exit(f'unsafe path in model.json: {ref}')
        if os.path.exists(path):
            files[ref] = open(path, 'rb').read()
        else:
            print(f'  note: {ref} is missing; the viewer will skip it')
    payload = {
        'entry': 'startModel',
        'files': {k: base64.b64encode(v).decode() for k, v in files.items()},
        'three': base64.b64encode(open(THREE, 'rb').read()).decode(),
        'viewer': base64.b64encode(open(VIEWER, 'rb').read()).decode(),
    }
    html_path = html_path or os.path.join(out_dir, 'model.html')
    html = open(TEMPLATE, encoding='utf-8').read().replace('__TITLE__', html_escape(spec.get('name') or '3D model'))
    html = html.replace('__DATA__', json.dumps(payload).replace('</', '<\\/'))
    with open(html_path, 'w', encoding='utf-8') as f:
        f.write(html)
    return html_path, spec


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('source', help='scan bundle (folder or .zip), or a model folder to rebuild')
    ap.add_argument('-o', '--out', default=None, help='output folder (default: house-model next to the bundle)')
    ap.add_argument('--max-photos', type=int, default=60, help='photos kept for photo-compare mode')
    ap.add_argument('--no-colors', action='store_true', help="don't sample colors from the photos")
    ap.add_argument('--no-textures', action='store_true', help='colors only, no floor textures')
    ap.add_argument('--min-texture-res', type=float, default=120, help='no floor texture unless a photo shows the floor this sharp (pixels per meter)')
    a = ap.parse_args()

    src = a.source
    if os.path.isdir(src) and os.path.exists(os.path.join(src, 'model.json')) and not os.path.exists(os.path.join(src, 'manifest.json')):
        path, spec = write_html(src)
    else:
        out = a.out or os.path.join(os.path.dirname(os.path.abspath(src)), 'house-model')
        os.makedirs(out, exist_ok=True)
        spec = build_spec(Bundle(src), out, a.max_photos, not a.no_colors, not a.no_textures, a.min_texture_res)
        with open(os.path.join(out, 'model.json'), 'w', encoding='utf-8') as f:
            json.dump(spec, f, indent=1)
        path, spec = write_html(out)
    print(f'{path}: {os.path.getsize(path) / 1e6:.1f} MB · {len(spec.get("rooms", []))} rooms · {len(spec.get("walls", []))} walls · '
          f'{len(spec.get("items", []))} furniture · {len(spec.get("photos", []))} photos')


if __name__ == '__main__':
    main()
