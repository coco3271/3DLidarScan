#!/usr/bin/env python3
"""Turn a 3D LiDAR Scan export (house-capture/5, folder or .zip) into a Gaussian-splat training
dataset in the nerfstudio layout, which every common splat trainer reads: our train.py,
nerfstudio's splatfacto, gsplat's examples, Brush and OpenSplat (both run on a Mac).

usage: export_dataset.py <bundle-folder-or-zip> [-o dataset] [--max-edge 1920] [--frames auto|video|all|photos]

The training images come from the room videos the app records (video/room-N.mov + per-frame
poses): sharp keyframes every ~12 cm or ~7°, skipping frames the phone moved too fast for.
Scans from older app versions (photos only) work too. Reading video needs ffmpeg.

Writes:
  transforms.json     cameras: per-frame intrinsics + camera-to-world (OpenGL: x right, y up,
                      looking down -z, the same as ARKit), in the model frame of make_model.py
                      (meters, +Y up, floor at y = 0), so splats and model.json line up
  images/NNNN.jpg     sensor-orientation JPEGs with no EXIF (some loaders apply
                      EXIF rotation and some don't; without it, everyone reads the same pixels)
  depth/NNNN.png      LiDAR depth seen from that image's camera: 16-bit millimeters, 0 = none
                      (re-projected, so it is exact even when the depth frame came a moment later)
  points3D.ply        the starting point cloud: every confident LiDAR depth pixel, colored from
                      its RGB frame, merged into 2 cm voxels

Needs numpy and Pillow.
"""
import argparse
import io
import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import zlib

import numpy as np
from PIL import Image

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from make_walkthrough import Bundle  # noqa: E402
import make_model as mm  # noqa: E402

GL = np.diag([1.0, -1.0, -1.0, 1.0])  # OpenGL camera ↔ OpenCV camera (y down, looking down +z)


def mat(t):
    """column-major 16 → 4x4"""
    return np.array(t, dtype=np.float64).reshape(4, 4).T


def model_transform(b, manifest):
    """world → model (floor at 0, walls on x/z) from RoomPlan, like make_model.py; identity without rooms"""
    rooms = [b.json(r.get('file')) for r in manifest.get('rooms') or []]
    rooms = [r for r in rooms if r]
    walls = [w for r in rooms for w in r.get('walls') or []]
    floors = [f for r in rooms for f in r.get('floors') or []]
    if not walls and not floors:
        return np.eye(4)
    return np.array(mm.model_frame(walls, floors), dtype=np.float64)


def load_depth(b, rec):
    raw = b.read(rec['file'])
    if rec['file'].endswith('.f16z'):
        raw = zlib.decompress(raw, -15)
    d = np.frombuffer(raw, '<f2').astype(np.float32).reshape(rec['height'], rec['width'])
    conf = None
    if rec.get('confidence') and b.has(rec['confidence']):
        conf = np.frombuffer(b.read(rec['confidence']), np.uint8).reshape(rec['height'], rec['width'])
    return d, conf


def K3(k):
    """[fx,0,0, 0,fy,0, cx,cy,1] → fx, fy, cx, cy"""
    return k[0], k[4], k[6], k[7]


def depth_points(d, conf, K, c2w_gl, step=1, min_conf=1):
    """depth pixels → world points (N,3) and their pixel coordinates"""
    fx, fy, cx, cy = K
    v, u = np.mgrid[0:d.shape[0]:step, 0:d.shape[1]:step]
    z = d[v, u]
    ok = np.isfinite(z) & (z > 0.1) & (z < 12)
    if conf is not None:
        ok &= conf[v, u] >= min_conf
    u, v, z = u[ok], v[ok], z[ok]
    cam = np.stack([(u - cx) / fx * z, -(v - cy) / fy * z, -z, np.ones_like(z)], 1)
    return (cam @ c2w_gl.T)[:, :3], u, v


def project(pts, c2w_gl, K, w, h):
    """world points → pixel u, v and depth (along the view axis) for an OpenGL camera"""
    w2c = np.linalg.inv(c2w_gl)
    c = pts @ w2c[:3, :3].T + w2c[:3, 3]
    z = -c[:, 2]
    with np.errstate(divide='ignore', invalid='ignore'):
        u = K[0] * c[:, 0] / z + K[2]
        v = K[3] - K[1] * c[:, 1] / z + 0.0
    ok = (z > 0.05) & (u >= 0) & (u < w) & (v >= 0) & (v < h)
    return u, v, z, ok


