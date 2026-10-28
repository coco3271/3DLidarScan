#!/usr/bin/env python3
"""Checks for the photoreal splat pipeline (ai-kit/splat): dataset export, the renderer's math,
training, the generative repair rounds and the exported files.

usage: test_splat.py <out-dir>   (run.sh exported <out-dir>/dataset and trained <out-dir>/splat)
Needs torch (CPU is fine); skipped by run.sh when torch isn't installed.
"""
import base64
import io
import json
import math
import os
import subprocess
import sys
import tempfile
import unittest

import numpy as np
import torch
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SPLAT = os.path.join(HERE, '..', 'ai-kit', 'splat')
sys.path.insert(0, SPLAT)
sys.path.insert(0, HERE)
import gaussians as G  # noqa: E402
import fixers  # noqa: E402
from export_dataset import read_ply_points  # noqa: E402
from make_fake_bundle import render, trace  # noqa: E402
from export_dataset import select_keyframes  # noqa: E402

OUT = sys.argv.pop(1) if len(sys.argv) > 1 else os.path.join(HERE, 'out')
DS = os.path.join(OUT, 'dataset')
RUN = os.path.join(OUT, 'splat')


def load(p):
    with open(p, encoding='utf-8') as f:
        return json.load(f)


TF = load(os.path.join(DS, 'transforms.json'))
W2M = np.array(TF['world_to_model'])
M2W = np.linalg.inv(W2M)


class Dataset(unittest.TestCase):
    def test_cameras_and_lidar_depth_agree_with_the_scene(self):
        """Ray-trace the synthetic house through each exported camera: the depth PNG must match"""
        for f in TF['frames'][::7]:
            d = np.asarray(Image.open(os.path.join(DS, f['depth_file_path'])), dtype=np.float64) / 1000
            h, w = d.shape
            s = w / f['w']
            v, u = np.nonzero(d > 0)
            pick = np.random.default_rng(0).choice(len(u), min(300, len(u)), replace=False)
            u, v = u[pick] + 0.5, v[pick] + 0.5
            fx, fy, cx, cy = f['fl_x'] * s, f['fl_y'] * s, f['cx'] * s, f['cy'] * s
            c2w = M2W @ np.array(f['transform_matrix'])  # back to the fake house's world
            dirs = np.stack([(u - cx) / fx, -(v - cy) / fy, -np.ones_like(u)], 1) @ c2w[:3, :3].T
            t, _ = trace(np.tile(c2w[:3, 3], (len(u), 1)), dirs)
            got = d[(v - 0.5).astype(int), (u - 0.5).astype(int)]
            err = np.abs(got - t)
            self.assertLess(np.median(err), 0.03, f['file_path'])

    def test_model_frame_puts_the_floor_at_zero(self):
        xyz, rgb = read_ply_points(os.path.join(DS, TF['ply_file_path']))
        self.assertAlmostEqual(np.percentile(xyz[:, 1], 1), 0.0, delta=0.03)
        self.assertAlmostEqual(np.percentile(xyz[:, 1], 99), 2.6, delta=0.05)
        self.assertGreater(len(xyz), 10000)
        self.assertGreater(rgb.std(), 20, 'points are colored from the photos')

    def test_video_keyframes_are_the_frames_their_poses_describe(self):
        """Re-render the synthetic house from each video keyframe's camera: it must match the
        decoded image (a wrong frame index, rotation or intrinsics would not)"""
        video = [f for f in TF['frames'] if f.get('kind') == 'video']
        self.assertGreater(len(video), 60, 'the training images come from the video')
        for f in video[::9]:
            img = np.asarray(Image.open(os.path.join(DS, f['file_path'])).convert('RGB'), dtype=np.float64)
            c2w = M2W @ np.array(f['transform_matrix'])
            _, want = render(c2w, f['w'], f['h'], f['fl_x'], f['fl_y'], f['cx'], f['cy'])
            err = np.abs(img - want).mean()
            self.assertLess(err, 6, f'{f["source"]}: mean error {err:.1f}')

    def test_blurry_and_badly_tracked_video_frames_are_skipped(self):
        bad = set()
        for v in load(os.path.join(OUT, 'FakeHouse', 'manifest.json'))['videos']:
            for r in load(os.path.join(OUT, 'FakeHouse', v['frames'])):
                if r['blurPixels'] > 6 or r['tracking'] != 'normal':
                    bad.add(f'{v["file"]}#{r["index"]}')
        used = {f['source'] for f in TF['frames']}
        self.assertTrue(bad)
        self.assertFalse(bad & used)

    def test_keyframe_selection(self):
        def rec(i, x, yaw=0.0, blur=1.0, tracking='normal'):
            c, s_ = math.cos(yaw), math.sin(yaw)
            T = np.array([[c, 0, s_, x], [0, 1, 0, 1.5], [-s_, 0, c, 0], [0, 0, 0, 1.0]])
            return {'index': i, 'time': i / 30, 'transform': T.T.ravel().tolist(), 'blurPixels': blur, 'tracking': tracking}
        # walking 1 cm per frame: a keyframe every ~12 cm, the sharpest of the next 0.3 s
        recs = [rec(i, i * 0.01, blur=5 if i % 3 else 1) for i in range(120)]
        sel = select_keyframes(recs)
        self.assertTrue(8 <= len(sel) <= 12, len(sel))
        self.assertTrue(all(r['blurPixels'] == 1 for r in sel))
        # turning in place also makes keyframes; blurry or limited-tracking frames never do
        turn = [rec(i, 0, yaw=i * 0.02) for i in range(60)] + [rec(60, 0, yaw=2, blur=20), rec(61, 0, yaw=3, tracking='limited')]
        sel = select_keyframes(turn)
        self.assertTrue(7 <= len(sel) <= 11, len(sel))
        self.assertNotIn(60, [r['index'] for r in sel])
        self.assertNotIn(61, [r['index'] for r in sel])
        self.assertEqual(len(select_keyframes(recs, max_frames=4)), 4)

    def test_images_have_no_exif_rotation(self):
        with Image.open(os.path.join(DS, TF['frames'][0]['file_path'])) as im:
            self.assertNotEqual(im.getexif().get(0x0112), 6)
            self.assertEqual(im.size, (TF['frames'][0]['w'], TF['frames'][0]['h']))


