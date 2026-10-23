# Modeling reference

How the shared runtime and room modules are organized, the conventions it relies
on, and the mistakes that cost time the first time around. Read the section you need.

## Contents
1. Room coordinates
2. Walls as data (`WallDef`)
3. Profile sweeps (moldings, casings, crown, tray ceilings)
4. Wall-mounted things (`onWall`)
5. Furniture recipes
6. Materials and textures
7. Lighting and rendering
8. Viewer: cutaway, walk, overlay
9. Pitfalls

## 1. Room coordinates

Floor at y = 0, room centered on x/z, meters, +y up; −z is whatever wall you call "north".
The scan is moved into this frame with `SCAN_OFFSET` in `dimensions.ts` (negated center and
floor height from `measure_scan.mjs`). If the wall azimuth isn't ~0°, rotate the scan by the
negative angle (`rotY`) so walls run along the X and Z axes; everything downstream assumes that.

## 2. Walls as data

`shell.ts` holds one `WallDef` per wall: `origin` (interior face, left end, at the floor),
`u` (along the wall, left → right *as seen from inside the room*), `n` (normal into the room),
`length`, `thickness`, `openings`, `panels`, `baseboardGaps`. Keep `u × up = n`. For an
axis-aligned room:

| wall  | origin        | u   | n   | u coordinate |
|-------|---------------|-----|-----|--------------|
| north | (−W/2, 0, −D/2) | +x | +z | x + W/2 |
| east  | (+W/2, 0, −D/2) | +z | −x | z + D/2 |
| south | (+W/2, 0, +D/2) | −x | −z | W/2 − x |
| west  | (−W/2, 0, +D/2) | −z | +x | D/2 − z |

Measure in world coordinates from the elevations, then convert to u with this table. Openings:
- `rect` with `v0 = 0` (doorways, fireboxes) becomes a **notch in the outline**. Holes that touch
  the shape's edge break triangulation.
- `rect` above the floor and `arch` (semicircular head, radius = half width, `spring` = where the
  arc starts) become holes.
- `casing: true` adds door casing and a baseboard gap automatically.

The slab is an `ExtrudeGeometry` with material array `[wall, trim]`. Group 1 (sides) covers the
jambs/reveals, so openings get trim-colored returns for free. Extend the slab 0.3 m past both ends
so corners overlap.

Crown and baseboard are straight runs per wall that overlap in the corners. Two inside-corner
extrusions that cross read as a proper miter, and it keeps each wall's trim in that wall's group.

## 3. Profile sweeps

`sweep(profile, path, planeNormal, { closed, caps })` extrudes a 2D profile along a polyline
with mitered corners. Profile points are `[s, t]`: **s** = offset to the *left* of travel
(`planeNormal × direction`), **t** = offset along `planeNormal`. So:

- **Panel molding on a wall**: path = rectangle BL → BR → TR → TL in wall coordinates, plane
  normal = `n`. The left side is inward, so the profile grows into the panel.
- **Casing**: path up the left jamb, across the head, down the right jamb; the left side is away
  from the opening.
- **Crown / baseboard**: path along the wall toward −u with plane normal = up, so the left side is
  into the room. Crown `t` is negative (hangs down from the ceiling).
- **Tray ceiling**: closed rectangle at the perimeter-ceiling height, ordered so the left side
  points to the tray center, with the profile rising to the tray height.
- Repeat a profile point to make a hard edge (split normals). Use a DoubleSide trim material:
  sweep winding isn't guaranteed and DoubleSide shades back faces correctly.
- A **cove** (hollow curve) has its arc center *away* from the corner, at (r, −r) for a crown
  profile. With the center at the corner you get a quarter-round bulge instead.

## 4. Wall-mounted things

`onWall(obj, wall, u, v, out)` orients an object so local +x runs along the wall, +y is up and
+z points into the room. Build fixtures (TV, sconces, mirror, painting, fireplace surround) in
that local frame and add them to the wall's group, so dollhouse cutaway hides them with the wall.
`frame(width, height, profile)` sweeps a picture/mirror frame around a rectangle.

## 5. Furniture recipes

- **Upholstery**: `cushion(size, center, radius)` (RoundedBoxGeometry + box UVs in meters).
  Sectionals = base + arms + seat cushions with 6 mm gaps + back cushions tilted ~0.12 rad.
- **Pillows**: `pillow([w, h, thickness])`, an ellipsoid mapped onto a square with pinched
  sides. Lean against backs: rotation.x ≈ −0.3, and face the camera's likely view, since an
  edge-on pillow reads as a sheet.
