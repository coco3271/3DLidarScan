#!/usr/bin/env python3
"""Check that the walkthrough's photo camera reproduces each photo: the render from photo N's
pose (pose-N.png, made by e2e.mjs) must look like photo N, and clearly more like it than
like any other photo. This catches wrong axes, a missing upright rotation, a wrong field of
view or a mirrored image, any of which would make "render from where the photo was taken"
useless for the scan-to-threejs comparison loop.

usage: compare_poses.py <out-dir> <bundle-dir> [prefix]   (prefix model- checks make_model.py's renders)
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageOps


def upright(path, size):
    # sensor-orientation JPEG → upright by its EXIF orientation (6 for portrait, 1 or 3 for landscape)
    with Image.open(path) as im:
        return np.asarray(ImageOps.exif_transpose(im).convert('RGB').resize(size), dtype=np.float32)


def main():
    out, bundle = sys.argv[1], sys.argv[2]
    prefix = sys.argv[3] if len(sys.argv) > 3 else ''
    files = json.load(open(os.path.join(out, f'{prefix}pose-index.json')))
    renders = [np.asarray(Image.open(os.path.join(out, f'{prefix}pose-{i}.png')).convert('RGB'), dtype=np.float32) for i in range(len(files))]
    h, w = renders[0].shape[:2]
    photos = [upright(os.path.join(bundle, f), (w, h)) for f in files]
    # ignore pixels the scan never colored (class-grey: r≈g≈b) and the background
    colorful = lambda a: (np.abs(a[..., 0] - a[..., 1]) + np.abs(a[..., 1] - a[..., 2])) > 12
    # the clean model has one flat color per surface, not the photos' lighting: compare hue only
    # (chromaticity), and allow ties between photos of the same plain wall
    model = 'model' in prefix
    chroma = lambda a: a / np.maximum(a.sum(-1, keepdims=True), 1) * 255
    diff = np.zeros((len(files), len(files)))
    for i, r in enumerate(renders):
        mask = colorful(r)
        for j, p in enumerate(photos):
            m = mask & colorful(p) if model else mask
            d = np.abs(chroma(r) - chroma(p)) if model else np.abs(r - p)
            diff[i, j] = d[m].mean() if m.any() else 255
    failed = 0
    for i in range(len(files)):
        own = diff[i, i]
        others = np.delete(diff[i], i)
        ok = own < 15 and own <= others.min() + 1 if model else own < 30 and own < 0.6 * others.min()
        failed += not ok
        print(f"  {'ok ' if ok else 'FAIL'} {files[i]}: mean |render − photo| = {own:5.1f}  (closest other photo {others.min():5.1f})")
    if failed:
        sys.exit(f'{failed} photo camera(s) do not reproduce their photo')
    print('photo cameras reproduce their photos')


if __name__ == '__main__':
    main()
