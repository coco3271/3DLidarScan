"""3D Gaussian splats: the model, a differentiable renderer, densification, and file export.

Two renderers with the same interface:
  - gsplat (https://github.com/nerfstudio-project/gsplat): CUDA, fast, used when installed and
    an NVIDIA GPU is present; this is what a real house needs
  - a reference renderer in plain PyTorch: CPU / Apple MPS, tile-based, exact 3DGS math
    (EWA projection, depth-sorted alpha compositing); fine for tests and small previews

Cameras use the OpenCV convention internally (x right, y down, looking down +z); the dataset
stores OpenGL camera-to-world matrices, converted by `viewmat_from_c2w_gl`.
"""
import math

import numpy as np
import torch
import torch.nn.functional as F

SH_C0 = 0.28209479177387814
SH_C1 = 0.4886025119029199
SH_C2 = (1.0925484305920792, -1.0925484305920792, 0.31539156525252005, -1.0925484305920792, 0.5462742152960396)
SH_C3 = (-0.5900435899266435, 2.890611442640554, -0.4570457994644658, 0.3731763325901154,
         -0.4570457994644658, 1.445305721320277, -0.5900435899266435)

try:
    from gsplat import rasterization as _gsplat_rasterization
except Exception:  # not installed, or no CUDA build
    _gsplat_rasterization = None


def viewmat_from_c2w_gl(c2w_gl):
    """OpenGL camera-to-world (4x4) → OpenCV world-to-camera"""
    flip = torch.diag(torch.tensor([1.0, -1.0, -1.0, 1.0], dtype=c2w_gl.dtype, device=c2w_gl.device))
    return torch.linalg.inv(c2w_gl @ flip)


def quat_to_rot(q):
    """(N,4) w,x,y,z (any norm) → (N,3,3)"""
    q = F.normalize(q, dim=-1)
    w, x, y, z = q.unbind(-1)
    return torch.stack([
        1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
        2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
        2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)], -1).reshape(-1, 3, 3)


def eval_sh(deg, sh, dirs):
    """sh (N, K, 3) with K = (deg+1)², dirs (N,3) unit → (N,3) colors (before the +0.5 offset)"""
    out = SH_C0 * sh[:, 0]
    if deg < 1:
        return out
    x, y, z = dirs[:, 0:1], dirs[:, 1:2], dirs[:, 2:3]
    out = out - SH_C1 * y * sh[:, 1] + SH_C1 * z * sh[:, 2] - SH_C1 * x * sh[:, 3]
    if deg < 2:
        return out
    xx, yy, zz, xy, yz, xz = x * x, y * y, z * z, x * y, y * z, x * z
    out = (out + SH_C2[0] * xy * sh[:, 4] + SH_C2[1] * yz * sh[:, 5] + SH_C2[2] * (2 * zz - xx - yy) * sh[:, 6]
           + SH_C2[3] * xz * sh[:, 7] + SH_C2[4] * (xx - yy) * sh[:, 8])
    if deg < 3:
        return out
    return (out + SH_C3[0] * y * (3 * xx - yy) * sh[:, 9] + SH_C3[1] * xy * z * sh[:, 10]
            + SH_C3[2] * y * (4 * zz - xx - yy) * sh[:, 11] + SH_C3[3] * z * (2 * zz - 3 * xx - 3 * yy) * sh[:, 12]
            + SH_C3[4] * x * (4 * zz - xx - yy) * sh[:, 13] + SH_C3[5] * z * (xx - yy) * sh[:, 14]
            + SH_C3[6] * x * (xx - 3 * yy) * sh[:, 15])


class Gaussians(torch.nn.Module):
    """Learnable splats: means, log-scales, rotations, opacity logits, SH colors"""

    def __init__(self, xyz, rgb, sh_degree=3, init_scale=None):
        super().__init__()
        xyz = torch.as_tensor(xyz, dtype=torch.float32)
        rgb = torch.as_tensor(rgb, dtype=torch.float32)
        n = len(xyz)
        if init_scale is None:
            # mean distance to the 3 nearest neighbours (on a sample, to keep it cheap)
            init_scale = knn_scale(xyz)
        self.sh_degree = sh_degree
        self.means = torch.nn.Parameter(xyz.clone())
        self.log_scales = torch.nn.Parameter(torch.log(torch.as_tensor(init_scale, dtype=torch.float32).expand(n).clone())[:, None].repeat(1, 3))
        self.quats = torch.nn.Parameter(torch.tensor([1.0, 0, 0, 0]).repeat(n, 1))
        self.opacity = torch.nn.Parameter(torch.logit(torch.full((n,), 0.1)))
        self.sh0 = torch.nn.Parameter(((rgb - 0.5) / SH_C0)[:, None, :])
        self.shN = torch.nn.Parameter(torch.zeros(n, (sh_degree + 1) ** 2 - 1, 3))

    def __len__(self):
        return self.means.shape[0]

    def params(self):
        return {'means': self.means, 'log_scales': self.log_scales, 'quats': self.quats,
                'opacity': self.opacity, 'sh0': self.sh0, 'shN': self.shN}

    def colors(self, cam_pos, degree):
        sh = torch.cat([self.sh0, self.shN], 1)[:, :(degree + 1) ** 2]
        dirs = F.normalize(self.means - cam_pos, dim=-1)
        return torch.clamp(eval_sh(degree, sh, dirs) + 0.5, min=0)


