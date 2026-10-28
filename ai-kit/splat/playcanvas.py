#!/usr/bin/env python3
"""PlayCanvas outputs for a trained splat scene, made with PlayCanvas's splat-transform
(https://github.com/playcanvas/splat-transform, MIT; needs Node.js, fetched with npx):

  scene.sog          the scene in SOG, PlayCanvas's compressed splat format (~10x smaller than
                     .ply, keeps view-dependent color); SuperSplat, PlayCanvas and Spark read it
  dollhouse.sog      the same without the ceiling and the tops of the walls (for the dollhouse view)
  playcanvas.html    PlayCanvas's own SuperSplat viewer, self-contained: starts above the house,
                     one annotation per room (click to fly there), and a walkthrough tour along the
                     path the phone was carried (the play button)

usage: playcanvas.py <splat-out> [--bundle scan.zip] [--no-html]

The scene stays in our model frame (meters, +Y up, floor at y = 0); PlayCanvas reads it upright
as is. To edit or clean the scene by hand, open scene.ply or scene.sog in SuperSplat:
https://superspl.at/editor
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
SPLAT_TRANSFORM = '@playcanvas/splat-transform@3.10.1'


def available():
    return shutil.which('npx') is not None


def splat_transform(args, quiet=True):
    """Run PlayCanvas's splat-transform (on the CPU, so it works without a GPU)"""
    cmd = ['npx', '-y', SPLAT_TRANSFORM, '-w', '--no-tty', '-g', 'cpu'] + (['-q'] if quiet else []) + args
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f'splat-transform failed: {(r.stderr or r.stdout).strip()[-800:]}')


def ply_heights(path):
    """y of every splat, and its opacity (from a standard 3DGS .ply)"""
    with open(path, 'rb') as f:
        data = f.read()
    end = data.index(b'end_header\n') + len(b'end_header\n')
    header = data[:end].decode()
    n = int(header.split('element vertex ')[1].split()[0])
    names = [l.split()[-1] for l in header.splitlines() if l.startswith('property')]
    arr = np.frombuffer(data[end:], dtype='<f4', count=n * len(names)).reshape(n, len(names))
    return arr[:, names.index('x')], arr[:, names.index('y')], arr[:, names.index('z')], 1 / (1 + np.exp(-arr[:, names.index('opacity')]))


def cut_ply(src, dst, cut):
    """Write the splats of a standard 3DGS .ply whose center is below `cut` meters"""
    with open(src, 'rb') as f:
        data = f.read()
    end = data.index(b'end_header\n') + len(b'end_header\n')
    header = data[:end].decode()
    n = int(header.split('element vertex ')[1].split()[0])
    names = [l.split()[-1] for l in header.splitlines() if l.startswith('property')]
    if any(l.split()[1] != 'float' for l in header.splitlines() if l.startswith('property')):
        raise ValueError('expected an all-float 3DGS .ply')
    arr = np.frombuffer(data[end:], dtype='<f4', count=n * len(names)).reshape(n, len(names))
    keep = arr[arr[:, names.index('y')] < cut]
    with open(dst, 'wb') as f:
        f.write(header.replace(f'element vertex {n}\n', f'element vertex {len(keep)}\n').encode())
        f.write(keep.astype('<f4').tobytes())
    return len(keep)


def cut_height(ply):
    """where to cut for the dollhouse: just under the ceiling (the highest dense layer of splats)"""
    _, y, _, op = ply_heights(ply)
    solid = y[op > 0.3] if (op > 0.3).sum() > 100 else y
    return max(1.2, float(np.percentile(solid, 98.5)) - 0.45)


def rooms_from_bundle(bundle):
    """room names and floor outlines in the model frame (the same frame as the splats)"""
    if not bundle:
        return []
    try:
        import make_model as mm
        from make_walkthrough import Bundle
        b = Bundle(bundle)
        manifest = b.json('manifest.json') or {}
        caps = [(r, b.json(r.get('file'))) for r in manifest.get('rooms') or []]
        caps = [(r, R) for r, R in caps if R]
        W2R = mm.model_frame([w for _, R in caps for w in R.get('walls') or []], [f for _, R in caps for f in R.get('floors') or []])
        out = []
        for r, R in caps:
            poly = mm.room_polygon(R, W2R)
            if poly:
                out.append({'name': r.get('name') or 'Room', 'polygon': poly, 'area': mm.area(poly)})
        return out
    except Exception as e:  # rooms are a nicety: never fail the export over them
        print(f'  note: no room annotations ({e})')
        return []


