#!/usr/bin/env python3
"""Write a synthetic house-capture/5 bundle (what the iPhone app exports) for testing the
AI kit and the walkthrough viewer without a device: two box rooms side by side with a door
between them, a window, furniture, a classified LiDAR mesh, depth frames and posed photos
that are ray-traced from the same geometry, so projections must line up exactly.

usage: make_fake_bundle.py <out-dir> [--zip]      (needs numpy + Pillow)
"""
import argparse
import json
import math
import os
import shutil
import struct
import uuid
import zlib

import numpy as np
from PIL import Image

H = 2.6  # ceiling height; floor at y = -1.3 (ARKit's world origin is wherever the phone started)
FLOOR = -1.3
# room A: x 0..5, z 0..4 · room B: x 5..8, z 0..4 (shared wall at x=5 with a door)
ROOMS = [dict(name='Living room', x0=0.0, x1=5.0, z0=0.0, z1=4.0), dict(name='Bedroom', x0=5.0, x1=8.0, z0=0.0, z1=4.0)]
WALL_COLORS = {'xmin': (200, 90, 80), 'xmax': (80, 150, 210), 'zmin': (90, 180, 110), 'zmax': (220, 190, 80)}


def uid():
    return str(uuid.uuid4()).upper()


def col_major(m):
    return [float(v) for v in np.asarray(m, dtype=np.float64).T.reshape(-1)]


def frame(x_axis, y_axis, z_axis, origin):
    m = np.eye(4)
    m[:3, 0], m[:3, 1], m[:3, 2], m[:3, 3] = x_axis, y_axis, z_axis, origin
    return m


def wall(a, b, inward):
    """RoomPlan wall: centered transform, x along the wall, z = normal; dims [w, h, 0]."""
    a, b = np.array(a, float), np.array(b, float)
    x = (b - a) / np.linalg.norm(b - a)
    z = np.array(inward, float)
    center = np.array([(a[0] + b[0]) / 2, FLOOR + H / 2, (a[1] + b[1]) / 2])
    xa = np.array([x[0], 0, x[1]]); za = np.array([z[0], 0, z[1]])
    return {'identifier': uid(), 'category': {'wall': {}}, 'confidence': {'high': {}},
            'dimensions': [float(np.linalg.norm(b - a)), H, 0.0],
            'transform': col_major(frame(xa, np.cross(za, xa), za, center)),
            'parentIdentifier': None, 'polygonCorners': [], 'completedEdges': [], 'story': 0}


def child(kind, parent, along, bottom, w, h, extra=None):
    """door/window centered `along` meters from the wall's left end, `bottom` above floor."""
    M = np.array(parent['transform']).reshape(4, 4).T
    left = M[:3, 3] - M[:3, 0] * parent['dimensions'][0] / 2
    c = left + M[:3, 0] * along
    c[1] = FLOOR + bottom + h / 2
    m = M.copy(); m[:3, 3] = c
    return {'identifier': uid(), 'category': {kind: extra or {}}, 'confidence': {'high': {}},
            'dimensions': [w, h, 0.0], 'transform': col_major(m), 'parentIdentifier': parent['identifier'],
            'polygonCorners': [], 'completedEdges': [], 'story': 0}


def room_json(r, door_wall_side):
    x0, x1, z0, z1 = r['x0'], r['x1'], r['z0'], r['z1']
    walls = {
        'zmin': wall((x0, z0), (x1, z0), (0, 1)), 'xmax': wall((x1, z0), (x1, z1), (-1, 0)),
        'zmax': wall((x1, z1), (x0, z1), (0, -1)), 'xmin': wall((x0, z1), (x0, z0), (1, 0)),
    }
    doors = [child('door', walls[door_wall_side], 2.0, 0.0, 0.9, 2.05, {'isOpen': False})]
    windows = [child('window', walls['zmax'], 1.5, 0.9, 1.2, 1.2)] if r['name'] == 'Living room' else []
    fl = frame([1, 0, 0], [0, 0, -1], [0, 1, 0], [(x0 + x1) / 2, FLOOR, (z0 + z1) / 2])
    hw, hd = (x1 - x0) / 2, (z1 - z0) / 2
    floor = {'identifier': uid(), 'category': {'floor': {}}, 'confidence': {'high': {}},
             'dimensions': [x1 - x0, z1 - z0, 0.0], 'transform': col_major(fl), 'parentIdentifier': None,
             'polygonCorners': [[-hw, -hd, 0], [hw, -hd, 0], [hw, hd, 0], [-hw, hd, 0]], 'completedEdges': [], 'story': 0}
    objs = []
    if r['name'] == 'Living room':
        objs.append(obj('sofa', [1.0, FLOOR + 0.4, 3.4], [2.0, 0.8, 0.9]))
        objs.append(obj('table', [2.5, FLOOR + 0.375, 1.8], [1.2, 0.75, 0.8]))
    else:
        objs.append(obj('bed', [6.5, FLOOR + 0.3, 2.9], [1.6, 0.6, 2.0]))
    return {'version': 2, 'identifier': uid(), 'story': 0, 'walls': list(walls.values()), 'doors': doors, 'windows': windows,
            'openings': [], 'objects': objs, 'floors': [floor], 'sections': []}