- **Throws/blankets**: a PlaneGeometry laid along a CatmullRom curve that follows the cushion
  surfaces (seat → cushion front → top → behind), plus a few low-frequency sine folds.
- **Turned things** (bowls, lamp shades, stools, pedestals): `lathe([[r, y], …])`.
- **Bent things** (sconce arms, chair frames): `tube(points, radius)`.
- **Organic tops** (live-edge tables): CylinderGeometry with radius wobble from summed sines.
- **Clutter** (toy piles, books): seeded `mulberry32` scatter of primitives in a region, denser
  toward the corner. Don't hand-place 60 objects.
- Place free-standing pieces by footprint from the top view: `place(group, [x, 0, z], rotY)`,
  where rotY turns local +z (the front) to face where the piece faces (`atan2(dx, dz)`).

## 6. Materials and textures

- The scan's colors are darker than the real albedo because the capture lighting is baked in.
  Sample with `ortho.py sample`, then brighten about 1.3–1.4× and nudge toward the photo.
- Fabrics, carpet and leather: CC0 normal + roughness maps with a *neutralized* grayscale color
  map (`fetch_textures.py get … :neutral`), tinted by `material.color`. Wood/stone keep their
  color maps. Patterns (plaid, stripes, paintings, rugs) are canvas textures drawn in code.
- UVs: `boxUV(geometry)` projects in meters, so a `repeat` of 3 means 3 tiles per meter on
  every object regardless of size.
- **Preload** every texture before creating materials (`loadTextures()`). Cloning textures whose
  image hasn't loaded spams "Texture marked for update but no image data found".

## 7. Lighting and rendering

- Put lights where the real fixtures are: SpotLights under pot lights (~25 cd, 55°, penumbra 0.9),
  PointLights inside lamp shades and sconces, low HemisphereLight fill. Make shades emissive.
- `bakeEnvironment()`: after the room is built, capture a CubeCamera at room center → PMREM →
  `scene.environment` (warm bounce light from the room itself), plus a second capture at the
  mirror for its envMap. It works far better than a generic studio environment.
- Nothing moves, so render shadows once: `shadowMap.autoUpdate = false; needsUpdate = true`.
  Two shadowed spots plus one shadowed point light is plenty. Use `PCFShadowMap`
  (`PCFSoftShadowMap` was removed in recent three.js).
- `render.ts`: EffectComposer → RenderPass → GTAOPass (radius ~0.35) → OutputPass, with AgX tone mapping.
- Scan materials: `MeshBasicMaterial({ map, toneMapped: false })`. The texture already is the
  final photographed color, and Polycam GLBs have no normals.

## 8. Viewer

- **Dollhouse cutaway**: every frame, hide a wall group when
  `dot(camera − wallMidpoint, n) < 0` (the camera is behind it), and hide the ceiling group when
  the camera is above the wall top. Neighboring rooms use single-sided inward planes, so they cut
  away on their own.
- **Walk**: PointerLockControls, eye height 1.6 m, clamp to the room bounds. Treat `unlock` and
  `pointerlockerror` as "back to dollhouse".
- **Rebuilt / Scan / Overlay**: load the scan lazily; overlay = scan at 45% opacity,
  `depthWrite: false`. Overlay is the quickest honest check of alignment.

## 9. Pitfalls

- `gltf-transform optimize` **simplifies by default**. Pass `--simplify false` for scans.
- Poly Haven returns 403 to Python's urllib; use curl.
- Vite serves an HTML error page for a module with a broken import. The capture page then never
  sets `data-ready`, and the screenshot waits forever: check the console.
- agent-browser key names are plain (`keyboard down s`), not `KeyS`.
- Floors straddle histogram bins; use the area-weighted mean (the script does).
- Asset names lie: look at a contact sheet (`fetch_textures.py sheet`).
- Neighbor rooms need a saddle/threshold inside the wall thickness, or you see a black strip in
  every doorway.
- **Outside corners** (L-shaped rooms): extending a slab past its end pokes into the room. Use
  per-end `ext` (0 where the probe point just past the end is inside the floor polygon), and paint
  slab end caps with the wall material (`paintSlabEnds`), or they show as white trim columns.
- Don't create materials at module import time (e.g. inside a top-level `WALLS = ...map()`): the
  texture preload hasn't happened yet and `tex()` throws. Assign materials inside `build()`.
- Furniture attached to a wall (built-ins, shelving with a back panel) must go in that wall's group,
  or its back shows as a phantom wall when the cutaway hides the real one.
- Soffits/bulkheads from RoomPlan: walls under a soffit report the lower height. Model the soffit
  as boxes following those walls (depth from photos, ~0.45 m typical), stepping with wall jogs.