def knn_scale(xyz, k=3, sample=20000):
    """Per-point initial size: mean distance to the k nearest neighbours"""
    n = len(xyz)
    out = torch.empty(n)
    ref = xyz if n <= sample else xyz[torch.randperm(n)[:sample]]
    for i in range(0, n, 4096):
        d = torch.cdist(xyz[i:i + 4096], ref)
        out[i:i + 4096] = d.topk(k + 1, largest=False).values[:, 1:].mean(1)
    return out.clamp(1e-4, 0.5)


# ---- rendering -----------------------------------------------------------------------------------

def render(g, viewmat, K, width, height, sh_degree, bg, backend='auto'):
    """→ dict(rgb (H,W,3), depth (H,W), alpha (H,W), means2d (for densification), visible (N,) bool)"""
    scales = torch.exp(g.log_scales)
    opac = torch.sigmoid(g.opacity)
    cam_pos = torch.linalg.inv(viewmat)[:3, 3]
    colors = g.colors(cam_pos, sh_degree)
    if backend == 'auto':
        backend = 'gsplat' if _gsplat_rasterization is not None and g.means.is_cuda else 'torch'
    if backend == 'gsplat':
        rc, ra, info = _gsplat_rasterization(g.means, F.normalize(g.quats, dim=-1), scales, opac, colors,
                                             viewmat[None], K[None], width, height, render_mode='RGB+ED',
                                             backgrounds=bg[None], packed=False)
        info['means2d'].retain_grad()
        radii = info['radii'][0]
        visible = (radii > 0).all(-1) if radii.dim() == 2 else radii > 0
        # gsplat's expected depth is normalized by alpha; return the accumulated depth like the
        # reference renderer (callers divide by alpha)
        return {'rgb': rc[0, ..., :3], 'depth': rc[0, ..., 3] * ra[0, ..., 0], 'alpha': ra[0, ..., 0],
                'means2d': info['means2d'], 'means2d_index': None, 'visible': visible}
    return rasterize_torch(g.means, g.quats, scales, opac, colors, viewmat, K, width, height, bg)


