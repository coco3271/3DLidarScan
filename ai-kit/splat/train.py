#!/usr/bin/env python3
"""Train a photoreal Gaussian-splat scene from a scan dataset (export_dataset.py), then make it
clean with generative AI: "reconstruction as generation".

usage: train.py <dataset> -o splat-out [--steps 30000] [--fixer difix|fal|openai|classic|none]
                [--downscale 1] [--device auto|cuda|mps|cpu] [--eval]

Stage 1, reconstruction (what the capture saw). Standard 3DGS: start from the LiDAR point
  cloud, fit color + SSIM to every photo, densify where detail is missing. Two additions for
  phone captures: LiDAR depth supervision (walls stay flat, no fog in front of them) and a
  per-photo color correction (the iPhone changes exposure and white balance as you walk).

Stage 2, generation (what it didn't see). From the walking path, step back and turn to views
  nobody photographed, render them, repair each render with the fixer (fixers.py), and train
  on the repaired renders too, at lower weight and only where the scene was unreliable. This is
  repeated with views farther from the capture each round (progressive, as in Difix3D+), so the
  scene stays consistent and the repairs become part of the 3D scene itself.

Writes splat-out/: scene.ply (standard 3DGS), scene.splat (compact, for the web viewer),
cameras.json, metrics.json, previews/*.jpg. Then: make_splat_html.py splat-out → splat.html.
"""
import argparse
import json
import math
import os
import random
import sys
import time

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gaussians as G  # noqa: E402
import fixers  # noqa: E402
from export_dataset import read_ply_points  # noqa: E402


class View:
    """One training camera: image, intrinsics, OpenCV world-to-camera, optional LiDAR depth"""

    def __init__(self, img, K, viewmat, depth=None, weight=1.0, mask=None, name='', appearance=None):
        self.img, self.K, self.viewmat, self.depth = img, K, viewmat, depth
        self.weight, self.mask, self.name, self.appearance = weight, mask, name, appearance
        self.H, self.W = img.shape[:2]


def load_views(ds, downscale, device):
    with open(os.path.join(ds, 'transforms.json')) as f:
        tf = json.load(f)
    views = []
    for i, f in enumerate(tf['frames']):
        im = Image.open(os.path.join(ds, f['file_path'])).convert('RGB')
        s = 1 / downscale
        W, H = max(8, round(f['w'] * s)), max(8, round(f['h'] * s))
        if (W, H) != im.size:
            im = im.resize((W, H), Image.LANCZOS)
        sx, sy = W / f['w'], H / f['h']
        K = torch.tensor([[f['fl_x'] * sx, 0, f['cx'] * sx], [0, f['fl_y'] * sy, f['cy'] * sy], [0, 0, 1]], dtype=torch.float32)
        c2w = torch.tensor(f['transform_matrix'], dtype=torch.float32)
        depth = None
        if f.get('depth_file_path') and os.path.exists(os.path.join(ds, f['depth_file_path'])):
            d = np.asarray(Image.open(os.path.join(ds, f['depth_file_path'])), dtype=np.float32) * tf.get('depth_unit_scale_factor', 0.001)
            depth = torch.tensor(np.asarray(Image.fromarray(d).resize((W, H), Image.NEAREST)))
        img = torch.tensor(np.asarray(im), dtype=torch.float32) / 255
        views.append(View(img.to(device), K.to(device), G.viewmat_from_c2w_gl(c2w).to(device),
                          depth.to(device) if depth is not None else None, name=f['file_path'], appearance=i))
    return tf, views


def cam_center(v):
    return torch.linalg.inv(v.viewmat)[:3, 3]


def make_optimizers(g, extent, steps, lr_scale=1.0):
    lrs = {'means': 1.6e-4 * extent, 'log_scales': 5e-3, 'quats': 1e-3, 'opacity': 5e-2, 'sh0': 2.5e-3, 'shN': 2.5e-3 / 20}
    opt = torch.optim.Adam([{'params': [p], 'lr': lrs[k] * lr_scale, 'name': k} for k, p in g.params().items()], eps=1e-15)
    sched = torch.optim.lr_scheduler.LambdaLR(opt, [lambda s: 0.01 ** min(1, s / steps)] + [lambda s: 1.0] * 5)
    return opt, sched


