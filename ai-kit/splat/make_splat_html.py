#!/usr/bin/env python3
"""Package a trained splat scene (train.py output) into ONE offline splat.html: the photoreal
walkthrough with Dollhouse (ceiling cut away), Walk and Photos (exact photo cameras + compare).

usage: make_splat_html.py <splat-out> --dataset <dataset> [-o splat.html] [--max-photos 40]
"""
import argparse
import base64
import io
import json
import os
import sys

from PIL import Image

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from make_walkthrough import TEMPLATE, evenly, html_escape  # noqa: E402

BUNDLE = os.path.join(HERE, 'viewer', 'spark.bundle.min.js')
VIEWER = os.path.join(HERE, 'viewer', 'viewer.js')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('splat_out')
    ap.add_argument('--dataset', required=True, help='the export_dataset.py folder the scene was trained on')
    ap.add_argument('-o', '--out', default=None)
    ap.add_argument('--max-photos', type=int, default=40)
    ap.add_argument('--photo-edge', type=int, default=1280)
    a = ap.parse_args()

    cams = json.load(open(os.path.join(a.splat_out, 'cameras.json')))
    scene = next((f for f in ('scene.splat', 'scene.spz', 'scene.ply') if os.path.exists(os.path.join(a.splat_out, f))), None)
    if not scene:
        sys.exit(f'no scene.splat in {a.splat_out}')
    files = {scene: open(os.path.join(a.splat_out, scene), 'rb').read()}
    # photo stops: the shots the user took on purpose first, else an even spread
    allc = cams['cameras']
    manual = [c for c in allc if c.get('manual')]
    keep = evenly(manual if len(manual) >= 3 else allc, a.max_photos)
    for i, c in enumerate(keep):
        src = os.path.join(a.dataset, c['file'])
        if not os.path.exists(src):
            continue
        im = Image.open(src).convert('RGB').transpose(Image.Transpose.ROTATE_270)  # sensor → upright
        im.thumbnail((a.photo_edge, a.photo_edge))
        buf = io.BytesIO()
        im.save(buf, 'JPEG', quality=85)
        c['photo'] = f'photos/{i:03d}.jpg'
        files[c['photo']] = buf.getvalue()
    cams['cameras'] = [c for c in keep if c.get('photo')]
    files['cameras.json'] = json.dumps(cams).encode()

    payload = {
        'entry': 'startSplat',
        'files': {k: base64.b64encode(v).decode() for k, v in files.items()},
        'three': base64.b64encode(open(BUNDLE, 'rb').read()).decode(),
        'viewer': base64.b64encode(open(VIEWER, 'rb').read()).decode(),
    }
    out = a.out or os.path.join(a.splat_out, 'splat.html')
    title = cams.get('property') or 'Photoreal walkthrough'
    html = open(TEMPLATE, encoding='utf-8').read().replace('__TITLE__', html_escape(title))
    with open(out, 'w', encoding='utf-8') as f:
        f.write(html.replace('__DATA__', json.dumps(payload).replace('</', '<\\/')))
    print(f'{out}: {os.path.getsize(out) / 1e6:.1f} MB · {len(files[scene]) // 32 if scene.endswith(".splat") else "?"} splats · '
          f'{len(cams["cameras"])} photo stops')


if __name__ == '__main__':
    main()
