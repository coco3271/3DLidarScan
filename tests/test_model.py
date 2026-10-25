#!/usr/bin/env python3
"""Checks for ai-kit/make_model.py: the clean model must be measured right (rooms, walls,
openings, furniture), colored like the photos, and rebuildable after model.json is edited.

usage: test_model.py <out-dir>   (after run.sh built <out-dir>/model from the fake bundle)
"""
import base64
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.join(HERE, '..', 'ai-kit')
sys.path.insert(0, KIT)
sys.path.insert(0, HERE)
import make_model as mm  # noqa: E402
from make_fake_bundle import BOXES, WALL_COLORS  # noqa: E402

OUT = sys.argv.pop(1) if len(sys.argv) > 1 else os.path.join(HERE, 'out')
BUNDLE = os.path.join(OUT, 'FakeHouse')
MODEL = os.path.join(OUT, 'model')


def load(path):
    with open(path, encoding='utf-8') as f:
        return json.load(f)


def save(path, obj):
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(obj, f)


SPEC = load(os.path.join(MODEL, 'model.json'))


def run(*args, env=None):
    return subprocess.run([sys.executable, os.path.join(KIT, 'make_model.py'), *args], capture_output=True, text=True, env=env)


def payload(html):
    with open(html, encoding='utf-8') as f:
        text = f.read()
    start = text.index('<script id="data" type="application/json">') + len('<script id="data" type="application/json">')
    return json.loads(text[start:text.index('</script>', start)])


def rgb(h):
    return [int(h[i:i + 2], 16) for i in (1, 3, 5)]


def wall_mid(w):
    return ((w['a'][0] + w['b'][0]) / 2, (w['a'][1] + w['b'][1]) / 2)


