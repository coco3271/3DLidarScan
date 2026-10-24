# 3D LiDAR Scan: property walkthroughs from your iPhone

Scan a house or apartment room by room with your iPhone's LiDAR. At each spot you want in
the tour, take a high-quality photo; it's saved with its exact position, GPS and compass
heading. Apple's RoomPlan API models the walls, doors, windows and furniture as you go.
When you're done, export **one zip**. Attach it to Claude or ChatGPT with the prompt the app
gives you, and it recreates an interactive 3D walkthrough. The zip also already contains a
walkthrough you can open in any browser.

The export uses the `house-capture/5` bundle format and the `scan-to-threejs` workflow from
[wesbos/3d-model-anything](https://github.com/wesbos/3d-model-anything). Its scripts and
agent skill read these scans unchanged, and a copy of them ships inside every zip.

```
iPhone app ──► Scan.zip ──► Claude / ChatGPT (+ PROMPT)  ──► walkthrough.html, refined three.js model
                  │
                  └──────► web/index.html or the included walkthrough.html (any device, Android too)
```

## What's in the repo

| Path | What it is |
|---|---|
| `ios/` | The iPhone/iPad app (SwiftUI, RoomPlan, ARKit, CoreLocation) |
| `ai-kit/` | Ships inside the app and is copied into every zip as `_ai/`: `START_HERE.md` (instructions for the AI), `PROMPT.txt`, `make_walkthrough.py`, the walkthrough viewer, and the vendored `scan-to-threejs` skill and scripts |
| `web/index.html` | Web viewer: open a scan zip in any browser (phone or desktop, Android included). Nothing is uploaded |
| `tests/` | End-to-end test without a phone: builds a synthetic scan, runs every script, and renders the walkthrough in headless Chromium |

## Why iPhone (and not Android or a web app) for scanning

LiDAR depth and Apple's RoomPlan are only available to **native iOS apps** on devices with a
LiDAR scanner: iPhone 12 Pro and later Pro models, and iPad Pro (2020+), on iOS 17 or newer.
Browsers can't reach the LiDAR sensor, and Android phones have no LiDAR or RoomPlan. So
capture is iPhone-only, but **viewing** works everywhere through the web viewer or the
self-contained `walkthrough.html`.

## Install the app on your iPhone

You need a Mac with Xcode 16 or newer, and a free Apple ID is enough for your own phone.

```sh
brew install xcodegen
cd ios && xcodegen                 # creates LidarWalkthrough.xcodeproj
open LidarWalkthrough.xcodeproj
```

In Xcode, select the **LidarWalkthrough** target, then **Signing & Capabilities**, and pick
your team. If the bundle ID is taken, change it to something unique. Plug in your iPhone,
choose it as the run destination and press **Run**. The first time, on the phone, go to
Settings › General › VPN & Device Management and trust your developer certificate.

## Scanning a property

1. Tap **+** and enter the address or a name. GPS and the street address are added automatically.
2. Name the first room and walk slowly along the walls. Apple's RoomPlan draws the room
   live. The app also records the LiDAR mesh, depth frames and automatic reference photos.
3. The app takes reference photos by itself as you move: one every ~0.4 m or ~17° turn,
   only when you're steady enough for a sharp shot, and full-resolution when the phone allows.
   At every spot you want as a tour stop, stand still and tap the **shutter** for a
   full-resolution photo. Every photo is saved with where the phone was (X/Y/Z), which way
   it pointed, the LiDAR depth from that moment, GPS and compass heading.
4. Tap **Done with room**, then **Scan next room**. Walk there **without closing the app**,
   so every room lands in the same coordinate system and the floor plan lines up.
5. Tap **Finish property**. With two or more rooms, RoomPlan merges them into one floor plan.

While scanning, a live mini-map shows where you are and which way you're facing (green),
the path you walked, and a cone for every photo. A shutter photo also saves the LiDAR depth
frame from the same moment, so each photo has its own position (X/Y/Z), direction and
depth.

On the scan's page you can **Walk through in 3D** on the phone, open the **Photo map** (floor plan with every photo's position and direction; tap one to see its X/Y/Z), view **Apple's RoomPlan
model** (USDZ in Quick Look), or **Export ZIP for Claude / ChatGPT**, which opens the share
sheet (AirDrop, Files, Mail…). Scans are also visible in the **Files** app under
On My iPhone › 3D LiDAR Scan.

## Recreating the walkthrough with Claude or ChatGPT

1. Export the zip and attach it to a new chat. Use a model and plan with code execution
   and file uploads.