def obj(cat, center, dims):
    return {'identifier': uid(), 'category': {cat: {}}, 'confidence': {'high': {}}, 'dimensions': dims,
            'transform': col_major(frame([1, 0, 0], [0, 1, 0], [0, 0, 1], center)), 'parentIdentifier': None, 'story': 0}


# ---- ray tracing the two boxes (walls, floor, ceiling, furniture boxes) ------------------------

BOXES = [((0.0, FLOOR, 2.95), (2.0, FLOOR + 0.8, 3.85), (120, 70, 140)),
         ((1.9, FLOOR, 1.4), (3.1, FLOOR + 0.75, 2.2), (150, 100, 60)),
         ((5.7, FLOOR, 1.9), (7.3, FLOOR + 0.6, 3.9), (230, 230, 240))]


def trace(origins, dirs):
    """Distance and color along rays inside the house (x 0..8, z 0..4, internal wall at x=5)."""
    n = len(dirs)
    t = np.full(n, np.inf); colr = np.zeros((n, 3))
    def hit_plane(axis, value, color_fn, mask_fn):
        nonlocal t, colr
        with np.errstate(divide='ignore', invalid='ignore'):
            tt = (value - origins[:, axis]) / dirs[:, axis]
        p = origins + dirs * tt[:, None]
        ok = (tt > 1e-4) & (tt < t) & mask_fn(p)
        t = np.where(ok, tt, t)
        colr[ok] = color_fn(p[ok])
    def checker(p, a, b, c1, c2):
        k = (np.floor(p[:, a] * 2) + np.floor(p[:, b] * 2)) % 2
        return np.where(k[:, None] == 0, np.array(c1), np.array(c2))
    inside = lambda p: (p[:, 0] >= -1e-6) & (p[:, 0] <= 8 + 1e-6) & (p[:, 2] >= -1e-6) & (p[:, 2] <= 4 + 1e-6) & (p[:, 1] >= FLOOR - 1e-6) & (p[:, 1] <= FLOOR + H + 1e-6)
    hit_plane(1, FLOOR, lambda p: checker(p, 0, 2, (160, 120, 90), (120, 85, 60)), inside)
    hit_plane(1, FLOOR + H, lambda p: np.tile([235, 235, 235], (len(p), 1)), inside)
    shade = lambda c: (lambda p: np.clip(np.array(c) * (0.75 + 0.25 * np.sin(p[:, 1:2] * 6)), 0, 255))
    hit_plane(0, 0.0, shade(WALL_COLORS['xmin']), inside)
    hit_plane(0, 8.0, shade(WALL_COLORS['xmax']), inside)
    hit_plane(2, 0.0, shade(WALL_COLORS['zmin']), inside)
    hit_plane(2, 4.0, shade(WALL_COLORS['zmax']), inside)
    # internal wall at x=5 with a door hole z 1.55..2.45, y below FLOOR+2.05
    door = lambda p: (p[:, 2] > 1.55) & (p[:, 2] < 2.45) & (p[:, 1] < FLOOR + 2.05)
    hit_plane(0, 5.0, lambda p: np.tile([180, 180, 170], (len(p), 1)), lambda p: inside(p) & ~door(p))
    for lo, hi, c in BOXES:
        for axis in range(3):
            for v in (lo[axis], hi[axis]):
                o = [i for i in range(3) if i != axis]
                hit_plane(axis, v, lambda p, c=c: np.tile(c, (len(p), 1)),
                          lambda p, o=o: (p[:, o[0]] >= lo[o[0]]) & (p[:, o[0]] <= hi[o[0]]) & (p[:, o[1]] >= lo[o[1]]) & (p[:, o[1]] <= hi[o[1]]))
    return t, colr


def camera_pose(pos, yaw, pitch=0.0):
    """Phone held upright (portrait): sensor +X points at the floor, camera looks along -Z."""
    f = np.array([-math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch)])
    up = np.array([0.0, 1.0, 0.0])
    up = up - f * np.dot(up, f); up /= np.linalg.norm(up)
    x = -up
    z = -f
    y = np.cross(z, x)
    return frame(x, y, z, pos)