class Renderer(unittest.TestCase):
    def test_gradients_match_finite_differences(self):
        torch.manual_seed(0)
        dt = torch.float64
        n = 5
        args = [(torch.randn(n, 3, dtype=dt) * 0.3 + torch.tensor([0, 0, 3.0], dtype=dt)).requires_grad_(),
                torch.randn(n, 4, dtype=dt).requires_grad_(), (torch.rand(n, 3, dtype=dt) * 0.2 + 0.05).requires_grad_(),
                (torch.rand(n, dtype=dt) * 0.8 + 0.1).requires_grad_(), torch.rand(n, 3, dtype=dt).requires_grad_()]
        K = torch.tensor([[20., 0, 8], [0, 20, 6], [0, 0, 1]], dtype=dt)
        bg = torch.tensor([0.1, 0.2, 0.3], dtype=dt)

        def f(*x):
            o = G.rasterize_torch(*x, torch.eye(4, dtype=dt), K, 16, 12, bg, tile=8)
            return o['rgb'].sum() + 0.1 * o['depth'].sum()
        self.assertTrue(torch.autograd.gradcheck(f, args, eps=1e-6, atol=1e-4))

    def test_projection_convention(self):
        """OpenCV camera: +x right, +y down; a splat at (0.5, 0.3, 2) lands at pixel (75, 65)"""
        o = G.rasterize_torch(torch.tensor([[0.5, 0.3, 2.0]]), torch.tensor([[1., 0, 0, 0]]), torch.tensor([[0.02] * 3]),
                              torch.tensor([0.99]), torch.tensor([[1., 0, 0]]), torch.eye(4),
                              torch.tensor([[100., 0, 50], [0, 100, 50], [0, 0, 1]]), 100, 100, torch.zeros(3))
        r, c = (o['alpha'] == o['alpha'].max()).nonzero()[0].tolist()
        self.assertLessEqual(abs(r - 64.5), 1)
        self.assertLessEqual(abs(c - 74.5), 1)
        self.assertAlmostEqual(float(o['depth'][r, c] / o['alpha'][r, c]), 2.0, places=3)

    def test_gl_to_cv_viewmat(self):
        c2w = torch.eye(4)
        c2w[:3, 3] = torch.tensor([1.0, 2.0, 3.0])
        vm = G.viewmat_from_c2w_gl(c2w)
        # a point 2 m in front of an OpenGL camera (−z) is at +z = 2 in OpenCV camera space
        p = vm @ torch.tensor([1.0, 2.0, 1.0, 1.0])
        self.assertTrue(torch.allclose(p[:3], torch.tensor([0.0, 0.0, 2.0])))

    def test_sh_degree0_is_the_base_color(self):
        g = G.Gaussians(np.zeros((2, 3)), np.array([[0.2, 0.4, 0.6], [1, 0, 0]]), sh_degree=3, init_scale=0.1)
        c = g.colors(torch.tensor([0.0, 0.0, 5.0]), 3)
        self.assertTrue(torch.allclose(c, torch.tensor([[0.2, 0.4, 0.6], [1, 0, 0]]), atol=1e-5))


