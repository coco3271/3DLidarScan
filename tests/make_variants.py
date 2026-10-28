#!/usr/bin/env python3
"""Derive edge-case bundles from the synthetic one, to make sure the AI kit and the viewer
cope with whatever a real capture can produce:

  single-room   one room, no structure.json (a single-room scan never gets one)
  no-mesh       LiDAR mesh missing (scene reconstruction refused) → RoomPlan model only
  no-depth      depth frames missing → mesh colored from the photos instead
  no-photos     no photos at all → tour disabled, mesh stays class-colored
  ascii-ply     mesh written as ASCII PLY
  raw-depth     uncompressed .f16 depth (older house-capture bundles)
  flat-zip      zip with manifest.json at the root (no enclosing folder)
  landscape     photos taken with the phone sideways (as the app now scans), some upside down

usage: make_variants.py <FakeHouse dir> <out dir>
"""
import json
import os
import shutil
import struct
import sys
import zipfile
import zlib


def load(d, name):
    with open(os.path.join(d, name)) as f:
        return json.load(f)


def save(d, name, obj):
    with open(os.path.join(d, name), 'w') as f:
        json.dump(obj, f, indent=1)


def copy(src, out, name):
    dst = os.path.join(out, name)
    shutil.copytree(src, dst)
    return dst


def ply_to_ascii(path):
    data = open(path, 'rb').read()
    end = data.index(b'end_header\n') + len(b'end_header\n')
    header = data[:end].decode()
    nv = int(header.split('element vertex ')[1].split()[0])
    nf = int(header.split('element face ')[1].split()[0])
    body, off, lines = data[end:], 0, []
    for _ in range(nv):
        v = struct.unpack_from('<7f4B', body, off); off += 32
        lines.append(' '.join(f'{x:.5f}' if isinstance(x, float) else str(x) for x in v))
    for _ in range(nf):
        n, a, b, c, cls = struct.unpack_from('<B3IB', body, off); off += 14
        lines.append(f'{n} {a} {b} {c} {cls}')
    with open(path, 'w') as f:
        f.write(header.replace('binary_little_endian', 'ascii') + '\n'.join(lines) + '\n')


def landscape_photos(d):
    import numpy as np
    from PIL import Image
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from make_fake_bundle import col_major, pose_of, render
    photos = load(d, 'photos/photos.json')
    for i, p in enumerate(photos):
        T = np.array(p['transform']).reshape(4, 4).T
        f = -T[:3, 2]
        up = np.array([0.0, 1.0, 0.0]) - f * f[1]
        up /= np.linalg.norm(up)
        right = np.cross(f, up)
        L = np.eye(4)
        L[:3, 0], L[:3, 1], L[:3, 2], L[:3, 3] = right, up, -f, T[:3, 3]
        # tilt every other photo the other way round (sensor upside down: EXIF 3)
        if i % 2:
            L[:3, 0], L[:3, 1] = -right, -up
        w, h = p['width'], p['height']
        fx, fy, cx, cy = p['intrinsics'][0], p['intrinsics'][4], p['intrinsics'][6], p['intrinsics'][7]
        _, img = render(L, w, h, fx, fy, cx, cy)
        exif = Image.Exif()
        exif[0x0112] = 3 if i % 2 else 1
        Image.fromarray(img).save(os.path.join(d, p['file']), quality=90, exif=exif)
        p['transform'] = col_major(L)
        p['pose'] = pose_of(L)
    save(d, 'photos/photos.json', photos)


def main():
    src, out = sys.argv[1], sys.argv[2]
    if os.path.exists(out):
        shutil.rmtree(out)
    os.makedirs(out)

    d = copy(src, out, 'single-room')
    m = load(d, 'manifest.json')
    m['rooms'] = m['rooms'][:1]
    m['structure'] = None
    m['mesh'] = m['rooms'][0]['mesh']
    save(d, 'manifest.json', m)
    os.remove(os.path.join(d, 'structure.json'))

    d = copy(src, out, 'no-mesh')
    m = load(d, 'manifest.json')
    m['mesh'] = None
    for r in m['rooms']:
        r['mesh'] = None
    save(d, 'manifest.json', m)
    shutil.rmtree(os.path.join(d, 'mesh'))

    d = copy(src, out, 'no-depth')
    m = load(d, 'manifest.json')
    m['depthFrames'] = None
    m['depthFrameCount'] = 0
    save(d, 'manifest.json', m)
    shutil.rmtree(os.path.join(d, 'depth'))

    d = copy(src, out, 'no-photos')
    save(d, 'photos/photos.json', [])
    for f in os.listdir(os.path.join(d, 'photos')):
        if f.endswith('.jpg'):
            os.remove(os.path.join(d, 'photos', f))

    d = copy(src, out, 'ascii-ply')
    for f in os.listdir(os.path.join(d, 'mesh')):
        ply_to_ascii(os.path.join(d, 'mesh', f))

    d = copy(src, out, 'raw-depth')
    frames = load(d, 'depth/frames.json')
    for fr in frames:
        p = os.path.join(d, fr['file'])
        raw = zlib.decompress(open(p, 'rb').read(), -15)
        os.remove(p)
        fr['file'] = fr['file'][:-1]  # .f16z → .f16
        open(os.path.join(d, fr['file']), 'wb').write(raw)
    save(d, 'depth/frames.json', frames)

    # landscape: the app scans with the phone held sideways. Re-render every photo from the same
    # spot and direction, sensor upright (EXIF orientation 1), so viewers must not assume portrait.
    d = copy(src, out, 'landscape')
    landscape_photos(d)

    with zipfile.ZipFile(os.path.join(out, 'flat-zip.zip'), 'w', zipfile.ZIP_DEFLATED) as z:
        for root, _, files in os.walk(src):
            for f in files:
                full = os.path.join(root, f)
                z.write(full, os.path.relpath(full, src))

    print('variants:', ', '.join(sorted(os.listdir(out))))


if __name__ == '__main__':
    main()
