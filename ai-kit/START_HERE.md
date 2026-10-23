# START HERE: instructions for the AI rebuilding this property walkthrough

This zip is a **3D LiDAR property scan** from an iPhone (LiDAR + Apple RoomPlan + photos +
GPS). It uses the `house-capture/5` bundle format of
[wesbos/3d-model-anything](https://github.com/wesbos/3d-model-anything), so that project's
`scan-to-threejs` workflow applies. A copy of the skill and its scripts is in
`_ai/scan-to-threejs/` (MIT, see its LICENSE).

**Goal:** give the user an interactive 3D walkthrough of the property that they can open in a
browser. It needs a dollhouse overview, first-person walking between rooms, and a tour of
the photo spots. Be accurate to the measurements, and be honest about what is measured and
what is guessed.

## 1. Unpack and orient yourself

The bundle root is the folder that contains `manifest.json`. The folder name may contain
spaces, so quote paths.

| File | What it is |
|---|---|
| `manifest.json` | `format`, `rooms[]` (name, counts, files), `structure`, `mesh`, `property` (name, street address, GPS) |
| `structure.json` | All rooms merged by Apple's RoomPlan `StructureBuilder`, present when 2 or more rooms were scanned |
| `rooms/room-N.json` | One room as RoomPlan's `CapturedRoom` JSON: `walls`, `doors`, `windows`, `openings`, `objects`, `floors` |
| `rooms/room-N.usdz` | Apple's parametric model of the room |
| `mesh/room-N.ply` | LiDAR triangle mesh (the last room's file has the whole session). Faces carry the ARKit class: 0 none, 1 wall, 2 floor, 3 ceiling, 4 table, 5 seat, 6 window, 7 door |
| `photos/photos.json` + `photos/NNNN.jpg` | Posed photos. `manual: true` marks the high-resolution shots the user took at each spot (the tour stops). Each has `location` (lat/lon, accuracy in m, compass `heading`) |
| `depth/frames.json` + `depth/NNNNN.{f16z,conf,jpg}` | LiDAR depth frames: 256×192 Float16 meters stored as raw DEFLATE (`zlib.decompress(raw, -15)`), confidence 0–2, and 640×480 RGB, each with its pose |
| `walkthrough.html` | A ready-made walkthrough built on the phone (see step 2) |

Conventions that matter:

- All geometry and poses share one coordinate system: the ARKit world of the session.
  Units are meters, **+Y is up**, and the system is right-handed, the same as three.js.
  The floor is **not** at y=0: get it from `floors[].transform` or from the bottoms of the walls.
- Matrices are **column-major** 4×4 (translation is the last 4 numbers). In three.js,
  `new Matrix4().fromArray(t)` reads them directly.
- RoomPlan elements: `transform` is the element's **center**, and `dimensions` is
  `[width, height, depth]` (depth is 0 for walls, doors and windows). A door, window or
  opening belongs to the wall whose `identifier` equals its `parentIdentifier`.
- Photo `transform` is camera-to-world, and the camera looks down **−Z**.
  `intrinsics = [fx,0,0, 0,fy,0, cx,cy,1]` describe the raw **landscape** sensor pixels.
  Project with those and ignore EXIF orientation. To view a photo upright, rotate it 90°
  clockwise (EXIF orientation 6).
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
**Always give the user this file first.** It works on phones and desktops, needs no server
and has no dependencies. If the zip already has `walkthrough.html` from the phone, you can
hand that over as-is, or regenerate it.

## 3. Full rebuild: a clean, editable three.js model (scan-to-threejs workflow)

When the user wants a polished model and not the raw scan, follow
`_ai/scan-to-threejs/SKILL.md` and `references/house-capture.md`. In short:

```sh
S=_ai/scan-to-threejs/scripts
python3 $S/bundle_plan.py . -o plan.png                       # walls, openings, furniture, photo spots + per-wall photo coverage
python3 $S/bundle_to_room.py . -o house.json --plan plan.png  # all rooms (uses structure.json); --room N for one room
python3 $S/prepare_photos.py . house.json photos-upright      # upright photos in the same order as house.json "photos"
# optional, needs numpy+open3d: colored GLB rebuilt from the depth frames
python3 $S/reconstruct_bundle.py . --room house.json -o recon
```

`bundle_to_room.py` writes measured room coordinates: the floor at y=0, walls aligned to X/Z,
inward normals, openings in wall u/v, furniture boxes (`center`, `size`, `rotY`), and photo
cameras (`position`, `forward`, `up`, `fovY`). Then:

1. **Measure first.** Build the floor polygon, walls (with their real heights), door and
   window cut-outs, and ceilings from those numbers. Don't invent dimensions. Where
   something is uncertain, say so.
2. **Model the furniture** from the RoomPlan boxes (treat them as bounds, not shapes) and
   from the photos (shape, material, color). Look at the photos. Make materials and colors
   match what's visible: floors, wall paint, cabinets, counters, fixtures.
3. **Compare with the photos.** Render the model from each tour photo's camera pose
   (position, forward, up, fovY) and put it next to the photo. Fix the biggest mismatch,
   then repeat.
4. **Deliver** a single self-contained HTML file. Inline three.js (or use one pinned CDN URL).
   Include dollhouse and first-person controls with touch support, clickable photo spots
   that fly the camera to the photo pose and show the photo, and room labels from
   `manifest.rooms[].name`. Also give the property name and address from `manifest.property`.
   You can reuse `_ai/walkthrough/viewer.js`: it exports `startWalkthrough(THREE, element, source)`.

## 4. What to tell the user

- Which file to open, and the controls: drag to look, WASD or the joystick to walk, and
  tap a pink dot for a photo stop.
- What is measured (RoomPlan walls, openings, room sizes; LiDAR mesh) and what is modeled
  or approximate (furniture detail, materials, areas the scan didn't see).
- Room sizes and the total floor area from the measurements, if they'd find that useful.
