#!/usr/bin/env python3
"""Check that the walkthrough's photo camera reproduces each photo: the render from photo N's
pose (pose-N.png, made by e2e.mjs) must look like photo N, and clearly more like it than
like any other photo. This catches wrong axes, a missing upright rotation, a wrong field of
view or a mirrored image, any of which would make "render from where the photo was taken"
useless for the scan-to-threejs comparison loop.

usage: compare_poses.py <out-dir> <bundle-dir>
"""
import json
import os
import sys

import numpy as np
from PIL import Image


def upright(path, size):
    # sensor-orientation JPEG → upright (EXIF orientation 6 = rotate 90° clockwise), as prepare_photos.py
    with Image.open(path) as im:
        return np.asarray(im.convert('RGB').transpose(Image.Transpose.ROTATE_270).resize(size), dtype=np.float32)


def main():
    out, bundle = sys.argv[1], sys.argv[2]
    files = json.load(open(os.path.join(out, 'pose-index.json')))
    renders = [np.asarray(Image.open(os.path.join(out, f'pose-{i}.png')).convert('RGB'), dtype=np.float32) for i in range(len(files))]
    h, w = renders[0].shape[:2]
    photos = [upright(os.path.join(bundle, f), (w, h)) for f in files]
    # ignore pixels the scan never colored (class-grey: r≈g≈b) and the background
    diff = np.zeros((len(files), len(files)))
    for i, r in enumerate(renders):
        mask = (np.abs(r[..., 0] - r[..., 1]) + np.abs(r[..., 1] - r[..., 2])) > 12
        for j, p in enumerate(photos):
            diff[i, j] = np.abs(r - p)[mask].mean() if mask.any() else 255
    failed = 0
    for i in range(len(files)):
        own = diff[i, i]
        others = np.delete(diff[i], i)
        ok = own < 30 and own < 0.6 * others.min()
        failed += not ok
        print(f"  {'ok ' if ok else 'FAIL'} {files[i]}: mean |render − photo| = {own:5.1f}  (closest other photo {others.min():5.1f})")
    if failed:
        sys.exit(f'{failed} photo camera(s) do not reproduce their photo')
    print('photo cameras reproduce their photos')


if __name__ == '__main__':
    main()