2. Tap **Copy AI prompt** in the app and paste it. The text is in `ai-kit/PROMPT.txt`.
3. The AI reads `START_HERE.md` inside the zip. It first runs
   `python3 _ai/make_walkthrough.py .`, which returns a working walkthrough immediately. It
   then follows the scan-to-threejs workflow to build a cleaner measured model with matched
   materials, a dollhouse view, first-person walking and a photo tour, and reports room
   sizes and floor area.

Chat upload limits vary, often a few hundred MB. A big house with many rooms can exceed
them; in that case, export fewer rooms per scan.

You can also skip the AI and open the zip's `walkthrough.html` directly, or the web viewer:
serve this repo (or enable GitHub Pages on it) and open `web/index.html`, then pick the zip.

```sh
python3 -m http.server 8000      # then http://localhost:8000/web/
```

## What's in an exported zip

```
<Property 2026-10-23 15.00.00>/
  START_HERE.md            instructions for the AI (start here)
  walkthrough.html         ready-made offline walkthrough
  manifest.json            format house-capture/5, rooms, property name/address/GPS
  structure.json|usdz      all rooms merged by RoomPlan (2+ rooms)
  rooms/room-N.json|usdz   RoomPlan CapturedRoom per room (+ -mesh.usdz, -data.json)
  mesh/room-N.ply          LiDAR mesh, classified faces (wall/floor/ceiling/door/…)
  photos/photos.json       pose, intrinsics, GPS, heading, high-res flag for every photo
  photos/NNNN.jpg          photos (EXIF GPS; manual shots are full resolution)
  poses.csv                every photo + depth frame: x,y,z (m), direction, yaw/pitch, paired LiDAR frame, GPS
  depth/frames.json        LiDAR depth frames with poses
  depth/NNNNN.f16z|conf|jpg
  _ai/                     make_walkthrough.py, viewer, scan-to-threejs skill + scripts
```

Coordinates are meters, +Y up, right-handed (ARKit world = three.js). Matrices are
column-major. Indoor GPS is approximate: it tags the property and photos and is never used
for measuring.

## Development

```sh
tests/run.sh      # needs python3 + numpy + Pillow, node; downloads playwright-core into tests/

# Swift logic tests in the iOS Simulator (macOS), using the synthetic scan:
python3 tests/make_fake_bundle.py tests/out/FakeHouse
cd ios && xcodegen && cd ..
TEST_RUNNER_FIXTURE_BUNDLE=$PWD/tests/out/FakeHouse TEST_RUNNER_AI_KIT=$PWD/ai-kit TEST_RUNNER_OUT_DIR=$PWD/tests/out \
  xcodebuild test -project ios/LidarWalkthrough.xcodeproj -scheme LidarWalkthroughTests -destination 'platform=iOS Simulator,name=iPhone 16'
```

`tests/make_fake_bundle.py` ray-traces a two-room house into a bundle in the same format
(RoomPlan JSON, PLY, Float16 DEFLATE depth, posed JPEGs), and `tests/make_variants.py`
derives edge cases from it: one room, no mesh, no depth, no photos, ASCII PLY, raw depth,
and a zip with no folder. `tests/run.sh` runs:
- the vendored scan-to-threejs scripts,
- `make_walkthrough.py`,
- the kit's unit tests (`tests/test_kit.py`),
- `tests/e2e.mjs`, which loads every variant in headless Chromium and drives the real UI,
- `tests/compare_poses.py`, which renders the scan from every photo's camera and checks
  pixel by pixel that it reproduces that photo.

CI (`.github/workflows/ci.yml`) also compiles the app, runs the Swift tests in the iOS
Simulator, and opens the walkthrough built by the app's own Swift code in a browser.

`ai-kit/walkthrough/three.bundle.min.js` is three.js r180 bundled into one ES module so the
walkthrough works offline, including inside the single HTML file:

```sh
npm i three@0.180.0 esbuild && echo "export * from 'three'" > entry.js && \
  npx esbuild entry.js --bundle --minify --format=esm --outfile=ai-kit/walkthrough/three.bundle.min.js
```

## Credits

- Bundle format, `scan-to-threejs` skill and scripts:
  [wesbos/3d-model-anything](https://github.com/wesbos/3d-model-anything) (MIT); see
  `ai-kit/scan-to-threejs/LICENSE` and `VENDORED.md`.
- [three.js](https://threejs.org) (MIT) and [JSZip](https://stuk.github.io/jszip/) (MIT/GPLv3).
