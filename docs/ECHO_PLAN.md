# Plan: an Echo-3-style photoreal walkthrough from an iPhone scan

## What Echo-3 does, and what we copy

The SpAItial Echo-3 video shows a phone capture (video, plus the camera pose of every frame)
turned into a **photoreal, spatially consistent 3D world**. The key idea is in the comparison
shots: "models without world knowledge" (plain reconstruction) show holes, smears and floaters
wherever the camera didn't look closely. Echo-3 fills and cleans those parts with what a
generative model knows about real rooms. **Reconstruction is treated as generation,
conditioned on the capture.**

Echo-3's own model isn't public. Its open-source equivalent is two published pieces:

| Piece | Open-source method | Role |
|---|---|---|
| Photoreal reconstruction | **3D Gaussian Splatting** (Kerbl et al. 2023), with [gsplat](https://github.com/nerfstudio-project/gsplat) | Turns posed photos into a real-time, photoreal 3D scene |
| "World knowledge" repair | **Difix3D+** (Wu et al., NVIDIA, CVPR 2025) | A single-step diffusion model fixes renders from new viewpoints. The fixed renders are trained back into the splat, so the 3D scene itself gets cleaner. At view time it can also polish the frames. |

Our capture is already stronger than plain video: we have **LiDAR depth for every photo**, so
walls are flat and correctly scaled, with no floaters in front of them. We also have **exact
ARKit poses**, so there's no need for COLMAP, which fails on blank walls, and **RoomPlan
geometry** to tell what is a wall, a floor, a door. The generative model therefore only has to
hallucinate the genuinely unseen parts, not guess the geometry.

## Architecture

```
iPhone app (exists)                     processing (new: ai-kit/splat/)                         viewing
─────────────────────                   ──────────────────────────────────────                  ───────────────
1920×1440 keyframes ─┐                  1 export_dataset.py                                     splat.html
LiDAR depth + conf  ─┼─ Scan.zip ──►       images, cameras (model frame), depth PNGs,  ──┐       (Spark, three.js)
ARKit pose / intr.  ─┤                     LiDAR point cloud → nerfstudio layout          │       Dollhouse / Walk /
RoomPlan rooms      ─┘                  2 train.py                                        │       Photos + compare
                                           stage 1: 3DGS + depth loss + per-photo color  ─┤
                                           stage 2: render new views → fixer → retrain    │       model.html (exists)
                                                    (progressively farther, 3 rounds)     │       clean dollhouse
                                        3 make_splat_html.py → one offline file  ◄────────┘
```

The fixers (`fixers.py`) all share one interface: `fix(render, unreliable_mask, reference_photo)`.

- **difix:** NVIDIA Difix-ref. Runs locally on a CUDA GPU, ~8 GB VRAM. It repairs the whole frame,
  floaters included, guided by the nearest real photo. This is the Echo-3 equivalent.
- **fal:** FLUX.1 Fill [pro]. **openai:** gpt-image-1 edits. Both are hosted APIs that fill only the
  masked holes; nothing measured is touched.
- **classic:** a no-AI push-pull fill, used for tests and offline previews.

## Phases

### Phase 1: done in this commit

- [x] `export_dataset.py`: scan → nerfstudio dataset.
  - EXIF-free sensor-orientation images, per-frame intrinsics, and camera-to-world in the
    `make_model.py` frame.
  - LiDAR depth re-projected into each photo's camera.
  - A 2 cm-voxel colored LiDAR point cloud.
  - Also works with nerfstudio splatfacto, Brush and OpenSplat.
- [x] `gaussians.py`: splat model, SH colors up to degree 3, and two renderers. One is gsplat
  (CUDA). The other is a pure-PyTorch reference rasterizer (CPU/MPS), checked with `gradcheck`.
  Also densification (clone/split/prune), and `.ply` / `.splat` export and import.
- [x] `train.py`.
  - **Stage 1:** L1 + SSIM, LiDAR depth loss, an opacity regularizer, a per-photo color
    correction for iPhone auto-exposure, and held-out PSNR.
  - **Stage 2:** progressive generative rounds. Each round makes new viewpoints (step back,
    turn, or stand between two photo spots), skips ones inside walls or outside the house,
    and builds a reliability mask from alpha. It then calls the fixer and trains on the
    repairs at lower weight.
- [x] `fixers.py`: difix / fal / openai / classic.
- [x] `viewer/viewer.js` + `spark.bundle.min.js` (three.js r180 + Spark 2.3.1).
  - Dollhouse: the ceiling and wall tops are cut away by filtering splats by height.
  - Walk: WASD or touch buttons.
  - Photos: exact photo cameras with a compare slider.
- [x] `make_splat_html.py` (one offline HTML file) and `make_splat.py` (one command for the
  whole pipeline).
- [x] Tests on the synthetic house, CPU-only, run in CI.
  - The exported depth matches the ray-traced scene.
  - Renderer gradients and axis conventions are correct.
  - Training reaches >22 dB on held-out photos.
  - Generative rounds run, exports round-trip, and the browser checks pass.

### Phase 2: first real-house results (needs an NVIDIA GPU, ~1 day)

1. Run `make_splat.py --fixer difix --quality standard` on a real scan on a rented GPU
   (RunPod, Lambda, Colab Pro: an L4 or A10G is enough). `BUILD_SPLAT.md` has the steps.
2. Tune on real data:
   - the densify threshold
   - depth-loss weight versus LiDAR noise near glass and mirrors (mask confidence 0)
   - the generative-round count, reach and weight
   - the novel-view generator: follow the RoomPlan floor polygon for walk paths, so new views
     are always inside rooms at eye height
3. Compare with and without `--fixer` on held-out photos and on the walk path. This is the
   left/right comparison from the video, and it should become a regression metric.

### Phase 3: quality closer to Echo-3

- **Geometry-aware generation.**
  - Render the clean `model.json` (`house.js`) from the same new viewpoint and pass it to the
    fixer as a structural guide. Walls, doors and floors stay where RoomPlan measured them,
    even where no photo looked.
  - Use RoomPlan's floor and ceiling planes to fill gaps in a large flat surface before any
    diffusion runs.
- **Real-time polish.** Difix at view time, a post-pass on rendered frames as in Difix3D+,
  for a desktop "ultra" mode streamed from a server.
- **Anti-aliasing and size.**
  - Mip-Splatting filter or gsplat `antialiased` mode.
  - `.spz` export (about 10× smaller than `.splat`) so a whole house fits in a phone download.
- **Exposure.** Use the per-photo color correction to also export a neutral version, and add
  bilateral-grid appearance from gsplat for strong lighting changes.

### Phase 4: product

- **In the app:**
  - Upload the zip to a processing endpoint: a GPU worker running `make_splat.py`, with a
    queue and progress.
  - Get a link back, and show `splat.html` in a WKWebView.
  - The scan screen's red/green coverage map doubles as guidance for splat quality.
- **Any iPhone (no LiDAR).**
  - ARKit world tracking works on every iPhone, so add a "Video scan" mode that records
    keyframes and poses without RoomPlan.
  - Replace LiDAR depth with a monocular metric-depth model on the server, or a feed-forward
    multi-view model (DUSt3R/MASt3R/VGGT family) for both depth and pose refinement.
  - The generative stage matters more there.
- **Sharing.** Host `splat.html` with a public, read-only link like a listing page, and embed
  it in real-estate listings.

## Costs (rough, unverified until Phase 2)

| Step | Where | Time per house (3–6 rooms) | Cost |
|---|---|---|---|
| Stage 1 reconstruction, 30k steps | L4 / A10G GPU | ~20–40 min | ~$0.30–1.00 |
| Stage 2 Difix rounds (~72 views) | same GPU | a few minutes | included |
| Stage 2 via the FLUX Fill API instead | fal.ai | — | ~72 × the per-image price |
| Viewing | user's browser | real time | free (static file) |

## Risks

- **Hallucinated content.** For real estate, invented furniture or fixtures would be
  misleading. The defaults keep measured geometry fixed, train repairs at low weight, and let
  repairs change only unreliable pixels; Difix is conditioned on the real reference photo.
  The viewer should label the generative mode, and the plain reconstruction stays available
  (`--fixer none`).
- **Mirrors, glass, TVs.** LiDAR returns garbage on these, so mask them by confidence and by
  RoomPlan window boxes.
- **Licensing.** Check before shipping commercially:
  - Difix weights: NVIDIA license.
  - FLUX Fill [pro]: API terms.
  - gsplat (Apache-2.0) and Spark (MIT) are fine.

## Sources

- Echo / Echo-2 announcements ([moguravr](https://www.moguravr.com/?p=286215),
  [all-ai.de](https://www.all-ai.de/news/news26/echo2-spaitial-3d)) and the Echo-3 video.
  spaitial.ai itself was not reachable from the build environment.
- Difix3D+: [arXiv 2503.01774](https://arxiv.org/abs/2503.01774),
  [CVPR 2025 oral](https://cvpr.thecvf.com/virtual/2025/oral/35364).
- gsplat: https://github.com/nerfstudio-project/gsplat ·
  Spark (World Labs): https://sparkjs.dev
