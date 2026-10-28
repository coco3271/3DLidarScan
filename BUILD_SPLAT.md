# Build a photoreal walkthrough (Gaussian splats + generative repair) from a scan zip

Instructions for Claude Code. The user gives you this file and a scan zip exported from the
**3D LiDAR Scan** iPhone app.

**Goal:** a photoreal 3D walkthrough of the property, delivered as one offline file,
`splat.html`. The scene is reconstructed from the photos and LiDAR, then cleaned with
generative AI wherever the capture was thin. The method is in `docs/ECHO_PLAN.md`.

## 0. Where to run it

Training a whole house needs an **NVIDIA GPU**. On a Mac, this pipeline only makes small
previews (the CPU/MPS renderer is slow). Check what you're on first:

```sh
nvidia-smi 2>/dev/null | head -15 || echo "no NVIDIA GPU"; uname -sm
```

- **NVIDIA GPU (Linux, a cloud box, or Colab):** follow steps 1–4.
- **Mac:**
  - Tell the user the full-quality run needs a GPU machine, and give them the steps below to
    paste into a rented GPU box.
  - Recommend an L4 or A10G (24 GB) on RunPod, Lambda or Colab Pro, about $0.5–1/hour.
  - Meanwhile you can still make a quick local preview:
    `make_splat.py ... --quality preview --fixer classic --device mps --downscale 6`.
  - Or offer [Brush](https://github.com/ArthurBrussee/brush), which trains splats on a Mac GPU
    from the `dataset/` folder that step 2 writes. That's stage 1 only, with no generative repair.

## 1. Set up (once per machine)

```sh
cd ~ && { [ -d 3DLidarScan ] || git clone https://github.com/coco3271/3DLidarScan.git; }
cd ~/3DLidarScan && git fetch origin && git checkout claude/modest-gates-iupjvr && git pull
KIT=~/3DLidarScan/ai-kit

python3 -m venv ~/.venvs/splat && source ~/.venvs/splat/bin/activate
pip install -q numpy pillow torch
# ffmpeg reads the scan video; Node.js makes the PlayCanvas files (npx fetches splat-transform)
command -v ffmpeg || sudo apt-get install -y ffmpeg      # macOS: brew install ffmpeg
command -v npx || sudo apt-get install -y nodejs npm     # macOS: brew install node
# CUDA only: the fast renderer and the generative fixer
pip install -q gsplat                     # compiles its CUDA kernels on first use (needs nvcc); prebuilt
                                          # wheels: https://docs.gsplat.studio/whl/ (match torch + CUDA)
git clone https://github.com/nv-tlabs/Difix3D.git ~/Difix3D && pip install -q -r ~/Difix3D/requirements.txt
export DIFIX_REPO=~/Difix3D
```

If `gsplat` won't build, training still runs on the GPU with the reference renderer, just
slower. Say so and use `--quality preview`. If Difix won't install, fall back to an API fixer
(step 3).

## 2. Run the pipeline

```sh
source ~/.venvs/splat/bin/activate
python3 "$KIT/splat/make_splat.py" "<scan.zip>" -o "<work folder>" --fixer difix --quality standard --eval
```

This runs four steps:
1. `export_dataset.py`: picks sharp keyframes from each room's **video** (using the per-frame
   poses), with LiDAR depth from the same moments and the point cloud, written to
   `<work>/dataset`. It prints how many frames it skipped as blurry or badly tracked. If most of
   a room was skipped, tell the user to rescan it more slowly. Scans from older app versions
   (photos, no video) work too.
2. `train.py`: reconstruction, then 3 generative repair rounds, written to `<work>/scene`.
3. `playcanvas.py`: the PlayCanvas files, `scene.sog` (compact) and `playcanvas.html`
   (PlayCanvas's viewer, with room annotations and a walkthrough tour).
4. `make_splat_html.py`: writes `<work>/splat.html`.

Watch the output:
- The held-out PSNR printed at the end should be **above ~22 dB** on a real house. Below
  that, check the capture: blurry photos, or too few of them.
- `<work>/scene/previews/gen-*.jpg` show each repair, with the render on the left and the
  fixed image on the right. Look at a few. If the fixer invents things (furniture that isn't
  there, changed wall colors), rerun with `--gen-weight 0.3` or with fewer rounds
  (`--gen-rounds 2`).

## 3. Without a local Difix

| Fixer | Needs | Notes |
|---|---|---|
| `--fixer fal` | `export FAL_KEY=...` | FLUX.1 Fill [pro]; fills only the unreliable areas |
| `--fixer openai` | `export OPENAI_API_KEY=...` | gpt-image-1 edits with a mask |
| `--fixer none` | — | Plain reconstruction, the "without world knowledge" baseline |

Each API repair is one paid image request: about `--gen-rounds × --gen-views` = 72 images
with the defaults. Ask the user before spending on an API.

## 4. Check, and deliver

```sh
open "<work folder>/splat.html"        # or copy it to the user's machine
```

- Dollhouse: the ceiling is cut away and the rooms are visible.
- Walk: it stays inside the rooms, without fog in front of the walls.
- Photos: each view matches its photo. Drag the Compare slider to check.

Give the user `splat.html` and `playcanvas.html`. Each is one offline file that opens in any
browser, phones included. To clean up or edit the scene, they can drop `<work>/scene/scene.sog`
(or `scene.ply`) into SuperSplat (https://superspl.at/editor), PlayCanvas's free editor, and
publish from there. Tell them:
- what was reconstructed from their photos
- what was repaired by generative AI (the `previews/gen-*.jpg` show which views)
- that `<work>/scene/scene.ply` is the standard 3DGS file for other viewers (SuperSplat,
  Polycam, game engines)