def settings(cams, rooms, box):
    """SuperSplat viewer settings: start above the house, a room annotation each, a tour"""
    (x0, y0, z0), (x1, y1, z1) = box
    cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
    r = max(2.5, math.hypot(x1 - x0, z1 - z0) / 2)
    start = {'position': [cx + r * 0.55, r * 1.35, cz + r * 0.9], 'target': [cx, 0.3, cz], 'fov': 50}
    annotations = []
    for room in rooms:
        px = sum(p[0] for p in room['polygon']) / len(room['polygon'])
        pz = sum(p[1] for p in room['polygon']) / len(room['polygon'])
        xs, zs = [p[0] for p in room['polygon']], [p[1] for p in room['polygon']]
        span = max(max(xs) - min(xs), max(zs) - min(zs))
        annotations.append({
            'position': [px, 1.2, pz], 'title': room['name'], 'text': f'{room["area"]:.1f} m² ({room["area"] * 10.7639:.0f} ft²)',
            'camera': {'initial': {'position': [px + span * 0.35, 2.2 + span * 0.25, pz + span * 0.55], 'target': [px, 0.6, pz], 'fov': 60}}})
    # the walkthrough: the phone's own path (eye height, looking where it looked), smoothed
    path = []
    for c in cams:
        m = np.array(c['transform'])
        pos, fwd = m[:3, 3], -m[:3, 2]
        if not path or np.linalg.norm(pos - path[-1][0]) > 0.6:
            path.append((pos, fwd))
    tracks = []
    if len(path) >= 3:
        times, positions, targets = [], [], []
        t = 0.0
        for i, (pos, fwd) in enumerate(path):
            if i:
                t += max(1.0, float(np.linalg.norm(pos - path[i - 1][0])) / 0.5)  # ~0.5 m/s
            flat = np.array([fwd[0], max(-0.3, min(0.3, fwd[1])), fwd[2]])
            flat /= np.linalg.norm(flat) or 1
            times.append(round(t, 3))
            positions += [round(float(v), 4) for v in (pos[0], 1.6, pos[2])]
            targets += [round(float(v), 4) for v in (pos[0] + flat[0] * 1.5, 1.6 + flat[1] * 1.5, pos[2] + flat[2] * 1.5)]
        tracks.append({'name': 'Walkthrough', 'duration': times[-1], 'frameRate': 30, 'loopMode': 'repeat',
                       'interpolation': 'spline', 'smoothness': 1,
                       'keyframes': {'times': times, 'values': {'position': positions, 'target': targets, 'fov': [65] * len(times)}}})
    off = {'enabled': False}
    return {
        'version': 2, 'tonemapping': 'none', 'highPrecisionRendering': False,
        'background': {'color': [0.043, 0.086, 0.149]},
        'postEffectSettings': {'sharpness': {**off, 'amount': 0}, 'bloom': {**off, 'intensity': 1, 'blurLevel': 2},
                               'grading': {**off, 'brightness': 0, 'contrast': 1, 'saturation': 1, 'tint': [1, 1, 1]},
                               'vignette': {**off, 'intensity': 0.5, 'inner': 0.3, 'outer': 0.75, 'curvature': 1},
                               'fringing': {**off, 'intensity': 0.5}},
        'animTracks': tracks, 'cameras': [{'initial': start}], 'annotations': annotations, 'startMode': 'default',
    }


def make(splat_out, bundle=None, html=True):
    ply = os.path.join(splat_out, 'scene.ply')
    if not os.path.exists(ply):
        sys.exit(f'no scene.ply in {splat_out}')
    if not available():
        print('  note: Node.js (npx) not found: skipping the PlayCanvas outputs (scene.sog, playcanvas.html)')
        return False
    x, y, z, op = ply_heights(ply)
    solid = op > 0.3
    q = lambda a, p: float(np.percentile(a[solid] if solid.sum() > 100 else a, p))
    box = ((q(x, 1), q(y, 1), q(z, 1)), (q(x, 99), q(y, 99), q(z, 99)))
    cut = cut_height(ply)
    splat_transform([ply, '-N', os.path.join(splat_out, 'scene.sog')])
    with tempfile.TemporaryDirectory() as tmp:
        low = os.path.join(tmp, 'dollhouse.ply')
        cut_ply(ply, low, cut)
        splat_transform([low, '-N', os.path.join(splat_out, 'dollhouse.sog')])
    with open(os.path.join(splat_out, 'cameras.json')) as f:
        cams = json.load(f)
    cams['dollhouse_cut'] = round(cut, 3)
    cams['bounds'] = [list(map(lambda v: round(v, 3), box[0])), list(map(lambda v: round(v, 3), box[1]))]
    cams['splats'] = int(len(x))
    with open(os.path.join(splat_out, 'cameras.json'), 'w') as f:
        json.dump(cams, f)
    if html:
        with tempfile.TemporaryDirectory() as tmp:
            sp = os.path.join(tmp, 'settings.json')
            with open(sp, 'w') as f:
                json.dump(settings(cams['cameras'], rooms_from_bundle(bundle), box), f)
            splat_transform(['--viewer-settings', sp, os.path.join(splat_out, 'scene.sog'), os.path.join(splat_out, 'playcanvas.html')])
    sizes = ', '.join(f'{n} {os.path.getsize(os.path.join(splat_out, n)) / 1e6:.1f} MB'
                      for n in ('scene.sog', 'dollhouse.sog', 'playcanvas.html') if os.path.exists(os.path.join(splat_out, n)))
    print(f'{splat_out}: PlayCanvas outputs ({sizes}), dollhouse cut at {cut:.2f} m')
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('splat_out')
    ap.add_argument('--bundle', help='the scan (folder or zip), for room names on the annotations')
    ap.add_argument('--no-html', action='store_true')
    a = ap.parse_args()
    if not make(a.splat_out, a.bundle, not a.no_html):
        sys.exit(1)


if __name__ == '__main__':
    main()
