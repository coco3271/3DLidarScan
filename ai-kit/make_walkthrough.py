#!/usr/bin/env python3
"""Turn a 3D LiDAR Scan export (house-capture/5 bundle, folder or .zip) into ONE offline
walkthrough.html: dollhouse view, first-person walk, and a photo tour, with the LiDAR mesh
colored from the scan's own photos in the browser.

usage: make_walkthrough.py <bundle-folder-or-zip> [-o walkthrough.html]
                           [--max-depth-frames 300] [--max-photos 120] [--photo-edge 1600]

Standard library only. If Pillow is installed, photos are downscaled to --photo-edge to keep
the file small (sensor orientation and EXIF are preserved; intrinsics are rescaled in the
viewer from the image's own size, so nothing else changes).
"""
import argparse
import base64
import io
import json
import os
import posixpath
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
VIEWER = os.path.join(HERE, 'walkthrough', 'viewer.js')
THREE = os.path.join(HERE, 'walkthrough', 'three.bundle.min.js')
# shared with the iPhone app's WalkthroughBuilder.swift: __TITLE__ and __DATA__ are filled in
TEMPLATE = os.path.join(HERE, 'walkthrough', 'template.html')


class Bundle:
    """Read files relative to the folder that holds manifest.json (inside a zip or on disk)."""

    def __init__(self, path):
        self.zip = None
        if zipfile.is_zipfile(path):
            self.zip = zipfile.ZipFile(path)
            names = [n for n in self.zip.namelist() if posixpath.basename(n) == 'manifest.json' and '__MACOSX' not in n]
            if not names:
                sys.exit('no manifest.json in the zip')
            self.root = posixpath.dirname(min(names, key=len))
            self.names = {n[len(self.root) + 1 if self.root else 0:] for n in self.zip.namelist() if not n.endswith('/')}
        else:
            root = path
            if not os.path.exists(os.path.join(root, 'manifest.json')):
                found = [d for d, _, files in os.walk(path) if 'manifest.json' in files]
                if not found:
                    sys.exit(f'no manifest.json under {path}')
                root = min(found, key=len)
            self.root = root
            self.names = {os.path.relpath(os.path.join(d, f), root).replace(os.sep, '/')
                          for d, _, files in os.walk(root) for f in files}

    def has(self, name):
        return bool(name) and name in self.names

    def read(self, name):
        if '..' in name.split('/') or name.startswith('/'):
            raise ValueError(f'unsafe path in bundle: {name}')
        if self.zip:
            return self.zip.read(posixpath.join(self.root, name) if self.root else name)
        with open(os.path.join(self.root, name), 'rb') as f:
            return f.read()

    def json(self, name):
        return json.loads(self.read(name)) if self.has(name) else None


def evenly(items, limit):
    if limit <= 0 or len(items) <= limit:
        return list(items)
    step = len(items) / limit
    return [items[int(i * step)] for i in range(limit)]


def shrink_jpeg(data, edge):
    try:
        from PIL import Image
    except ImportError:
        return data
    with Image.open(io.BytesIO(data)) as im:
        if max(im.size) <= edge:
            return data
        exif = im.info.get('exif')
        im = im.convert('RGB')
        im.thumbnail((edge, edge))
        out = io.BytesIO()
        im.save(out, 'JPEG', quality=85, **({'exif': exif} if exif else {}))
        return out.getvalue()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('bundle')
    ap.add_argument('-o', '--out', default='walkthrough.html')
    ap.add_argument('--max-depth-frames', type=int, default=300, help='depth+RGB frames used to color the mesh')
    ap.add_argument('--max-photos', type=int, default=120, help='photos embedded for the photo tour (manual/high-res first)')
    ap.add_argument('--photo-edge', type=int, default=1600, help='downscale embedded photos to this long edge (needs Pillow)')
    a = ap.parse_args()

    b = Bundle(a.bundle)
    manifest = b.json('manifest.json')
    if not str(manifest.get('format', '')).startswith('house-capture/'):
        sys.exit(f"unsupported bundle format: {manifest.get('format')}")
    files = {}

    def add(name, data=None):
        if name and (data is not None or b.has(name)) and name not in files:
            files[name] = data if data is not None else b.read(name)

    add('manifest.json')
    rooms = manifest.get('rooms', [])
    add(manifest.get('structure'))
    for r in rooms:
        add(r.get('file'))
    # the last room's mesh holds the whole session's LiDAR mesh
    mesh = (manifest.get('mesh') or {}).get('file') or next((r['mesh']['file'] for r in reversed(rooms) if r.get('mesh')), None)
    add(mesh)

    photos_path = manifest.get('photos') or 'photos/photos.json'
    photos = b.json(photos_path) or []
    manual = [p for p in photos if p.get('manual')]
    tour = manual if len(manual) >= 2 else photos
    keep = evenly(sorted(tour, key=lambda p: p['timestamp']), a.max_photos)
    for p in keep:
        if b.has(p['file']):
            add(p['file'], shrink_jpeg(b.read(p['file']), a.photo_edge))
    kept = {p['file'] for p in keep}
    files[photos_path] = json.dumps([p for p in photos if p['file'] in kept]).encode()

    depth_path = manifest.get('depthFrames') or 'depth/frames.json'
    frames = [f for f in (b.json(depth_path) or []) if b.has(f['file']) and b.has(f.get('rgb'))]
    frames = evenly(frames, a.max_depth_frames)
    for f in frames:
        add(f['file']); add(f.get('confidence')); add(f.get('rgb'))
    files[depth_path] = json.dumps(frames).encode()
    if not frames and mesh:
        # no depth: the viewer colors from the photos instead, so make sure some are there
        print('note: no depth frames; mesh will be colored from photos without occlusion tests')

    payload = {
        'files': {k: base64.b64encode(v).decode() for k, v in files.items()},
        'three': base64.b64encode(open(THREE, 'rb').read()).decode(),
        'viewer': base64.b64encode(open(VIEWER, 'rb').read()).decode(),
    }
    title = (manifest.get('property') or {}).get('name') or manifest.get('houseName') or 'Property walkthrough'
    html = open(TEMPLATE, encoding='utf-8').read().replace('__TITLE__', html_escape(title)).replace('__DATA__', json.dumps(payload).replace('</', '<\\/'))
    with open(a.out, 'w', encoding='utf-8') as f:
        f.write(html)
    size = os.path.getsize(a.out) / 1e6
    print(f'{a.out}: {size:.1f} MB · {len(rooms)} rooms · mesh {"yes" if mesh and mesh in files else "no"} · '
          f'{len(keep)} tour photos · {len(frames)} color frames')


def html_escape(s):
    return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')


if __name__ == '__main__':
    main()