class Training(unittest.TestCase):
    def test_reconstruction_learned_the_house(self):
        m = load(os.path.join(RUN, 'metrics.json'))
        self.assertGreater(m['final_psnr'], 22, m)
        self.assertGreater(m['final_psnr'], m['start_psnr'] + 8, m)
        self.assertGreater(m['splats'], 20000, 'densification added detail')

    def test_generative_rounds_ran(self):
        m = load(os.path.join(RUN, 'metrics.json'))
        self.assertEqual(m['fixer'], 'classic')
        self.assertTrue(m['rounds'] and all(r['views'] > 0 for r in m['rounds']), m)
        self.assertTrue(any(n.startswith('gen-') for n in os.listdir(os.path.join(RUN, 'previews'))))

    def test_exports_round_trip(self):
        g = G.load_ply_gaussians(os.path.join(RUN, 'scene.ply'), sh_degree=1)
        with open(os.path.join(RUN, 'scene.splat'), 'rb') as f:
            raw = f.read()
        self.assertEqual(len(raw) % 32, 0)
        rec = np.frombuffer(raw, dtype=[('p', '<f4', 3), ('s', '<f4', 3), ('c', 'u1', 4), ('r', 'u1', 4)])
        self.assertLessEqual(len(rec), len(g))
        self.assertGreater(len(rec), 0.5 * len(g))
        # most important first, positions inside the house (x ±4, z ±2, 0..2.6 m)
        self.assertTrue(np.all(np.percentile(rec['p'], 50, axis=0) > [-4.5, -0.3, -2.5]))
        self.assertTrue(np.all(np.percentile(rec['p'], 50, axis=0) < [4.5, 2.9, 2.5]))
        q = rec['r'].astype(float) - 128
        self.assertTrue(np.all(np.abs(np.linalg.norm(q, axis=1) - 128) < 3), 'unit quaternions')

    def test_photo_cameras_for_the_viewer(self):
        cams = load(os.path.join(RUN, 'cameras.json'))['cameras']
        self.assertEqual(len(cams), len(TF['frames']))
        self.assertEqual(cams[0]['transform'], TF['frames'][0]['transform_matrix'])