def novel_views(train, n, reach, rng, device):
    """Viewpoints nobody photographed: step back from a photo spot and turn, or stand between two"""
    out = []
    for _ in range(n):
        v = train[rng.randrange(len(train))]
        c2w = torch.linalg.inv(v.viewmat)  # OpenCV camera-to-world
        fwd, right = c2w[:3, 2], c2w[:3, 0]
        yaw = rng.uniform(-1, 1) * math.radians(35) * reach
        step = -fwd * rng.uniform(0.2, 1.0) * reach + right * rng.uniform(-0.5, 0.5) * reach
        if rng.random() < 0.3:  # between this photo spot and another one
            o = torch.linalg.inv(train[rng.randrange(len(train))].viewmat)
            step = (o[:3, 3] - c2w[:3, 3]) * rng.uniform(0.3, 0.7)
        c, s = math.cos(yaw), math.sin(yaw)
        up = -c2w[:3, 1]
        # rotate the camera about the world's up axis (+Y in the model frame)
        Ry = torch.tensor([[c, 0, s], [0, 1, 0], [-s, 0, c]], dtype=torch.float32, device=device)
        n2w = torch.eye(4, device=device)
        n2w[:3, :3] = Ry @ c2w[:3, :3] if abs(float(up[1])) > 0.5 else c2w[:3, :3]
        n2w[:3, 3] = c2w[:3, 3] + step
        out.append((torch.linalg.inv(n2w), v))
    return out


def nearest_view(train, viewmat):
    p = torch.linalg.inv(viewmat)
    pos, fwd = p[:3, 3], p[:3, 2]
    best = None
    for v in train:
        q = torch.linalg.inv(v.viewmat)
        score = float((q[:3, 3] - pos).norm()) - 0.8 * float(q[:3, 2] @ fwd)
        if best is None or score < best[0]:
            best = (score, v)
    return best[1]