def rasterize_torch(means, quats, scales, opac, colors, viewmat, K, W, H, bg, tile=32):
    """Reference 3DGS rasterizer in plain PyTorch (differentiable through autograd)"""
    dev = means.device
    R, t = viewmat[:3, :3], viewmat[:3, 3]
    pc = means @ R.T + t
    z = pc[:, 2]
    fx, fy, cx, cy = K[0, 0], K[1, 1], K[0, 2], K[1, 2]
    front = z > 0.05
    idx = torch.nonzero(front).squeeze(1)
    pc, zf = pc[idx], z[idx]
    # EWA: 3D covariance through the projection's Jacobian (clamped like 3DGS, for stability)
    lim_x, lim_y = 1.3 * (W / 2) / fx, 1.3 * (H / 2) / fy
    tx = torch.clamp(pc[:, 0] / zf, -lim_x, lim_x) * zf
    ty = torch.clamp(pc[:, 1] / zf, -lim_y, lim_y) * zf
    Rg = quat_to_rot(quats[idx])
    S = scales[idx]
    M = Rg * S[:, None, :]
    cov3 = M @ M.transpose(1, 2)
    covc = R @ cov3 @ R.T
    dt = means.dtype
    J = torch.zeros(len(idx), 2, 3, device=dev, dtype=dt)
    J[:, 0, 0] = fx / zf
    J[:, 0, 2] = -fx * tx / zf ** 2
    J[:, 1, 1] = fy / zf
    J[:, 1, 2] = -fy * ty / zf ** 2
    cov2 = J @ covc @ J.transpose(1, 2) + 0.3 * torch.eye(2, device=dev, dtype=dt)
    a, bb, c = cov2[:, 0, 0], cov2[:, 0, 1], cov2[:, 1, 1]
    det = (a * c - bb * bb).clamp(min=1e-12)
    conic = torch.stack([c / det, -bb / det, a / det], -1)
    mid = (a + c) / 2
    lam = mid + torch.sqrt((mid * mid - det).clamp(min=0.1))
    radius = torch.ceil(3 * torch.sqrt(lam))
    u = fx * pc[:, 0] / zf + cx
    v = fy * pc[:, 1] / zf + cy
    means2d = torch.stack([u, v], -1)
    if means2d.requires_grad:
        means2d.retain_grad()  # its gradient tells the densifier where detail is missing
    u, v = means2d[:, 0], means2d[:, 1]
    on = (u + radius > 0) & (u - radius < W) & (v + radius > 0) & (v - radius < H)
    visible = torch.zeros(len(means), dtype=torch.bool, device=dev)
    visible[idx[on]] = True
    order = torch.argsort(zf)
    order = order[on[order]]
    col = colors[idx]
    op = opac[idx]

    rows_ = []
    du, dv = u.detach(), v.detach()
    rad = radius.detach()
    for y0 in range(0, H, tile):
        row = []
        y1 = min(H, y0 + tile)
        for x0 in range(0, W, tile):
            x1 = min(W, x0 + tile)
            sel = order[(du[order] + rad[order] >= x0) & (du[order] - rad[order] < x1)
                        & (dv[order] + rad[order] >= y0) & (dv[order] - rad[order] < y1)]
            ys, xs = torch.meshgrid(torch.arange(y0, y1, device=dev, dtype=dt) + 0.5,
                                    torch.arange(x0, x1, device=dev, dtype=dt) + 0.5, indexing='ij')
            if len(sel) == 0:
                row.append((bg.expand(y1 - y0, x1 - x0, 3), torch.zeros(y1 - y0, x1 - x0, device=dev, dtype=dt),
                            torch.zeros(y1 - y0, x1 - x0, device=dev, dtype=dt)))
                continue
            dx = xs.reshape(-1, 1) - u[sel][None]
            dy = ys.reshape(-1, 1) - v[sel][None]
            cs = conic[sel]
            power = -0.5 * (cs[:, 0] * dx * dx + cs[:, 2] * dy * dy) - cs[:, 1] * dx * dy
            alpha = torch.clamp(op[sel][None] * torch.exp(torch.clamp(power, max=0)), max=0.99)
            alpha = alpha * (alpha > 1 / 255)
            trans = torch.cumprod(torch.cat([torch.ones_like(alpha[:, :1]), 1 - alpha[:, :-1]], 1), 1)
            w = alpha * trans
            a_acc = w.sum(1)
            rgb = w @ col[sel] + (1 - a_acc)[:, None] * bg
            d = w @ zf[sel]
            row.append((rgb.reshape(y1 - y0, x1 - x0, 3), d.reshape(y1 - y0, x1 - x0), a_acc.reshape(y1 - y0, x1 - x0)))
        rows_.append(row)
    img = torch.cat([torch.cat([r[0] for r in row], 1) for row in rows_], 0)
    dep = torch.cat([torch.cat([r[1] for r in row], 1) for row in rows_], 0)
    acc = torch.cat([torch.cat([r[2] for r in row], 1) for row in rows_], 0)
    return {'rgb': img, 'depth': dep, 'alpha': acc, 'means2d': means2d, 'means2d_index': idx, 'visible': visible}


# ---- losses ------------------------------------------------------------------------------------------

