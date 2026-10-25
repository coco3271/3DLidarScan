# Build a clean 3D model from a LiDAR scan zip

Instructions for Claude Code, running on the user's Mac. The user drops this file into a
Claude Code session together with a scan zip exported from the **3D LiDAR Scan** iPhone app.

**Goal:** turn the scan into a clean, measured 3D model of the property in the
"architectural dollhouse" style, and hand the user one offline file, `model.html`. That style
means thick walls cut away toward the camera, framed doors and windows, real floor materials,
furniture in its measured place and color, soft shadows, all on a dark blueprint grid. The
model must also look like the user's photos when seen from where each photo was taken.

Don't hand over the raw LiDAR mesh as the result, and don't write a three.js scene from
scratch. The repo has a generator and a renderer for this look. Your job is to run the
generator, then refine the model's `model.json` until it matches the photos.

---

## 0. Inputs

- **The scan zip.** If the user didn't give a path, look for recent zips in `~/Downloads`
  and `~/Desktop` that contain a `manifest.json` with `"format": "house-capture/5"`:
  ```sh
  for z in ~/Downloads/*.zip ~/Desktop/*.zip; do unzip -l "$z" 2>/dev/null | grep -q manifest.json && echo "$z"; done
  ```
  If there are several, ask the user which one. Paths often contain spaces, so always quote them.
- Make a working folder next to the zip, for example `~/Desktop/<property name> model/`.

## 1. Set up the tools (once)

```sh
# the kit: generator, renderer and scripts
cd ~ && { [ -d 3DLidarScan ] || git clone https://github.com/coco3271/3DLidarScan.git; }
cd ~/3DLidarScan && git fetch origin && git checkout claude/modest-gates-iupjvr && git pull
KIT=~/3DLidarScan/ai-kit

# Python packages for colors and floor textures (a venv keeps the system Python clean)
python3 -m venv ~/.venvs/lidar && source ~/.venvs/lidar/bin/activate && pip install -q numpy pillow

# a headless browser to render the model from each photo's camera
mkdir -p ~/.lidar-render && cd ~/.lidar-render && [ -d node_modules/playwright ] || \
  (npm init -y >/dev/null && npm i -s playwright && npx playwright install chromium)
```

Use the kit from the repo (`$KIT`), not the `_ai/` folder inside the zip. Zips made by older
app builds don't have `make_model.py`. If `node`/`npm` are missing, install them with
`brew install node`. Ask the user first if Homebrew isn't installed either.

## 2. Build the model

```sh
source ~/.venvs/lidar/bin/activate
cd "<working folder>"
python3 "$KIT/make_walkthrough.py" "<scan.zip>" -o walkthrough.html   # quick preview of the raw scan
python3 "$KIT/make_model.py" "<scan.zip>" -o house-model             # the clean model
open house-model/model.html
```

`make_model.py` prints how many photos it used for colors, how many floor textures it cut and
how many furniture items it colored. If it says `no RoomPlan rooms`, the user didn't tap
**Save room** while scanning. Tell them, and stop.

Tell the user `model.html` is open, and that you'll keep refining it. Then continue.

The output folder `house-model/` contains:

| File | What it is |
|---|---|
| `model.json` | The whole house as data. Edit this file. |
| `textures/floor-N.jpg` | A floor swatch for each room, cut from the photos |
| `photos/` | The tour photos. They are stored in sensor orientation; `ImageOps.exif_transpose` rotates them upright. |
| `model.html` | The deliverable: one offline file with everything embedded |

To rebuild after editing `model.json` (your edits are kept):
```sh
python3 "$KIT/make_model.py" house-model
```

## 3. Look at the photos

Read `$KIT/START_HERE.md` (section 3) for details. To view the photos upright:

```sh
mkdir -p review/photos && python3 - <<'EOF'
import json, os
from PIL import Image, ImageOps
spec = json.load(open('house-model/model.json'))
for i, p in enumerate(spec['photos']):
    im = ImageOps.exif_transpose(Image.open(os.path.join('house-model', p['file']))).convert('RGB')
    im.thumbnail((900, 900)); im.save(f'review/photos/photo-{i:02d}.jpg', quality=85)
print(len(spec['photos']), 'photos → review/photos/')
EOF
```

Then look at each image in `review/photos/`, room by room. For each room, note:
- every piece of furniture: its type, its color, and what it's made of
- the floor material, the wall paint, and any accent wall or tiles
- what RoomPlan doesn't detect: rugs, plants, lamps, curtains, wall art, books, counters,
  a kitchen island, mirrors

## 4. Refine `model.json`

Units are meters, +Y is up, the floor is at y = 0, and the walls run along X/Z.

```js
{ name, subtitle,
  style:  { background, grid, wallColor, wallThickness, baseboard },
  rooms:  [{ name, polygon: [[x,z]...], floor: "<material>"|"#hex", height?, label? }],
  walls:  [{ a:[x,z], b:[x,z], height, thickness?, color?, centered?,
             openings: [{ kind: "door"|"window"|"opening", u0, u1, v0, v1, open? }] }],
  items:  [{ type, center:[x,y,z], size:[w,h,d], rotY, color?, colors?, parts?, label? }],
  materials: { name: { color?, map?: "textures/x.jpg", tile?: meters, roughness? } },
  photos: [ ...camera of each photo... ]  // generated; don't edit
}
```

- **Items:** `center` is the middle of the item's box, and `size` is `[width, height, depth]`
  in the item's own frame. `rotY` turns the item's front (+z) around the vertical axis.
- **Walls:** `a → b` is the wall's interior face, with the room on the left as seen from
  above. `u0` and `u1` are measured along the wall from `a`; `v0` and `v1` are heights above
  the floor. A `centered` wall sits between two rooms.