class PlayCanvas(unittest.TestCase):
    def test_sog_files_and_cut_dollhouse(self):
        import zipfile
        sys.path.insert(0, SPLAT)
        import playcanvas
        for name in ('scene.sog', 'dollhouse.sog'):
            path = os.path.join(RUN, name)
            self.assertTrue(zipfile.is_zipfile(path), name)
            with zipfile.ZipFile(path) as z:
                meta = json.loads(z.read('meta.json'))
            self.assertIn('count', json.dumps(meta))
        cams = load(os.path.join(RUN, 'cameras.json'))
        _, y, _, _ = playcanvas.ply_heights(os.path.join(RUN, 'scene.ply'))
        self.assertEqual(cams['splats'], len(y))
        self.assertTrue(1.2 <= cams['dollhouse_cut'] < 2.6, cams['dollhouse_cut'])
        # the cut keeps the floor and walls, drops the ceiling
        with tempfile.TemporaryDirectory() as d:
            n = playcanvas.cut_ply(os.path.join(RUN, 'scene.ply'), os.path.join(d, 'low.ply'), cams['dollhouse_cut'])
            _, low, _, _ = playcanvas.ply_heights(os.path.join(d, 'low.ply'))
        self.assertEqual(n, (y < cams['dollhouse_cut']).sum())
        self.assertLess(low.max(), cams['dollhouse_cut'])
        self.assertTrue(0.4 * len(y) < n < len(y))

    def test_viewer_settings(self):
        sys.path.insert(0, SPLAT)
        import playcanvas
        cams = load(os.path.join(RUN, 'cameras.json'))
        rooms = playcanvas.rooms_from_bundle(os.path.join(OUT, 'FakeHouse.zip'))
        self.assertEqual([r['name'] for r in rooms], ['Living room', 'Bedroom'])
        st = playcanvas.settings(cams['cameras'], rooms, cams['bounds'])
        self.assertEqual(st['version'], 2)
        self.assertEqual([a['title'] for a in st['annotations']], ['Living room', 'Bedroom'])
        self.assertIn('20.0 m²', st['annotations'][0]['text'])
        cam = st['cameras'][0]['initial']
        self.assertGreater(cam['position'][1], 3, 'starts above the house')
        track = st['animTracks'][0]['keyframes']
        n = len(track['times'])
        self.assertGreater(n, 5)
        self.assertEqual(len(track['values']['position']), 3 * n)
        self.assertEqual(track['times'], sorted(track['times']))
        self.assertTrue(all(abs(v - 1.6) < 1e-6 for v in track['values']['position'][1::3]), 'eye height')


class Fixers(unittest.TestCase):
    def test_classic_fills_only_the_holes(self):
        img = np.zeros((40, 60, 3), np.uint8)
        img[:, :30] = (200, 50, 50)
        img[:, 30:] = (50, 50, 200)
        mask = np.zeros((40, 60), bool)
        mask[10:30, 20:40] = True
        broken = img.copy()
        broken[mask] = 0
        out = fixers.ClassicFixer()(broken, mask)
        self.assertTrue(np.array_equal(out[0], img[0]), 'pixels far from the hole are untouched')
        self.assertGreater(out[20, 22, 0], 120)  # filled from its red side
        self.assertGreater(out[20, 38, 2], 120)  # and from its blue side
        self.assertLess(np.abs(out[mask].astype(int) - img[mask]).mean(), 60)

    def test_providers_explain_missing_setup(self):
        env = {k: v for k, v in os.environ.items() if k not in ('FAL_KEY', 'OPENAI_API_KEY', 'DIFIX_REPO')}
        for name, needle in (('fal', 'FAL_KEY'), ('openai', 'OPENAI_API_KEY'), ('difix', 'Difix3D')):
            r = subprocess.run([sys.executable, '-c', f'import sys; sys.path.insert(0, {SPLAT!r}); import fixers; fixers.get({name!r})'],
                               capture_output=True, text=True, env=env)
            self.assertNotEqual(r.returncode, 0)
            self.assertIn(needle, r.stderr + r.stdout)


class Html(unittest.TestCase):
    def test_splat_html_embeds_scene_cameras_and_photos(self):
        with open(os.path.join(RUN, 'splat.html'), encoding='utf-8') as f:
            html = f.read()
        start = html.index('<script id="data" type="application/json">') + len('<script id="data" type="application/json">')
        data = json.loads(html[start:html.index('</script>', start)])
        self.assertEqual(data['entry'], 'startSplat')
        # the compact PlayCanvas files when Node.js made them, else the .splat
        if os.path.exists(os.path.join(RUN, 'scene.sog')):
            self.assertEqual(sorted(k for k in data['files'] if k.endswith('.sog')), ['dollhouse.sog', 'scene.sog'])
        else:
            self.assertTrue('scene.splat' in data['files'], 'scene embedded')
        cams = json.loads(base64.b64decode(data['files']['cameras.json']))['cameras']
        self.assertTrue(cams)
        for c in cams:
            self.assertIn(c['photo'], data['files'])
            im = Image.open(io.BytesIO(base64.b64decode(data['files'][c['photo']])))
            self.assertGreater(im.height, im.width, 'photos are upright (portrait)')


if __name__ == '__main__':
    unittest.main(verbosity=1)