def to_u8(t):
    return (t.detach().clamp(0, 1).cpu().numpy() * 255 + 0.5).astype(np.uint8)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('dataset')
    ap.add_argument('-o', '--out', default='splat-out')
    ap.add_argument('--steps', type=int, default=30000)
    ap.add_argument('--downscale', type=float, default=1, help='train on images this many times smaller')
    ap.add_argument('--device', default='auto')
    ap.add_argument('--backend', default='auto', choices=['auto', 'gsplat', 'torch'])
    ap.add_argument('--sh-degree', type=int, default=3)
    ap.add_argument('--init-points', type=int, default=300_000, help='subsample the LiDAR cloud to this many splats')
    ap.add_argument('--max-gaussians', type=int, default=3_000_000)
    ap.add_argument('--depth-weight', type=float, default=0.2)
    ap.add_argument('--fixer', default='none', choices=['none', 'classic', 'difix', 'fal', 'openai'])
    ap.add_argument('--gen-rounds', type=int, default=3, help='progressive generative rounds')
    ap.add_argument('--gen-views', type=int, default=24, help='new viewpoints repaired per round')
    ap.add_argument('--gen-weight', type=float, default=0.5, help='loss weight of repaired views')
    ap.add_argument('--eval', action='store_true', help='hold out every 8th photo and report PSNR')
    ap.add_argument('--seed', type=int, default=0)
    a = ap.parse_args()

    torch.manual_seed(a.seed)
    rng = random.Random(a.seed)
    if a.device == 'auto':
        a.device = 'cuda' if torch.cuda.is_available() else 'mps' if torch.backends.mps.is_available() else 'cpu'
    dev = torch.device(a.device)
    os.makedirs(os.path.join(a.out, 'previews'), exist_ok=True)
    tf, views = load_views(a.dataset, a.downscale, dev)
    test = [v for i, v in enumerate(views) if a.eval and i % 8 == 4]
    train = [v for v in views if v not in test]
    print(f'{len(train)} training views, {len(test)} held out, {a.device}, '
          f'{"gsplat" if a.backend != "torch" and G._gsplat_rasterization is not None and dev.type == "cuda" else "reference"} renderer')

    centers = torch.stack([cam_center(v) for v in train])
    extent = max(1.0, float((centers - centers.mean(0)).norm(dim=1).max()) * 1.1)
    ply = tf.get('ply_file_path')
    if ply and os.path.exists(os.path.join(a.dataset, ply)):
        xyz, rgb = read_ply_points(os.path.join(a.dataset, ply))
        if len(xyz) > a.init_points:
            keep = np.random.default_rng(a.seed).choice(len(xyz), a.init_points, replace=False)
            xyz, rgb = xyz[keep], rgb[keep]
        rgb = rgb / 255.0
    else:  # no LiDAR: random points around the cameras
        n = min(a.init_points, 100_000)
        xyz = (centers.mean(0).cpu().numpy() + (np.random.default_rng(a.seed).random((n, 3)) - 0.5) * 2 * extent)
        rgb = np.full((n, 3), 0.5)
    g = G.Gaussians(xyz, rgb, a.sh_degree).to(dev)
    print(f'{len(g)} starting splats, scene extent {extent:.2f} m')

    # per-photo color correction (exposure / white balance): 3x3 + offset, starts at identity
    app = torch.nn.Parameter(torch.cat([torch.eye(3), torch.zeros(3, 1)], 1).repeat(len(views), 1, 1).to(dev))
    app_opt = torch.optim.Adam([app], lr=1e-3)
    opt, sched = make_optimizers(g, extent, a.steps)
    dens = G.Densifier(extent, start=min(500, a.steps // 10), stop=int(a.steps * 0.5), refine_every=100,
                       reset_every=max(3000, a.steps // 10), max_gaussians=a.max_gaussians)
    bg = torch.zeros(3, device=dev)

    gen_at = [int(a.steps * f) for f in np.linspace(0.55, 0.85, a.gen_rounds)] if a.fixer != 'none' and a.gen_rounds else []
    fixer = fixers.get(a.fixer) if gen_at else None
    pseudo = []

    def evaluate(tag):
        if not test:
            return None
        with torch.no_grad():
            vals = []
            for v in test:
                out = G.render(g, v.viewmat, v.K, v.W, v.H, g.sh_degree, bg, a.backend)
                vals.append(G.psnr(out['rgb'], v.img))
        p = float(np.mean(vals))
        print(f'  [{tag}] held-out PSNR {p:.2f} dB')
        return p

    metrics = {'start_psnr': evaluate('start')}
    t0 = time.time()
    degree = 0
    for it in range(1, a.steps + 1):
        if it % 1000 == 0 and degree < a.sh_degree:
            degree += 1
        use_pseudo = pseudo and rng.random() < 0.3
        v = rng.choice(pseudo if use_pseudo else train)
        out = G.render(g, v.viewmat, v.K, v.W, v.H, degree, bg, a.backend)
        rgb = out['rgb']
        if v.appearance is not None:
            A = app[v.appearance]
            rgb = (rgb.reshape(-1, 3) @ A[:, :3].T + A[:, 3]).reshape(rgb.shape)
        if v.mask is not None:  # repaired view: learn only where the scene was unreliable
            m = v.mask[..., None]
            loss = v.weight * ((rgb - v.img).abs() * m).sum() / m.sum().clamp(min=1) / 3
        else:
            loss = 0.8 * (rgb - v.img).abs().mean() + 0.2 * (1 - G.ssim(rgb, v.img))
            if v.depth is not None and a.depth_weight > 0:
                ok = (v.depth > 0) & (out['alpha'].detach() > 0.5)
                if ok.any():
                    w = a.depth_weight * (1 - 0.9 * it / a.steps)
                    loss = loss + w * (out['depth'][ok] / out['alpha'][ok].clamp(min=1e-3) - v.depth[ok]).abs().mean()
        loss = loss + 0.01 * torch.sigmoid(g.opacity).mean()  # fewer half-transparent floaters
        loss.backward()
        dens.accumulate(g, out, v.W, v.H)
        opt.step(); opt.zero_grad(set_to_none=True); sched.step()
        app_opt.step(); app_opt.zero_grad(set_to_none=True)
        note = dens.step(g, opt, it)
        if note and note != 'opacity reset' and (it % 1000 == 0 or a.steps < 5000):
            print(f'  step {it}: {note}')
        if it % max(1, a.steps // 20) == 0:
            print(f'  step {it}/{a.steps}  loss {float(loss.detach()):.4f}  {len(g)} splats  {time.time() - t0:.0f}s')

        if it in gen_at:
            r = gen_at.index(it) + 1
            reach = r / len(gen_at)  # progressively farther from the capture
            before = evaluate(f'before generative round {r}')
            made = 0
            with torch.no_grad():
                for vm, src in novel_views(train, a.gen_views, reach, rng, dev):
                    o = G.render(g, vm, src.K, src.W, src.H, g.sh_degree, bg, a.backend)
                    alpha = o['alpha']
                    if float(alpha.mean()) < 0.3 or float((o['depth'] / alpha.clamp(min=1e-3))[alpha > 0.5].median() if (alpha > 0.5).any() else 0) < 0.4:
                        continue  # outside the house or inside a wall
                    render_u8 = to_u8(o['rgb'])
                    unreliable = (alpha < 0.85).cpu().numpy()
                    ref = to_u8(nearest_view(train, vm).img)
                    try:
                        fixed = fixer(render_u8, unreliable, ref)
                    except Exception as e:
                        print(f'  fixer failed on a view: {e}')
                        continue
                    if fixer.name == 'difix':  # repairs everything: learn from the whole image
                        mask = torch.ones_like(alpha)
                    else:
                        mask = torch.tensor(unreliable, dtype=torch.float32, device=dev)
                    if made < 4:
                        Image.fromarray(np.concatenate([render_u8, fixed], 1)).save(os.path.join(a.out, 'previews', f'gen-r{r}-{made}.jpg'), quality=88)
                    pseudo.append(View(torch.tensor(fixed, dtype=torch.float32, device=dev) / 255, src.K, vm,
                                       weight=a.gen_weight, mask=mask, name=f'gen-{r}-{made}'))
                    made += 1
            print(f'  generative round {r}: {made} repaired views (reach {reach:.2f}), {len(pseudo)} total')
            metrics.setdefault('rounds', []).append({'step': it, 'views': made, 'psnr_before': before})

    metrics['final_psnr'] = evaluate('final')
    metrics.update({'splats': len(g), 'steps': a.steps, 'fixer': a.fixer, 'seconds': round(time.time() - t0)})

    G.export_ply(g, os.path.join(a.out, 'scene.ply'))
    with open(os.path.join(a.out, 'scene.splat'), 'wb') as f:
        f.write(G.to_splat_bytes(g))
    cams = []
    for f_, v in zip(tf['frames'], views):
        cams.append({'file': f_['file_path'], 'transform': f_['transform_matrix'], 'w': f_['w'], 'h': f_['h'],
                     'fl_x': f_['fl_x'], 'fl_y': f_['fl_y'], 'cx': f_['cx'], 'cy': f_['cy'], 'manual': f_.get('manual', False)})
    with open(os.path.join(a.out, 'cameras.json'), 'w') as f:
        json.dump({'property': tf.get('property'), 'cameras': cams, 'world_to_model': tf.get('world_to_model')}, f)
    with torch.no_grad():
        for i, v in enumerate((test or train)[:4]):
            o = G.render(g, v.viewmat, v.K, v.W, v.H, g.sh_degree, bg, a.backend)
            Image.fromarray(np.concatenate([to_u8(o['rgb']), to_u8(v.img)], 1)).save(os.path.join(a.out, 'previews', f'view-{i}.jpg'), quality=88)
    with open(os.path.join(a.out, 'metrics.json'), 'w') as f:
        json.dump(metrics, f, indent=1)
    print(f'{a.out}: {len(g)} splats · {metrics["seconds"]}s' + (f' · held-out PSNR {metrics["start_psnr"]:.1f} → {metrics["final_psnr"]:.1f} dB' if test else ''))


if __name__ == '__main__':
    main()
