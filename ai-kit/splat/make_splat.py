#!/usr/bin/env python3
"""One command from a scan zip to a photoreal, generatively cleaned walkthrough (splat.html).

usage: make_splat.py <scan.zip | bundle folder> [-o splat-work] [--fixer difix|fal|openai|classic|none]
                     [--quality preview|standard|high] [--device auto|cuda|mps|cpu]

  1. export_dataset.py   scan → images, cameras, LiDAR depth, starting point cloud
  2. train.py            reconstruction, then generative repair rounds (--fixer)
  3. playcanvas.py       PlayCanvas outputs: scene.sog (compact), playcanvas.html (PlayCanvas's own
                         viewer with room annotations and a walkthrough tour); needs Node.js
  4. make_splat_html.py  → splat-work/splat.html (our viewer: dollhouse, walk, photo compare)

Quality presets (on an NVIDIA GPU with gsplat; CPU/Mac use the slow reference renderer):
  preview    7k steps, images at 1/4 size     ~5 min GPU   (CPU: hours for a real house)
  standard  30k steps, images at 1/2 size     ~25 min GPU
  high      30k steps, full-size images       ~45 min GPU, 24 GB VRAM recommended
"""
import argparse
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PRESETS = {'preview': (7000, 4), 'standard': (30000, 2), 'high': (30000, 1)}


def run(args):
    print('$ ' + ' '.join(args), flush=True)
    subprocess.run([sys.executable] + args, check=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('bundle')
    ap.add_argument('-o', '--out', default='splat-work')
    ap.add_argument('--fixer', default='difix', choices=['none', 'classic', 'difix', 'fal', 'openai'])
    ap.add_argument('--quality', default='standard', choices=list(PRESETS))
    ap.add_argument('--steps', type=int, default=None, help='override the preset')
    ap.add_argument('--downscale', type=float, default=None, help='override the preset')
    ap.add_argument('--device', default='auto')
    ap.add_argument('--eval', action='store_true', help='hold out photos and report PSNR')
    ap.add_argument('--no-playcanvas', action='store_true', help="skip scene.sog / playcanvas.html (they need Node.js)")
    a, extra = ap.parse_known_args()
    steps, down = PRESETS[a.quality]
    steps, down = a.steps or steps, a.downscale or down
    ds, out = os.path.join(a.out, 'dataset'), os.path.join(a.out, 'scene')
    run([os.path.join(HERE, 'export_dataset.py'), a.bundle, '-o', ds])
    run([os.path.join(HERE, 'train.py'), ds, '-o', out, '--steps', str(steps), '--downscale', str(down),
         '--fixer', a.fixer, '--device', a.device] + (['--eval'] if a.eval else []) + extra)
    if not a.no_playcanvas:
        sys.path.insert(0, HERE)
        import playcanvas
        if playcanvas.make(out, a.bundle) and os.path.exists(os.path.join(out, 'playcanvas.html')):
            shutil.copy(os.path.join(out, 'playcanvas.html'), os.path.join(a.out, 'playcanvas.html'))
    run([os.path.join(HERE, 'make_splat_html.py'), out, '--dataset', ds, '-o', os.path.join(a.out, 'splat.html')])
    print(f'\nopen {os.path.join(a.out, "splat.html")}' + (f'  (or {os.path.join(a.out, "playcanvas.html")})'
                                                          if os.path.exists(os.path.join(a.out, 'playcanvas.html')) else ''))


if __name__ == '__main__':
    main()