def render(T, w, h, fx, fy, cx, cy):
    v, u = np.mgrid[0:h, 0:w]
    d_cam = np.stack([(u + 0.5 - cx) / fx, -(v + 0.5 - cy) / fy, -np.ones_like(u, dtype=float)], -1).reshape(-1, 3)
    d_world = d_cam @ T[:3, :3].T
    t, c = trace(np.tile(T[:3, 3], (len(d_world), 1)), d_world)
    depth = t  # along the camera's -Z: z-depth equals t because d_cam has z = -1
    return depth.reshape(h, w), c.reshape(h, w, 3).astype(np.uint8)


def write_ply(path, rooms):
    """Gridded triangle mesh of floor/ceiling/walls/internal wall with ARKit-style classes."""
    verts, faces = [], []
    def quad_grid(o, a, b, na, nb, normal, cls, skip=None):
        base = len(verts)
        for j in range(nb + 1):
            for i in range(na + 1):
                p = np.array(o) + np.array(a) * i / na + np.array(b) * j / nb
                verts.append((*p, *normal))
        for j in range(nb):
            for i in range(na):
                p = np.array(o) + np.array(a) * (i + .5) / na + np.array(b) * (j + .5) / nb
                if skip is not None and skip(p):
                    continue
                k = base + j * (na + 1) + i
                faces.append(((k, k + 1, k + na + 2), cls)); faces.append(((k, k + na + 2, k + na + 1), cls))
    quad_grid((0, FLOOR, 0), (8, 0, 0), (0, 0, 4), 32, 16, (0, 1, 0), 2)
    quad_grid((0, FLOOR + H, 0), (8, 0, 0), (0, 0, 4), 32, 16, (0, -1, 0), 3)
    quad_grid((0, FLOOR, 0), (8, 0, 0), (0, H, 0), 32, 10, (0, 0, 1), 1)
    quad_grid((0, FLOOR, 4), (8, 0, 0), (0, H, 0), 32, 10, (0, 0, -1), 1)
    quad_grid((0, FLOOR, 0), (0, 0, 4), (0, H, 0), 16, 10, (1, 0, 0), 1)
    quad_grid((8, FLOOR, 0), (0, 0, 4), (0, H, 0), 16, 10, (-1, 0, 0), 1)
    quad_grid((5, FLOOR, 0), (0, 0, 4), (0, H, 0), 32, 20, (1, 0, 0), 1, skip=lambda p: 1.55 < p[2] < 2.45 and p[1] < FLOOR + 2.05)
    for lo, hi, _ in BOXES:  # box tops as "table/seat"
        quad_grid((lo[0], hi[1], lo[2]), (hi[0] - lo[0], 0, 0), (0, 0, hi[2] - lo[2]), 4, 4, (0, 1, 0), 4)
    with open(path, 'wb') as f:
        f.write((f'ply\nformat binary_little_endian 1.0\nelement vertex {len(verts)}\n'
                 'property float x\nproperty float y\nproperty float z\nproperty float nx\nproperty float ny\nproperty float nz\n'
                 'property float coverage\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nproperty uchar inroom\n'
                 f'element face {len(faces)}\nproperty list uchar uint vertex_indices\nproperty uchar class\nend_header\n').encode())
        for v in verts:
            f.write(struct.pack('<7f4B', *v, 0.0, 128, 128, 128, 1))
        for (a, b, c), cls in faces:
            f.write(struct.pack('<B3IB', 3, a, b, c, cls))
    return len(verts), len(faces)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out')
    ap.add_argument('--zip', action='store_true')
    a = ap.parse_args()
    out = a.out
    if os.path.exists(out):
        shutil.rmtree(out)
    for d in ('rooms', 'mesh', 'photos', 'depth'):
        os.makedirs(os.path.join(out, d))

    room_files = [room_json(ROOMS[0], 'xmax'), room_json(ROOMS[1], 'xmin')]
    # merged structure: both rooms' elements (RoomPlan's StructureBuilder output has the same keys)
    structure = {k: [e for r in room_files for e in r[k]] for k in ('walls', 'doors', 'windows', 'openings', 'objects', 'floors')}
    structure.update({'version': 2, 'sections': [], 'rooms': []})
    json.dump(structure, open(os.path.join(out, 'structure.json'), 'w'), indent=1)

    photos, frames, records = [], [], []
    # photo + depth sensor model: 1920x1440 video frames scaled down 4x for test speed
    PW, PH, PF = 480, 360, 1440 / 4
    DW, DH = 256, 192
    t0 = 700000.0
    stops = [(ri, (x, FLOOR + 1.45, z), yaw) for ri, pts in enumerate([
        [(1.2, 1.0), (3.8, 1.0), (3.8, 3.0), (1.2, 2.5)], [(6.0, 1.0), (7.2, 1.2), (6.5, 2.0)]]) for x, z in pts
        for yaw in np.linspace(0, 2 * math.pi, 9)[:-1]]
    for i, (room, p, yaw) in enumerate(stops):
        T = camera_pose(p, yaw + 0.1 * i, pitch=-0.15 if i % 2 else 0.1)
        ts = t0 + i * 0.7
        # depth frame
        k = DW / PW
        depth, rgb = render(T, DW, DH, PF * k, PF * k, DW / 2, DH / 2)
        name = f'{len(frames):05d}'
        open(os.path.join(out, f'depth/{name}.f16z'), 'wb').write(zlib.compress(depth.astype('<f2').tobytes(), 6)[2:-4])
        open(os.path.join(out, f'depth/{name}.conf'), 'wb').write(np.full(DW * DH, 2, np.uint8).tobytes())
        _, rgb640 = render(T, 320, 240, PF * 320 / PW, PF * 320 / PW, 160, 120)
        Image.fromarray(rgb640).save(os.path.join(out, f'depth/{name}.jpg'), quality=85)
        frames.append({'file': f'depth/{name}.f16z', 'confidence': f'depth/{name}.conf', 'rgb': f'depth/{name}.jpg',
                       'rgbIntrinsics': [PF * 320 / PW, 0, 0, 0, PF * 320 / PW, 0, 160, 120, 1], 'room': room, 'timestamp': ts,
                       'width': DW, 'height': DH, 'transform': col_major(T),
                       'intrinsics': [PF * k, 0, 0, 0, PF * k, 0, DW / 2, DH / 2, 1]})
        if i % 4 == 0:
            _, img = render(T, PW, PH, PF, PF, PW / 2, PH / 2)
            fname = f'photos/{len(photos):04d}.jpg'
            exif = Image.Exif(); exif[0x0112] = 6
            Image.fromarray(img).save(os.path.join(out, fname), quality=90, exif=exif)
            photos.append({'file': fname, 'room': room, 'timestamp': ts, 'width': PW, 'height': PH, 'transform': col_major(T),
                           'intrinsics': [PF, 0, 0, 0, PF, 0, PW / 2, PH / 2, 1], 'tracking': 'normal', 'manual': i % 8 == 0,
                           'highRes': i % 8 == 0, 'pass': 'scan',
                           'capturedAt': '2026-10-23T15:00:00Z',
                           'location': {'latitude': 45.50169 + i * 1e-6, 'longitude': -73.56725, 'altitude': 30.0,
                                        'horizontalAccuracy': 8.0, 'verticalAccuracy': 4.0, 'heading': (math.degrees(yaw) % 360), 'headingAccuracy': 15.0}})
    json.dump(photos, open(os.path.join(out, 'photos/photos.json'), 'w'), indent=1)
    json.dump(frames, open(os.path.join(out, 'depth/frames.json'), 'w'))

    nv, nf = 0, 0
    for idx, r in enumerate(room_files):
        json.dump(r, open(os.path.join(out, f'rooms/room-{idx}.json'), 'w'), indent=1)
        nv, nf = write_ply(os.path.join(out, f'mesh/room-{idx}.ply'), ROOMS)
        records.append({'index': idx, 'name': ROOMS[idx]['name'], 'file': f'rooms/room-{idx}.json', 'usdz': '',
                        'capturedAt': '2026-10-23T15:00:00Z', 'walls': 4, 'doors': 1, 'windows': len(r['windows']), 'openings': 0,
                        'objects': len(r['objects']), 'mesh': {'file': f'mesh/room-{idx}.ply', 'anchors': 1, 'vertices': nv, 'faces': nf}})
    manifest = {
        'format': 'house-capture/5', 'createdAt': '2026-10-23T15:00:00Z', 'endedAt': '2026-10-23T15:10:00Z',
        'device': 'iPhone16,1', 'systemVersion': '18.0', 'house': 'test-house', 'houseName': '12 Test Street',
        'session': 'fake', 'zone': 'main', 'rooms': records, 'structure': 'structure.json',
        'mesh': records[-1]['mesh'], 'photos': 'photos/photos.json', 'photoCount': len(photos),
        'depthFrames': 'depth/frames.json', 'depthFrameCount': len(frames),
        'coordinateSystem': 'ARKit world space of this capture session: meters, +Y up (gravity), right-handed.',
        'property': {'name': '12 Test Street', 'address': '12 Test Street, Montréal, QC', 'latitude': 45.50169, 'longitude': -73.56725,
                     'altitude': 30.0, 'horizontalAccuracy': 8.0},
        'app': {'name': '3D LiDAR Scan', 'version': 'test'},
    }
    json.dump(manifest, open(os.path.join(out, 'manifest.json'), 'w'), indent=1)
    print(f'{out}: {len(photos)} photos, {len(frames)} depth frames, mesh {nv} verts / {nf} faces')
    if a.zip:
        z = shutil.make_archive(out, 'zip', os.path.dirname(os.path.abspath(out)), os.path.basename(out))
        print(z)


if __name__ == '__main__':
    main()
