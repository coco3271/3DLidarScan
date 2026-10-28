# START HERE: instructions for the AI rebuilding this property walkthrough

This zip is a **3D LiDAR property scan** from an iPhone (LiDAR + Apple RoomPlan + photos +
GPS). It uses the `house-capture/5` bundle format of
[wesbos/3d-model-anything](https://github.com/wesbos/3d-model-anything), so that project's
`scan-to-threejs` workflow applies. A copy of the skill and its scripts is in
`_ai/scan-to-threejs/` (MIT, see its LICENSE).

**Goal:** give the user a photoreal Gaussian-splat walkthrough rebuilt from the scan video
(step 2b) when you have an NVIDIA GPU. Otherwise give them a clean, measured 3D model of the property that they can open in a
browser: the "architectural dollhouse" look (thick cut-away walls, framed doors and windows,
real floor materials, furniture in its place, soft shadows, on a dark blueprint grid), with
first-person walking between rooms and a tour of the photo spots. Be accurate to the
measurements, and be honest about what is measured and what is guessed.

Don't hand over the raw LiDAR mesh as the result: it is noisy and lumpy. Don't model the
house from scratch either: boxy guessed furniture under flat light looks like a toy. The kit
already has a renderer for the clean look (step 3). Your job is to describe the house
accurately in its `model.json`.

## 1. Unpack and orient yourself

The bundle root is the folder that contains `manifest.json`. The folder name may contain
spaces, so quote paths.

| File | What it is |
|---|---|
| `manifest.json` | `format`, `rooms[]` (name, counts, files), `structure`, `mesh`, `property` (name, street address, GPS) |
| `structure.json` | All rooms merged by Apple's RoomPlan `StructureBuilder`, present when 2 or more rooms were scanned |
| `rooms/room-N.json` | One room as RoomPlan's `CapturedRoom` JSON: `walls`, `doors`, `windows`, `openings`, `objects`, `floors` |
| `rooms/room-N.usdz` | Apple's parametric model of the room |
| `mesh/room-N.ply` | LiDAR triangle mesh (the last room's file has the whole session). Faces carry the ARKit class: 0 none, 1 wall, 2 floor, 3 ceiling, 4 table, 5 seat, 6 window, 7 door. The per-vertex `coverage` value says how well the photos show that spot: 0 means no photo saw it (so model it from the mesh and RoomPlan alone), and 1 or more means well photographed. The red/amber/green vertex colors show the same thing. |
| `photos/photos.json` + `photos/NNNN.jpg` | Posed photos. `manual: true` marks the high-resolution shots the user took at each spot (the tour stops). Each has `location` (lat/lon, accuracy in m, compass `heading`) |
| `depth/frames.json` + `depth/NNNNN.{f16z,conf,jpg}` | LiDAR depth frames: 256×192 Float16 meters stored as raw DEFLATE (`zlib.decompress(raw, -15)`), confidence 0–2, and 640×480 RGB, each with its pose |
| `walkthrough.html` | A ready-made walkthrough built on the phone (see step 2) |
| `video/room-N.mov` + `video/room-N.json` | **The scan video of each room** (HEVC or H.264, sensor orientation: landscape, the orientation the intrinsics describe; don't apply rotation). The `.json` has one entry per video frame, in order: `time` in the video, ARKit `timestamp` (pairs it with depth frames), camera-to-world `transform`, `intrinsics` for the video's pixels, `tracking`, and `blurPixels` (predicted motion smear; skip frames above ~6). This is what the photoreal Gaussian-splat walkthrough trains on (step 2b). |
| `poses.csv` | One row per photo and depth frame: **where the phone was** (`x,y,z` in meters), **which way it pointed** (`dir_x,dir_y,dir_z`, `yaw_deg`, `pitch_deg`), and the paired photo ↔ LiDAR file, plus GPS |

Conventions that matter:

- All geometry and poses share one coordinate system: the ARKit world of the session.
  Units are meters, **+Y is up**, and the system is right-handed, the same as three.js.
  The floor is **not** at y=0: get it from `floors[].transform` or from the bottoms of the walls.
- Matrices are **column-major** 4×4 (translation is the last 4 numbers). In three.js,
  `new Matrix4().fromArray(t)` reads them directly.
- RoomPlan elements: `transform` is the element's **center**, and `dimensions` is
  `[width, height, depth]` (depth is 0 for walls, doors and windows). A door, window or
  opening belongs to the wall whose `identifier` equals its `parentIdentifier`.
- **Every photo has its LiDAR frame.** `photos.json` entries have `depthFrame`
  (`depth/NNNNN.f16z`), the depth captured at the same moment from the same spot, and that
  depth frame's `photo` points back. `pose` gives the camera's `position` [x,y,z] (m),
  `direction` (unit view vector), `yaw` (degrees, counter-clockwise seen from above,
  0 = facing world −Z) and `pitch`. These are the same numbers as `transform`, unpacked.
  Use them to place each photo on the floor plan and to render the model from exactly
  where the photo was taken.
- Photo `transform` is camera-to-world, and the camera looks down **−Z**.
  `intrinsics = [fx,0,0, 0,fy,0, cx,cy,1]` describe the raw **landscape** sensor pixels.
  Project with those and ignore EXIF orientation. To view a photo upright, apply its EXIF
  orientation (`ImageOps.exif_transpose` in Pillow). The app scans with the phone held
  **sideways** (landscape: orientation 1, or 3 when upside down); older scans were held upright
  (portrait: orientation 6). The same rule follows from the pose: the sensor axis (`transform`
  column 0 = x or column 1 = y) that points most upward in the world is the image's up.
- GPS indoors is approximate (see `horizontalAccuracy`, often 5–30 m). Use it to place
  the property on a map and to label photos, never to measure.

## 2. Fast path: a working walkthrough in one command

```sh
python3 _ai/make_walkthrough.py . -o walkthrough.html     # run inside the bundle folder (or pass the .zip)
```

This uses only the standard library, and Pillow is optional. It writes one self-contained,
offline HTML file. That file shows the LiDAR mesh colored from the photos (with occlusion
tests against the depth frames), Apple's RoomPlan walls, doors, windows and furniture, the
photo spots, and Dollhouse, Walk (WASD or an on-screen joystick) and Photo tour modes.
Give the user this file first, as the quick result while you build the clean model in
step 3. It works on phones and desktops, needs no server and has no dependencies. If the zip already has `walkthrough.html` from the phone, you can
hand that over as-is, or regenerate it.

## 2b. The photoreal walkthrough: Gaussian splats from the video

Gaussian splats rebuild the room from the scan video itself, so it looks like the video:
every texture, reflection and object. They are more faithful than any modeled scene, and the
best result when the user wants it to look real.

```sh
python3 _ai/splat/make_splat.py . -o splat-work --fixer difix   # → splat-work/splat.html + playcanvas.html
```

The pipeline:
1. Picks sharp keyframes from the video using the per-frame poses, skipping blurry frames.
2. Pairs each keyframe with LiDAR depth from the same moment.
3. Trains the splats, then repairs thin areas with generative AI.
4. Writes `splat.html`: dollhouse with the ceiling cut away, walk, and photo compare.
5. Writes the PlayCanvas files: `scene.sog`, and `playcanvas.html` with room annotations and a
   walkthrough tour.

Requirements:
- **An NVIDIA GPU** for a whole house, roughly 20–40 minutes.
- **Python:** `pip install numpy pillow torch gsplat`, plus the Difix3D repo for `--fixer difix`.
- **ffmpeg** to read the video.
- **Node.js** for the PlayCanvas files.

Full instructions are in `BUILD_SPLAT.md` in the app's repository. If you're in a chat
sandbox without a GPU, don't try to train a whole house on the CPU. Build the clean model
(step 3) and tell the user the photoreal version needs a GPU machine.

## 3. The clean model: `make_model.py`, then refine `model.json`

```sh
python3 _ai/make_model.py . -o house-model    # inside the bundle folder (or pass the .zip); needs numpy + Pillow for colors
```

It writes `house-model/` with:

- `model.json`: the whole house as data: rooms (floor polygons), walls (with door, window and
  opening cut-outs), furniture, materials, and the photo cameras. Units are meters, +Y up,
  the floor at y = 0, and the walls run along X/Z.
- `textures/floor-N.jpg`: a square of each room's real floor, cut out of the sharpest photo
  that shows it with nothing in the way, and flattened so it tiles.
- `photos/`: the tour photos, for the compare view.
- `model.html`: one offline file to give the user. It has a dollhouse view where the walls
  between the camera and the rooms are cut away, Walk (drag + WASD), and Photos (the exact
  camera of each photo, with a Compare slider that blends the photo over the model).

It does this from the measurements alone. Walls, openings and furniture boxes are from
RoomPlan. The two faces of a wall shared by two rooms become one wall, as thick as the gap
between them, and corners are joined. Wall paint, floor colors and furniture colors are
sampled from the photos. Every color sample is checked against that photo's LiDAR depth, so
a sofa standing in front of a wall never paints the wall.

**Then make it look like the photos.** Look at the photos (`photos/` in the model folder,
and `photos/*.jpg` in the bundle; rotate them upright). Edit `model.json` and rebuild with
`python3 _ai/make_model.py house-model`, which keeps your edits. Things to fix, roughly in
order of how much they matter:

1. **Furniture types and shapes.** RoomPlan only says `storage`, `table`, `chair` and
   similar. Change each item's `type` to what it really is, keeping its measured `center`,
   `size` and `rotY` (its front faces +z). Built-in types are: `bed sofa chair table desk
   storage shelf television refrigerator stove oven dishwasher washerDryer sink toilet
   bathtub fireplace stairs rug plant lamp curtain wallArt box custom`. Set `color` (and
   `colors: {blanket, pillow, wood, legs, front, counter, pot, frame, railing}` where it
   applies) from the photos.
2. **What RoomPlan doesn't detect**, from the photos: rugs, plants, lamps, curtains, wall art,
   shelves of books, counters, a kitchen island. Add items for them, with sizes estimated
   against the measured walls and furniture.
3. **Anything unusual:** build it as `type: "custom"` with `parts`, a list of
   `{shape: box|rbox|cyl|sphere|cone, size: [w,h,d], pos: [x,y,z], rot: [rx,ry,rz], color, roughness, metalness}`
   in the item's own frame (y = 0 is the floor, front is +z).
4. **Materials.** `materials` maps names to `{color, map, tile, roughness}`. A room's `floor`
   names one, or is a `"#hex"`. If a generated floor swatch looks wrong (a rug, a shadow),
   replace the texture or set a plain color. `style.wallColor` is the house paint; set `color`
   on a single wall for an accent wall or tiles.
5. **Geometry** only where the scan is clearly wrong: a missed door (add an opening with `u0,u1`
   along the wall from `a` and `v0,v1` above the floor), a door that should be shown open
   (`open: true`), or a wall RoomPlan missed.

**Check against the photos, and iterate.** `model.html#photo=N&ui=0` renders the model from
photo N's exact camera, with the same position, orientation and field of view. Use a 3:4
window, which matches the upright photo. `&overlay=0.5` blends the photo on top, and
`&quality=0` turns off ambient occlusion for faster headless renders. With a headless browser
(Playwright), screenshot each photo's view next to the photo. Fix the biggest mismatch, rebuild,
and repeat. Keep going past "close enough": shapes, colors, and the small objects that make a
room look lived in.

`model.json` reference (everything is optional except the geometry):

```js
{ name, subtitle,
  style:  { background, grid, wallColor, wallThickness, baseboard },
  rooms:  [{ name, polygon: [[x,z]...], floor: "<material>"|"#hex", height?, label? }],
  walls:  [{ a:[x,z], b:[x,z], height, thickness?, color?, centered?,
             openings: [{ kind: "door"|"window"|"opening", u0, u1, v0, v1, open? }] }],
  items:  [{ type, center:[x,y,z], size:[w,h,d], rotY, color?, colors?, parts?, label? }],
  materials: { name: { color?, map?: "textures/x.jpg", tile?: meters, roughness? } },
  photos: [{ file, transform (column-major 4x4, model frame), width, height, fx }] }
```

`a → b` is the wall's interior face, with the room to its left seen from above (`n` points
into the room). A `centered` wall straddles `a → b`, between two rooms. `source.worldToModel`
converts ARKit world coordinates (meshes, depth frames, `poses.csv`) into the model frame.

## 4. Going further: your own three.js build (scan-to-threejs workflow)

Only for something `model.json` can't express. Follow
`_ai/scan-to-threejs/SKILL.md` and `references/house-capture.md`:

```sh
S=_ai/scan-to-threejs/scripts
python3 $S/bundle_plan.py . -o plan.png                       # walls, openings, furniture, photo spots + per-wall photo coverage
python3 $S/bundle_to_room.py . -o house.json --plan plan.png  # all rooms (uses structure.json); --room N for one room
python3 $S/prepare_photos.py . house.json photos-upright      # upright photos in the same order as house.json "photos"
# optional, needs numpy+open3d: colored GLB rebuilt from the depth frames
python3 $S/reconstruct_bundle.py . --room house.json -o recon
```

Measure first, model the furniture from the RoomPlan boxes and the photos, then render from
each photo's camera and iterate, as above. You can reuse the renderer:
`_ai/model/house.js` exports `startModel(THREE, element, source)`, and
`_ai/walkthrough/viewer.js` exports `startWalkthrough(THREE, element, source)`. Deliver a
single self-contained HTML file.

## 5. What to tell the user

- Which file to open (`model.html` from step 3, plus `walkthrough.html` from step 2 if they
  want the raw scan), and the controls: drag to orbit or look, WASD to walk, and Photos to
  step through the photo spots.
- What is measured (RoomPlan walls, openings, room sizes; LiDAR mesh) and what is modeled
  or approximate (furniture detail, materials, areas the scan didn't see).
- Room sizes and the total floor area from the measurements, if they'd find that useful.