Work in this order, from what changes the look most to least:

1. **Furniture types and colors.** RoomPlan only knows generic categories (`storage`,
   `table`, `chair`…). Change each item's `type` to what it really is, and keep its measured
   `center`, `size` and `rotY`. The built-in types are:
   `bed sofa chair table desk storage shelf television refrigerator stove oven dishwasher
   washerDryer sink toilet bathtub fireplace stairs rug plant lamp curtain wallArt box custom`.
   Set `color` from the photos. Some types also take `colors: { blanket, pillow, wood, legs,
   front, counter, pot, frame, railing }`.
2. **Add what RoomPlan missed.** Add items for the rugs, plants, lamps, curtains, wall art and
   other decor you saw in the photos. Estimate their sizes against the measured walls and
   furniture. Wall art and curtains hang on a wall: set `center[1]` to their real height.
3. **Unusual objects.** Use `type: "custom"` with `parts`:
   `[{ shape: "box"|"rbox"|"cyl"|"sphere"|"cone", size:[w,h,d], pos:[x,y,z], rot:[rx,ry,rz], color, roughness, metalness }]`.
   Parts are placed in the item's own frame, with y = 0 at the floor and the front at +z.
4. **Materials.** Fix any floor swatch that caught a rug or a shadow: replace the image, or
   use a plain `color`. Set `style.wallColor` to the house paint, and give a wall its own
   `color` for an accent wall or tiles.
5. **Geometry, only where the scan is clearly wrong.** For example: add a missed door or
   opening, set `open: true` on a door that stands open, or add a wall RoomPlan missed.
   Never move or resize measured walls to make something "look nicer".

## 5. Compare with the photos, and iterate

Render the model from each photo's exact camera and put each render next to its photo:

```sh
cat > ~/.lidar-render/render.mjs <<'EOF'
// usage: node render.mjs <house-model dir> <out dir>
import { chromium } from 'playwright'
import { mkdirSync, readFileSync } from 'node:fs'
import path from 'node:path'
const [dir, out] = process.argv.slice(2).map((p) => path.resolve(p))
mkdirSync(out, { recursive: true })
const n = JSON.parse(readFileSync(path.join(dir, 'model.json'), 'utf8')).photos.length
const browser = await chromium.launch()
const page = await browser.newPage({ viewport: { width: 600, height: 800 } }) // 3:4 = the upright photo
page.on('pageerror', (e) => console.log('PAGE ERROR', e.message))
await page.goto('file://' + path.join(dir, 'model.html') + '#ui=0')
await page.waitForFunction(() => window.walkthrough, null, { timeout: 60000 })
for (let i = 0; i < n; i++) {
  await page.evaluate((i) => window.walkthrough.goToPhoto(i), i)
  await page.waitForTimeout(400)
  await page.screenshot({ path: path.join(out, `render-${String(i).padStart(2, '0')}.png`) })
}
await page.setViewportSize({ width: 1400, height: 900 })
await page.evaluate(() => window.walkthrough.setMode('dollhouse')); await page.waitForTimeout(800)
await page.screenshot({ path: path.join(out, 'dollhouse.png') })
await browser.close()
console.log(`${n} renders + dollhouse.png → ${out}`)
EOF

(cd ~/.lidar-render && node render.mjs "<working folder>/house-model" "<working folder>/review/renders")

python3 - <<'EOF'
import glob
from PIL import Image
for r in sorted(glob.glob('review/renders/render-*.png')):
    i = r[-6:-4]
    a = Image.open(r).convert('RGB'); b = Image.open(f'review/photos/photo-{i}.jpg').convert('RGB').resize(a.size)
    s = Image.new('RGB', (a.width * 2 + 10, a.height), 'white'); s.paste(a, (0, 0)); s.paste(b, (a.width + 10, 0))
    s.save(f'review/compare-{i}.jpg', quality=85)
print('side-by-sides → review/compare-NN.jpg (model left, photo right)')
EOF
```

Look at every `review/compare-NN.jpg` and at `review/renders/dollhouse.png`. Then:

1. Find the biggest mismatch. That might be a wrong furniture type or color, a missing
   object, a wrong floor or wall color, or an object facing the wrong way (`rotY`).
2. Fix it in `model.json`, rebuild, and render again.
3. Repeat. Keep going past "close enough": furniture shapes, colors, and the small objects
   that make a room look lived in. Stop when every comparison agrees and the dollhouse looks
   clean.

If a render shows `PAGE ERROR`, or the model fails to load, check `model.json` for a typo,
then rebuild. A view where the model and the photo don't line up at all is almost always a
photo taken while tracking was poor. Skip that photo; don't move the geometry to match it.

## 6. Deliver

- Give the user `house-model/model.html`, the full path in the working folder. It is one
  offline file: double-click to open it, or AirDrop it to an iPhone. Mention that
  `walkthrough.html` (the raw scan) is also there.
- Explain the controls:
  - **Dollhouse:** drag to orbit, scroll or pinch to zoom.
  - **Walk:** drag to look, WASD or the ▲▼ buttons to move.
  - **Photos:** steps through where each photo was taken, and the Compare slider blends in
    the photo.
- Give each room's size and the total floor area: the room labels and the subtitle in
  `model.json` show them, so read them there.
- Say what is measured and what is modeled. Walls, doors, windows, room sizes and furniture
  boxes are measured by RoomPlan. Colors and floor textures are sampled from the photos.
  Furniture shapes and the decor you added are modeled from the photos.
- List anything uncertain, for example areas no photo covered, or a room whose floor texture
  you replaced with a plain color.