def zbuffer(u, v, z, w, h):
    """nearest depth per pixel (0 where nothing landed)"""
    out = np.full(h * w, np.inf, dtype=np.float32)
    np.minimum.at(out, v.astype(int) * w + u.astype(int), z.astype(np.float32))
    out[~np.isfinite(out)] = 0
    return out.reshape(h, w)


def write_ply(path, xyz, rgb):
    """binary PLY with normals (nerfstudio, OpenSplat and Brush all read this)"""
    n = len(xyz)
    header = ('ply\nformat binary_little_endian 1.0\n'
              f'element vertex {n}\nproperty float x\nproperty float y\nproperty float z\n'
              'property float nx\nproperty float ny\nproperty float nz\n'
              'property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n')
    rec = np.zeros(n, dtype=[('p', '<f4', 3), ('n', '<f4', 3), ('c', 'u1', 3)])
    rec['p'], rec['c'] = xyz, rgb
    with open(path, 'wb') as f:
        f.write(header.encode())
        f.write(rec.tobytes())


def read_ply_points(path):
    """the x y z / red green blue of a PLY written by write_ply"""
    with open(path, 'rb') as f:
        data = f.read()
    end = data.index(b'end_header\n') + len(b'end_header\n')
    n = int(data[:end].decode().split('element vertex ')[1].split()[0])
    rec = np.frombuffer(data[end:], dtype=[('p', '<f4', 3), ('n', '<f4', 3), ('c', 'u1', 3)], count=n)
    return rec['p'].astype(np.float64), rec['c'].copy()

MAX_BLUR = 6.0  # predicted smear (px at 1920 wide) above which a video frame is skipped


def select_keyframes(recs, move=0.12, turn=0.12, window=0.3, max_blur=MAX_BLUR, max_frames=600):
    """Pick training frames from a video's per-frame poses: a new one each time the phone has
    moved ~12 cm or turned ~7°, taking the sharpest frame (least predicted blur) in the next
    0.3 s; frames with poor tracking or too much blur never count."""
    ok = [r for r in recs if r.get('tracking', 'normal') == 'normal' and r.get('blurPixels', 0) <= max_blur]
    sel, last, i = [], None, 0
    while i < len(ok):
        r = ok[i]
        if last is not None:
            a, b2 = mat(r['transform']), mat(last['transform'])
            d = np.linalg.norm(a[:3, 3] - b2[:3, 3])
            t = math.acos(max(-1.0, min(1.0, float(a[:3, 2] @ b2[:3, 2]))))
            if d < move and t < turn:
                i += 1
                continue
        j, best = i, i
        while j < len(ok) and ok[j]['time'] - r['time'] <= window:
            if ok[j].get('blurPixels', 0) < ok[best].get('blurPixels', 0):
                best = j
            j += 1
        sel.append(ok[best])
        last = ok[best]
        i = best + 1
    if len(sel) > max_frames:
        step = len(sel) / max_frames
        sel = [sel[int(k * step)] for k in range(max_frames)]
    return sel


def decode_frames(b, video, indices):
    """Yield (frame index, RGB array) for the wanted frames, decoding the video once with ffmpeg"""
    if not shutil.which('ffmpeg'):
        sys.exit('ffmpeg is needed to read the scan video (macOS: brew install ffmpeg; Linux: apt install ffmpeg)')
    wanted = set(indices)
    w, h = video['width'], video['height']
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, os.path.basename(video['file']))
        with open(path, 'wb') as f:  # ffmpeg needs a seekable file (.mov keeps its index at the end)
            f.write(b.read(video['file']))
        # sensor orientation as recorded; every frame exactly once, in order (no rate conversion)
        proc = subprocess.Popen(['ffmpeg', '-v', 'error', '-noautorotate', '-i', path, '-f', 'rawvideo', '-pix_fmt', 'rgb24',
                                 '-fps_mode', 'passthrough', '-'], stdout=subprocess.PIPE)
        size = w * h * 3
        n = 0
        try:
            while wanted:
                buf = proc.stdout.read(size)
                if len(buf) < size:
                    break
                if n in wanted:
                    wanted.discard(n)
                    yield n, np.frombuffer(buf, np.uint8).reshape(h, w, 3)
                n += 1
        finally:
            proc.stdout.close()
            proc.kill()
            proc.wait()
    if wanted:
        print(f'  note: {len(wanted)} keyframes were missing from {video["file"]} (it has {n} frames)')


