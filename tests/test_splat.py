#!/usr/bin/env python3
"""Checks for the photoreal splat pipeline (ai-kit/splat): dataset export, the renderer's math,
training, the generative repair rounds and the exported files.

usage: test_splat.py <out-dir>   (run.sh exported <out-dir>/dataset and trained <out-dir>/splat)
Needs torch (CPU is fine); skipped by run.sh when torch isn't installed.
"""
import base64
import io
import json
import os
import subprocess
import sys
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
from make_fake_bundle import trace  # noqa: E402

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

    def test_images_have_no_exif_rotation(self):
        im = Image.open(os.path.join(DS, TF['frames'][0]['file_path']))
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
        self.assertIn('scene.splat', data['files'])
        cams = json.loads(base64.b64decode(data['files']['cameras.json']))['cameras']
        self.assertTrue(cams)
        for c in cams:
            self.assertIn(c['photo'], data['files'])
            im = Image.open(io.BytesIO(base64.b64decode(data['files'][c['photo']])))
            self.assertGreater(im.height, im.width, 'photos are upright (portrait)')


if __name__ == '__main__':
    unittest.main(verbosity=1)