def ssim(x, y, window=11):
    """x, y (H,W,3) in 0..1 → mean SSIM"""
    x, y = x.permute(2, 0, 1)[None], y.permute(2, 0, 1)[None]
    g = torch.exp(-((torch.arange(window, device=x.device) - window // 2) ** 2) / (2 * 1.5 ** 2))
    g = (g / g.sum())
    k = (g[:, None] * g[None]).expand(3, 1, window, window)
    f = lambda t: F.conv2d(t, k, padding=window // 2, groups=3)
    mx, my = f(x), f(y)
    sxx, syy, sxy = f(x * x) - mx * mx, f(y * y) - my * my, f(x * y) - mx * my
    c1, c2 = 0.01 ** 2, 0.03 ** 2
    return (((2 * mx * my + c1) * (2 * sxy + c2)) / ((mx * mx + my * my + c1) * (sxx + syy + c2))).mean()


def psnr(x, y):
    return float(-10 * torch.log10(F.mse_loss(x, y).clamp(min=1e-10)))


# ---- densification: clone small, split large, prune transparent (Kerbl et al. 2023) -----------------

class Densifier:
    def __init__(self, extent, grad_thresh=0.0002, refine_every=100, start=500, stop=15000, reset_every=3000,
                 prune_opacity=0.005, max_gaussians=3_000_000):
        self.extent = extent
        self.grad_thresh, self.refine_every, self.start, self.stop = grad_thresh, refine_every, start, stop
        self.reset_every, self.prune_opacity, self.max_gaussians = reset_every, prune_opacity, max_gaussians
        self.grad = None
        self.count = None

    def accumulate(self, g, out, width, height):
        m2 = out['means2d']
        if m2.grad is None:
            return
        grad = m2.grad.detach()
        if grad.dim() == 3:
            grad = grad[0]
        grad = grad.clone()
        grad[:, 0] *= width / 2
        grad[:, 1] *= height / 2
        norm = grad.norm(dim=-1)
        n = len(g)
        if self.grad is None or len(self.grad) != n:
            self.grad = torch.zeros(n, device=norm.device)
            self.count = torch.zeros(n, device=norm.device)
        ids = out['means2d_index']
        if ids is None:  # gsplat: one entry per gaussian
            vis = out['visible']
            self.grad[vis] += norm[vis]
            self.count[vis] += 1
        else:
            vis = out['visible'][ids]
            self.grad[ids[vis]] += norm[vis]
            self.count[ids[vis]] += 1

    def step(self, g, opt, it):
        """Change the gaussians in place (and the optimizer's state with them). Returns a note or None."""
        if it % self.reset_every == 0 and self.start < it < self.stop:
            with torch.no_grad():
                g.opacity.clamp_(max=float(torch.logit(torch.tensor(0.01))))
            reset_adam(opt, g.opacity)
            return 'opacity reset'
        if not (self.start <= it < self.stop and it % self.refine_every == 0) or self.grad is None:
            return None
        avg = self.grad / self.count.clamp(min=1)
        high = avg > self.grad_thresh
        scale = torch.exp(g.log_scales).max(1).values
        small = scale <= 0.01 * self.extent
        clone = high & small
        split = high & ~small
        room = self.max_gaussians - len(g)
        if room <= 0:
            clone[:] = False; split[:] = False
        n0 = len(g)
        with torch.no_grad():
            new = {}
            P = g.params()
            ci = torch.nonzero(clone).squeeze(1)
            si = torch.nonzero(split).squeeze(1)
            # split: two children sampled inside the parent, 1.6x smaller
            sc = torch.exp(g.log_scales[si])
            R = quat_to_rot(g.quats[si])
            samples = [(R @ (torch.randn_like(sc) * sc)[..., None]).squeeze(-1) + g.means[si] for _ in range(2)]
            for k, p in P.items():
                parts = [p.data[ci]]
                if k == 'means':
                    parts += samples
                elif k == 'log_scales':
                    parts += [p.data[si] - math.log(1.6)] * 2
                else:
                    parts += [p.data[si]] * 2
                new[k] = torch.cat(parts)
            keep = ~split
            prune = (torch.sigmoid(g.opacity.data) < self.prune_opacity)
            if it > self.reset_every:
                prune |= scale > 0.1 * self.extent
            keep &= ~prune
            replace_params(g, opt, {k: torch.cat([p.data[keep], new[k]]) for k, p in P.items()}, keep, len(new['means']))
        self.grad = None
        return f'{n0} → {len(g)} gaussians (+{int(clone.sum())} cloned, {int(split.sum())} split, -{int((prune & ~split).sum())} pruned)'


def reset_adam(opt, param):
    for group in opt.param_groups:
        for p in group['params']:
            if p is param and p in opt.state:
                for v in opt.state[p].values():
                    if torch.is_tensor(v) and v.shape == p.shape:
                        v.zero_()


def replace_params(g, opt, values, keep, n_new):
    """Swap in resized parameters (autograd can't resize a parameter in place) and carry Adam's
    moments over: surviving gaussians keep theirs, new ones start from zero"""
    for name, value in values.items():
        old = getattr(g, name)
        new = torch.nn.Parameter(value)
        setattr(g, name, new)
        for group in opt.param_groups:
            if group['params'][0] is old:
                group['params'][0] = new
        st = opt.state.pop(old, None)
        if st:
            for k, v in list(st.items()):
                if torch.is_tensor(v) and v.dim() > 0 and v.shape[0] == keep.shape[0]:
                    st[k] = torch.cat([v[keep], torch.zeros((n_new,) + v.shape[1:], device=v.device, dtype=v.dtype)])
            opt.state[new] = st


# ---- export ------------------------------------------------------------------------------------------

def export_ply(g, path):
    """The standard 3DGS .ply (SuperSplat, Spark, Polycam, nerfstudio, Unity/Unreal plugins read it)"""
    with torch.no_grad():
        xyz = g.means.cpu().numpy()
        n = len(xyz)
        f_dc = g.sh0[:, 0].cpu().numpy()
        f_rest = g.shN.transpose(1, 2).reshape(n, -1).cpu().numpy()
        op = g.opacity.cpu().numpy()[:, None]
        sc = g.log_scales.cpu().numpy()
        rot = F.normalize(g.quats, dim=-1).cpu().numpy()
    cols = (['x', 'y', 'z', 'nx', 'ny', 'nz'] + [f'f_dc_{i}' for i in range(3)] + [f'f_rest_{i}' for i in range(f_rest.shape[1])]
            + ['opacity'] + [f'scale_{i}' for i in range(3)] + [f'rot_{i}' for i in range(4)])
    data = np.concatenate([xyz, np.zeros_like(xyz), f_dc, f_rest, op, sc, rot], 1).astype('<f4')
    header = 'ply\nformat binary_little_endian 1.0\n' + f'element vertex {n}\n' + ''.join(f'property float {c}\n' for c in cols) + 'end_header\n'
    with open(path, 'wb') as f:
        f.write(header.encode())
        f.write(data.tobytes())


def to_splat_bytes(g, min_opacity=0.02):
    """The compact .splat format (32 bytes per gaussian, most important first), read by Spark and
    most web viewers. View-dependent color is dropped (base color only)."""
    with torch.no_grad():
        op = torch.sigmoid(g.opacity)
        sc = torch.exp(g.log_scales)
        keep = op >= min_opacity
        order = torch.argsort((op * sc.prod(1))[keep], descending=True)
        xyz = g.means[keep][order].cpu().numpy().astype('<f4')
        s = sc[keep][order].cpu().numpy().astype('<f4')
        rgb = (0.5 + SH_C0 * g.sh0[keep][order][:, 0]).clamp(0, 1).cpu().numpy()
        a = op[keep][order].cpu().numpy()
        q = F.normalize(g.quats[keep][order], dim=-1).cpu().numpy()
    n = len(xyz)
    rec = np.zeros(n, dtype=[('p', '<f4', 3), ('s', '<f4', 3), ('c', 'u1', 4), ('r', 'u1', 4)])
    rec['p'], rec['s'] = xyz, s
    rec['c'] = np.clip(np.concatenate([rgb, a[:, None]], 1) * 255 + 0.5, 0, 255).astype(np.uint8)
    rec['r'] = np.clip(q * 128 + 128, 0, 255).astype(np.uint8)
    return rec.tobytes()


def load_ply_gaussians(path, sh_degree=3):
    """Read a standard 3DGS .ply (ours, or one trained elsewhere: Brush, OpenSplat, nerfstudio)"""
    with open(path, 'rb') as f:
        data = f.read()
    end = data.index(b'end_header\n') + len(b'end_header\n')
    header = data[:end].decode()
    n = int(header.split('element vertex ')[1].split()[0])
    names = [l.split()[-1] for l in header.splitlines() if l.startswith('property')]
    arr = np.frombuffer(data[end:], dtype='<f4', count=n * len(names)).reshape(n, len(names))
    col = {k: arr[:, i] for i, k in enumerate(names)}
    g = Gaussians(np.stack([col['x'], col['y'], col['z']], 1), np.zeros((n, 3)), sh_degree, init_scale=0.01)
    rest = sorted([k for k in names if k.startswith('f_rest_')], key=lambda k: int(k.split('_')[-1]))
    with torch.no_grad():
        g.sh0.copy_(torch.tensor(np.stack([col[f'f_dc_{i}'] for i in range(3)], 1))[:, None])
        if rest:
            r = torch.tensor(np.stack([col[k] for k in rest], 1)).reshape(n, 3, -1).transpose(1, 2)
            m = min(r.shape[1], g.shN.shape[1])
            g.shN[:, :m] = r[:, :m]
        g.opacity.copy_(torch.tensor(col['opacity']))
        g.log_scales.copy_(torch.tensor(np.stack([col[f'scale_{i}'] for i in range(3)], 1)))
        g.quats.copy_(torch.tensor(np.stack([col[f'rot_{i}'] for i in range(4)], 1)))
    return g