def export(src, out, max_edge=1920, frames='auto', voxel=0.02, max_points=500_000, depth_size=256, max_video_frames=600):
    b = Bundle(src)
    manifest = b.json('manifest.json') or {}
    if not str(manifest.get('format', '')).startswith('house-capture/'):
        sys.exit(f"unsupported bundle format: {manifest.get('format')}")
    W2M = model_transform(b, manifest)
    photos = sorted(b.json(manifest.get('photos') or 'photos/photos.json') or [], key=lambda p: p.get('timestamp', 0))
    depth_recs = [d for d in b.json(manifest.get('depthFrames') or 'depth/frames.json') or [] if b.has(d['file'])]
    by_depth = {d['file']: d for d in depth_recs}
    for sub in ('images', 'depth'):
        os.makedirs(os.path.join(out, sub), exist_ok=True)

    # every depth frame once, in model coordinates (for the point cloud and re-projected depth)
    clouds = []
    xyz_all, rgb_all = [], []
    for rec in depth_recs:
        try:
            d, conf = load_depth(b, rec)
        except Exception as e:
            print(f'  skipping {rec["file"]}: {e}')
            continue
        c2w = W2M @ mat(rec['transform'])
        pts, u, v = depth_points(d, conf, K3(rec['intrinsics']), c2w, min_conf=1)
        clouds.append((rec, pts))
        # the starting point cloud: high confidence only, colored from the frame's RGB
        hp, hu, hv = depth_points(d, conf, K3(rec['intrinsics']), c2w, step=2, min_conf=2 if conf is not None else 0)
        if rec.get('rgb') and b.has(rec['rgb']) and len(hp):
            img = np.asarray(Image.open(io.BytesIO(b.read(rec['rgb']))).convert('RGB'))
            ki = K3(rec.get('rgbIntrinsics') or [v * img.shape[1] / rec['width'] for v in rec['intrinsics']])
            pu, pv, _, ok = project(hp, c2w, ki, img.shape[1], img.shape[0])
            xyz_all.append(hp[ok])
            rgb_all.append(img[pv[ok].astype(int), pu[ok].astype(int)])

    tf_frames = []
    clouds_by_rec = {id(rec): c for rec, c in clouds}

    def emit(im, K, transform, pair, source, manual=False, kind='photo'):
        """one training image: save it (EXIF-free, downscaled), its camera, and its LiDAR depth"""
        name = f'{len(tf_frames):04d}'
        fx, fy, cx, cy = K
        s = min(1.0, max_edge / max(im.size))
        if s < 1:
            im = im.resize((round(im.width * s), round(im.height * s)), Image.LANCZOS)
            fx, fy, cx, cy = fx * s, fy * s, cx * s, cy * s
        im.save(os.path.join(out, 'images', name + '.jpg'), quality=95)
        c2w = W2M @ mat(transform)
        frame = {'file_path': f'images/{name}.jpg', 'transform_matrix': c2w.tolist(),
                 'fl_x': fx, 'fl_y': fy, 'cx': cx, 'cy': cy, 'w': im.width, 'h': im.height,
                 'source': source, 'kind': kind, 'manual': manual}
        # depth seen from this camera: re-project the depth frame from the same moment
        cloud = clouds_by_rec.get(id(pair)) if pair is not None else None
        if cloud is not None and len(cloud):
            dw = depth_size
            dh = round(dw * im.height / im.width)
            kd = (fx * dw / im.width, fy * dw / im.width, cx * dw / im.width, cy * dw / im.width)
            u, v, z, ok = project(cloud, c2w, kd, dw, dh)
            dm = zbuffer(u[ok], v[ok], z[ok], dw, dh)
            Image.fromarray(np.clip(dm * 1000, 0, 65535).astype(np.uint16)).save(os.path.join(out, 'depth', name + '.png'))
            frame['depth_file_path'] = f'depth/{name}.png'
        tf_frames.append(frame)

    videos = [v for v in manifest.get('videos') or [] if b.has(v.get('file')) and b.has(v.get('frames'))]
    if frames == 'auto':
        frames = 'video' if videos else 'all'
    if frames == 'video' and not videos:
        sys.exit('this scan has no video (it was made by an older app version): use --frames all')

    # 1. the video: sharp keyframes, evenly spread over where the phone went
    nvideo = 0
    if frames == 'video':
        times = np.array([d['timestamp'] for d in depth_recs]) if depth_recs else np.zeros(0)
        for v in videos:
            recs = b.json(v['frames']) or []
            pick = select_keyframes(recs, max_frames=max_video_frames)
            print(f'  {v["file"]}: {len(recs)} frames, {len(pick)} keyframes '
                  f'(skipped {sum(1 for r in recs if r.get("tracking", "normal") != "normal" or r.get("blurPixels", 0) > MAX_BLUR)} blurry or badly tracked)')
            want = {r['index']: r for r in pick}
            for index, rgb in decode_frames(b, v, sorted(want)):
                r = want[index]
                pair = None
                if len(times):
                    j = int(np.argmin(np.abs(times - r['timestamp'])))
                    if abs(times[j] - r['timestamp']) < 0.25:
                        pair = depth_recs[j]
                emit(Image.fromarray(rgb), K3(r['intrinsics']), r['transform'], pair, f'{v["file"]}#{index}', kind='video')
                nvideo += 1

    # 2. photos: the shutter's full-resolution tour stops always; the automatic ones too when
    # there is no video (with a video they are copies of its frames)
    for p in photos:
        if not b.has(p['file']) or (frames == 'video' and not p.get('manual')):
            continue
        im = Image.open(io.BytesIO(b.read(p['file']))).convert('RGB')  # raw sensor orientation; EXIF dropped on save
        sx = im.width / p['width']
        fx, fy, cx, cy = K3(p['intrinsics'])
        emit(im, (fx * sx, fy * sx, cx * sx, cy * sx), p['transform'], by_depth.get(p.get('depthFrame')), p['file'],
             manual=bool(p.get('manual')))

    # 3. without a video, --frames all adds the 640-wide RGB of depth frames no photo was paired with
    if frames == 'all':
        used = {p.get('depthFrame') for p in photos}
        for d in depth_recs:
            if d['file'] in used or not d.get('rgb') or not b.has(d['rgb']):
                continue
            im = Image.open(io.BytesIO(b.read(d['rgb']))).convert('RGB')
            emit(im, K3(d.get('rgbIntrinsics') or d['intrinsics']), d['transform'], d, d['rgb'], kind='depth')

    if xyz_all:
        xyz, rgb = np.concatenate(xyz_all), np.concatenate(rgb_all).astype(np.float64)
        key = np.floor(xyz / voxel).astype(np.int64)
        _, inv, cnt = np.unique(key, axis=0, return_inverse=True, return_counts=True)
        inv = inv.ravel()
        P = np.zeros((len(cnt), 3)); C = np.zeros((len(cnt), 3))
        np.add.at(P, inv, xyz); np.add.at(C, inv, rgb)
        P /= cnt[:, None]; C /= cnt[:, None]
        if len(P) > max_points:
            keep = np.random.default_rng(0).choice(len(P), max_points, replace=False)
            P, C = P[keep], C[keep]
        write_ply(os.path.join(out, 'points3D.ply'), P.astype(np.float32), np.clip(C, 0, 255).astype(np.uint8))
        npts = len(P)
    else:
        npts = 0

    tf = {'camera_model': 'OPENCV', 'frames': tf_frames, 'depth_unit_scale_factor': 0.001,
          'note': 'transform_matrix is camera-to-world, OpenGL camera axes (as nerfstudio), '
                  'model frame of make_model.py: meters, +Y up, floor at y = 0',
          'world_to_model': W2M.tolist(),
          'property': (manifest.get('property') or {}).get('name') or manifest.get('houseName') or 'Property'}
    if npts:
        tf['ply_file_path'] = 'points3D.ply'
    with open(os.path.join(out, 'transforms.json'), 'w') as f:
        json.dump(tf, f, indent=1)
    nd = sum(1 for f in tf_frames if 'depth_file_path' in f)
    print(f'{out}: {len(tf_frames)} images ({nvideo} from the video), '
          f'{nd} with LiDAR depth, {npts} starting points')
    return tf


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('bundle')
    ap.add_argument('-o', '--out', default='dataset')
    ap.add_argument('--max-edge', type=int, default=1920, help='downscale images to this long edge')
    ap.add_argument('--frames', choices=['auto', 'video', 'all', 'photos'], default='auto',
                    help='video: keyframes of the scan video + shutter photos (default when the scan has a video); '
                         'all: photos + RGB of the other depth frames (scans without video); photos: photos only')
    ap.add_argument('--max-video-frames', type=int, default=600, help='at most this many keyframes per room video')
    ap.add_argument('--voxel', type=float, default=0.02, help='point cloud voxel size in meters')
    a = ap.parse_args()
    export(a.bundle, a.out, a.max_edge, a.frames, a.voxel, max_video_frames=a.max_video_frames)


if __name__ == '__main__':
    main()