class Model(unittest.TestCase):
    def test_rooms_are_measured(self):
        self.assertEqual([r['name'] for r in SPEC['rooms']], ['Living room', 'Bedroom'])
        self.assertAlmostEqual(mm.area(SPEC['rooms'][0]['polygon']), 20.0, places=2)
        self.assertAlmostEqual(mm.area(SPEC['rooms'][1]['polygon']), 12.0, places=2)
        self.assertIn('32 m²', SPEC['subtitle'])

    def test_walls_close_the_rooms_and_face_inward(self):
        walls = SPEC['walls']
        self.assertEqual(len(walls), 7, 'the wall both rooms scanned is merged into one')
        shared = [w for w in walls if w.get('centered')]
        self.assertEqual(len(shared), 1)
        self.assertEqual([o['kind'] for o in shared[0]['openings']], ['door'])
        door = shared[0]['openings'][0]
        self.assertAlmostEqual(door['u1'] - door['u0'], 0.9, places=2)
        self.assertAlmostEqual(door['v1'], 2.05, places=2)
        polys = [r['polygon'] for r in SPEC['rooms']]
        for w in walls:
            self.assertAlmostEqual(w['height'], 2.6, places=3)
            if w.get('centered'):
                continue
            ax, az, ux, uz, L = mm.seg(w)
            mx, mz = wall_mid(w)
            self.assertTrue(any(mm.inside(p, mx - uz * 0.2, mz + ux * 0.2) for p in polys), f'n points into a room: {w}')
        windows = [o for w in walls for o in w['openings'] if o['kind'] == 'window']
        self.assertEqual(len(windows), 1)
        self.assertAlmostEqual(windows[0]['v0'], 0.9, places=2)

    def test_furniture_sits_where_roomplan_measured_it(self):
        W2R = mm.rows(SPEC['source']['worldToModel'])
        want = {}
        for lo, hi, c in BOXES:
            ctr = mm.apply(W2R, [(lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2, (lo[2] + hi[2]) / 2])
            want[tuple(c)] = (ctr, hi[1] - lo[1])
        self.assertEqual(sorted(i['type'] for i in SPEC['items']), ['bed', 'sofa', 'table'])
        for it in SPEC['items']:
            self.assertAlmostEqual(it['center'][1], it['size'][1] / 2, places=3, msg='rests on the floor')
            ctr, _ = min(want.values(), key=lambda v: math.dist(v[0], it['center']))
            self.assertLess(math.dist([ctr[0], ctr[2]], [it['center'][0], it['center'][2]]), 0.11, it)

    def test_colors_come_from_the_photos(self):
        by_type = {it['type']: it for it in SPEC['items']}
        truth = {'sofa': BOXES[0][2], 'table': BOXES[1][2], 'bed': BOXES[2][2]}
        for t, c in truth.items():
            self.assertLess(math.dist(rgb(by_type[t]['color']), c), 25, f'{t}: {by_type[t]["color"]} vs {c}')
        # outer walls: x min red, x max blue, z min green, z max yellow (the fake shades them 0.75..1)
        W2R = mm.rows(SPEC['source']['worldToModel'])
        side = {'xmin': mm.apply(W2R, [0, 0, 2]), 'xmax': mm.apply(W2R, [8, 0, 2]), 'zmin': mm.apply(W2R, [2.5, 0, 0]), 'zmax': mm.apply(W2R, [2.5, 0, 4])}
        for name, p in side.items():
            w = min((w for w in SPEC['walls'] if not w.get('centered')), key=lambda w: math.dist(wall_mid(w), (p[0], p[2])))
            got = rgb(w.get('color') or SPEC['style']['wallColor'])
            want = WALL_COLORS[name]
            self.assertEqual(max(range(3), key=lambda i: got[i]), max(range(3), key=lambda i: want[i]), f'{name}: {got} vs {want}')
            ratio = [g / c for g, c in zip(got, want)]
            self.assertTrue(all(0.6 < r < 1.05 for r in ratio), f'{name}: {got} vs {want}')

    def test_floor_textures_are_cut_from_the_photos(self):
        for r in SPEC['rooms']:
            m = SPEC['materials'][r['floor']]
            self.assertTrue(os.path.exists(os.path.join(MODEL, m['map'])), m)
            self.assertLessEqual(m['tile'], 1.2)
        # the fake floor is a 0.5 m checker: the swatch must show it axis-aligned and to scale
        import numpy as np
        from PIL import Image
        m = SPEC['materials'][SPEC['rooms'][1]['floor']]
        tex = np.asarray(Image.open(os.path.join(MODEL, m['map'])).convert('L'), dtype=float)
        row = tex[tex.shape[0] // 2]
        edges = np.nonzero(np.abs(np.diff((row > row.mean()).astype(int))))[0]
        if len(edges) >= 2:
            spacing = np.diff(edges).mean() / tex.shape[1] * m['tile']
            self.assertAlmostEqual(spacing, 0.5, delta=0.08)

    def test_photo_cameras_are_in_the_model_frame(self):
        photos = {p['file']: p for p in load(os.path.join(BUNDLE, 'photos/photos.json'))}
        W2R = mm.rows(SPEC['source']['worldToModel'])
        self.assertTrue(SPEC['photos'])
        for p in SPEC['photos']:
            world = photos[p['file']]
            pos = mm.apply(W2R, world['transform'][12:15])
            self.assertLess(math.dist(pos, p['transform'][12:15]), 1e-3)
            self.assertTrue(os.path.exists(os.path.join(MODEL, p['file'])))

    def test_html_embeds_everything(self):
        data = payload(os.path.join(MODEL, 'model.html'))
        self.assertEqual(data['entry'], 'startModel')
        self.assertIn('export async function startModel', base64.b64decode(data['viewer']).decode())
        spec = json.loads(base64.b64decode(data['files']['model.json']))
        for m in spec['materials'].values():
            if m.get('map'):
                self.assertIn(m['map'], data['files'])
        for p in spec['photos']:
            self.assertIn(p['file'], data['files'])

    def test_rebuild_after_editing_model_json(self):
        with tempfile.TemporaryDirectory() as d:
            work = os.path.join(d, 'house model')
            shutil.copytree(MODEL, work)
            spec = load(os.path.join(work, 'model.json'))
            spec['items'].append({'type': 'rug', 'center': [0, 0.006, 0], 'size': [2, 0.012, 1.4], 'rotY': 0, 'color': '#aa3344'})
            spec['name'] = 'Edited <house>'
            save(os.path.join(work, 'model.json'), spec)
            r = run(work)
            self.assertEqual(r.returncode, 0, r.stderr)
            data = payload(os.path.join(work, 'model.html'))
            rebuilt = json.loads(base64.b64decode(data['files']['model.json']))
            self.assertEqual(rebuilt['items'][-1]['type'], 'rug')
            with open(os.path.join(work, 'model.html'), encoding='utf-8') as f:
                self.assertIn('<title>Edited &lt;house&gt;</title>', f.read())

    def test_rejects_paths_outside_the_model_folder(self):
        with tempfile.TemporaryDirectory() as d:
            work = os.path.join(d, 'm')
            shutil.copytree(MODEL, work)
            spec = load(os.path.join(work, 'model.json'))
            spec['materials']['evil'] = {'map': '../../etc/passwd'}
            save(os.path.join(work, 'model.json'), spec)
            r = run(work)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('unsafe path', r.stderr)

    def test_works_without_numpy_and_pillow(self):
        with tempfile.TemporaryDirectory() as d:
            for mod in ('numpy', 'PIL'):
                os.makedirs(os.path.join(d, 'shadow', mod))
                with open(os.path.join(d, 'shadow', mod, '__init__.py'), 'w') as f:
                    f.write('raise ImportError("hidden for the test")\n')
            env = dict(os.environ, PYTHONPATH=os.path.join(d, 'shadow'))
            r = run(BUNDLE, '-o', os.path.join(d, 'out'), env=env)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('install numpy and Pillow', r.stdout)
            spec = load(os.path.join(d, 'out', 'model.json'))
            self.assertEqual(len(spec['walls']), 7)
            self.assertFalse(spec['materials'])

    def test_variants(self):
        single = load(os.path.join(OUT, 'variants', 'single-room-model', 'model.json'))
        self.assertEqual(len(single['rooms']), 1)
        self.assertFalse(any(w.get('centered') for w in single['walls']))
        nodepth = load(os.path.join(OUT, 'variants', 'no-depth-model', 'model.json'))
        self.assertFalse(nodepth['materials'], 'no depth → no occlusion-safe colors')
        nophotos = load(os.path.join(OUT, 'variants', 'no-photos-model', 'model.json'))
        self.assertEqual(nophotos['photos'], [])

    def test_merge_walls(self):
        # two faces of one 0.15 m wall, scanned from either side, with the same door
        a = {'a': [0, 0], 'b': [4, 0], 'height': 2.5, 'openings': [{'kind': 'door', 'u0': 1, 'u1': 1.9, 'v0': 0, 'v1': 2}]}
        b = {'a': [4.1, 0.15], 'b': [-0.1, 0.15], 'height': 2.6, 'openings': [{'kind': 'door', 'u0': 2.2, 'u1': 3.1, 'v0': 0, 'v1': 2.05}]}
        far = {'a': [0, 3], 'b': [4, 3], 'height': 2.5, 'openings': []}
        out = mm.merge_walls([a, b, far])
        self.assertEqual(len(out), 2)
        m = next(w for w in out if w.get('centered'))
        self.assertAlmostEqual(m['thickness'], 0.15, places=3)
        self.assertAlmostEqual(m['a'][1], 0.075, places=3)
        self.assertAlmostEqual(math.dist(m['a'], m['b']), 4.2, places=3)
        self.assertEqual(len(m['openings']), 1, 'one door, not two')
        self.assertAlmostEqual(m['openings'][0]['u0'], 1.1, places=3)
        self.assertAlmostEqual(m['openings'][0]['v1'], 2.05, places=3)
        # perpendicular walls and walls far apart never merge
        self.assertIsNone(mm.try_merge(a, {'a': [0, 0], 'b': [0, 4], 'height': 2.5, 'openings': []}))
        self.assertIsNone(mm.try_merge(a, far))


if __name__ == '__main__':
    unittest.main(verbosity=1)
