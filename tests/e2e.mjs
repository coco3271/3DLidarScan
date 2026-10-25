// End-to-end checks of the walkthrough in headless Chromium:
//   1. the single-file walkthrough and web/index.html (zip opened in the browser) load without errors
//      and the LiDAR mesh gets colored from the photos
//   2. every edge-case variant (tests/make_variants.py) loads without errors
//   3. the real UI works: mode buttons, keyboard walking, drag-to-look, mini-map taps, photo tour
//      next/prev, the compare overlay, layer toggles
//   4. for every tour photo, a render from that photo's camera (#photo=N&ui=0&layers=mesh) is saved
//      as pose-N.png with pose-index.json; tests/compare_poses.py checks they match the photos
//   5. the clean model (make_model.py): builds, cuts away near walls, walk/photo modes, renders
//      from each photo camera (model-pose-N.png, checked by compare_poses.py too)
//
// usage: node tests/e2e.mjs <out-dir>   (expects the files tests/run.sh creates there)
import { chromium } from 'playwright-core'
import { existsSync, readdirSync, writeFileSync } from 'node:fs'
import { readFile } from 'node:fs/promises'
import http from 'node:http'
import path from 'node:path'

const out = path.resolve(process.argv[2] || 'tests/out')
const repo = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..')
const failures = []
const check = (ok, what) => { console.log(`${ok ? '  ok ' : '  FAIL'} ${what}`); if (!ok) failures.push(what) }

function chromiumPath() {
  if (process.env.CHROMIUM_PATH) return process.env.CHROMIUM_PATH
  const base = process.env.PLAYWRIGHT_BROWSERS_PATH || '/opt/pw-browsers'
  if (!existsSync(base)) return undefined // playwright-core's own download (npx playwright-core install chromium)
  for (const dir of readdirSync(base).filter((d) => d.startsWith('chromium-')).sort().reverse()) {
    for (const sub of ['chrome-linux/chrome', 'chrome-linux64/chrome', 'chrome-mac/Chromium.app/Contents/MacOS/Chromium']) {
      const p = path.join(base, dir, sub)
      if (existsSync(p)) return p
    }
  }
  return undefined
}

const browser = await chromium.launch({
  executablePath: chromiumPath(),
  args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'],
})

/** Open a page, wait until the walkthrough is ready (mesh coloring done) and collect errors */
async function open(url, viewport = { width: 1280, height: 800 }) {
  const page = await browser.newPage({ viewport })
  const errors = []
  page.on('pageerror', (e) => errors.push(String(e)))
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()) })
  await page.goto(url)
  await page.waitForFunction(() => window.walkthrough || document.getElementById('err')?.textContent || document.querySelector('#msg.err'),
    null, { timeout: 120000 })
  await page.waitForTimeout(300)
  return { page, errors }
}

const coloredFraction = (page) => page.evaluate(() => {
  let n = 0, total = 0
  window.walkthrough.scene.traverse((o) => {
    const c = o.isMesh && o.geometry.getAttribute('color')
    if (!c) return
    for (let i = 0; i < c.count; i++) {
      total++
      if (Math.abs(c.getX(i) - c.getY(i)) > 0.05 || Math.abs(c.getY(i) - c.getZ(i)) > 0.05) n++
    }
  })
  return total ? n / total : null
})

const cam = (page) => page.evaluate(() => {
  const c = window.walkthrough.camera
  return { x: c.position.x, y: c.position.y, z: c.position.z, qx: c.quaternion.x, qy: c.quaternion.y, qz: c.quaternion.z, qw: c.quaternion.w, fov: c.fov }
})

// ---- 0. extra files to load-check (e.g. the walkthrough built by the iOS app's Swift code) ---------
for (const file of (process.env.EXTRA_HTML || '').split(':').filter(Boolean)) {
  console.log(path.basename(file))
  const { page, errors } = await open('file://' + path.resolve(file))
  const ready = await page.evaluate(() => !!window.walkthrough)
  const f = ready ? await coloredFraction(page) : 0
  check(ready && errors.length === 0, `${path.basename(file)}: loads without errors ${errors.join(' | ')}`)
  check(f > 0.5, `${path.basename(file)}: mesh photo-colored (${Math.round(f * 100)}%)`)
  if (ready) {
    await page.evaluate(() => window.walkthrough.goToPhoto(0)); await page.waitForTimeout(1100)
    await page.screenshot({ path: path.join(out, path.basename(file, '.html') + '.png') })
  }
  await page.close()
}
if (process.env.EXTRA_ONLY) {
  await browser.close()
  console.log(failures.length ? `\n${failures.length} FAILED:\n- ${failures.join('\n- ')}` : '\nall browser checks passed')
  process.exit(failures.length ? 1 : 0)
}

// ---- 1. full walkthrough: single file + web app ------------------------------------------------
console.log('single-file walkthrough')
{
  const { page, errors } = await open('file://' + path.join(out, 'walkthrough.html'))
  const f = await coloredFraction(page)
  check(f > 0.5, `mesh photo-colored (${Math.round(f * 100)}%)`)
  await page.screenshot({ path: path.join(out, 'dollhouse.png') })

  // ---- 3. UI interactions ----
  await page.click('.wt-modes button[data-mode=walk]')
  check(await page.evaluate(() => window.walkthrough.mode) === 'walk', 'Walk button switches to walk mode')
  await page.waitForTimeout(200) // let a walk-mode frame render before measuring
  const a = await cam(page)
  await page.keyboard.down('KeyW'); await page.waitForTimeout(700); await page.keyboard.up('KeyW')
  const b = await cam(page)
  check(Math.hypot(b.x - a.x, b.z - a.z) > 0.4 && Math.hypot(b.x - a.x, b.z - a.z) < 1.5, `W key walks forward (${Math.hypot(b.x - a.x, b.z - a.z).toFixed(2)} m)`)
  await page.mouse.move(640, 400); await page.mouse.down(); await page.mouse.move(760, 430, { steps: 6 }); await page.mouse.up()
  const c = await cam(page)
  check(Math.abs(c.qy - b.qy) + Math.abs(c.qx - b.qx) > 0.02, 'dragging turns the view')
  await page.screenshot({ path: path.join(out, 'walk.png') })

  const box = await page.locator('.wt-map').boundingBox()
  await page.mouse.click(box.x + box.width * 0.3, box.y + box.height * 0.5)
  await page.waitForTimeout(150)
  const d = await cam(page)
  check(await page.evaluate(() => window.walkthrough.mode) !== 'dollhouse' && Math.hypot(d.x - c.x, d.z - c.z) > 0.2,
    'tapping the mini-map moves you there')

  await page.click('.wt-modes button[data-mode=tour]')
  await page.waitForTimeout(1100)
  check(await page.evaluate(() => window.walkthrough.mode) === 'tour' && await page.isVisible('.wt-photo'), 'Photo tour opens the photo panel')
  const i0 = await page.evaluate(() => window.walkthrough.tourIndex)
  await page.click('.wt-photo [data-act=next]'); await page.waitForTimeout(1100)
  check(await page.evaluate(() => window.walkthrough.tourIndex) === i0 + 1, 'Next goes to the next photo')
  const t = await page.evaluate(() => {
    const p = window.walkthrough.tour[window.walkthrough.tourIndex], c = window.walkthrough.camera
    return { d: Math.hypot(c.position.x - p.transform[12], c.position.y - p.transform[13], c.position.z - p.transform[14]),
             fov: c.fov, want: 2 * Math.atan(p.width / 2 / p.intrinsics[0]) * 180 / Math.PI }
  })
  check(t.d < 1e-3 && Math.abs(t.fov - t.want) < 0.01, `tour camera sits exactly at the photo (Δ ${t.d.toExponential(1)} m, fov ${t.fov.toFixed(1)}°)`)
  check(/X -?\d+\.\d\d · Y -?\d+\.\d\d · Z -?\d+\.\d\d m · facing \d+°/.test(await page.textContent('.wt-photo .meta')),
    'photo panel shows X/Y/Z and facing')
  await page.click('.wt-photo [data-act=prev]'); await page.waitForTimeout(200)
  check(await page.evaluate(() => window.walkthrough.tourIndex) === i0, 'Prev goes back')
  await page.locator('.wt-ov').fill('60')
  check(await page.evaluate(() => { const o = document.querySelector('.wt-overlay'); return !o.hidden && +o.style.opacity === 0.6 }),
    'Compare slider overlays the photo')
  await page.screenshot({ path: path.join(out, 'tour-compare.png') })
  await page.keyboard.down('KeyW'); await page.waitForTimeout(200); await page.keyboard.up('KeyW')
  check(await page.evaluate(() => window.walkthrough.mode === 'walk' && document.querySelector('.wt-overlay').hidden),
    'walking away leaves the tour and hides the overlay')
  await page.click('.wt-modes button[data-mode=tour]'); await page.waitForTimeout(1100)
  check(await page.evaluate(() => {
    const p = window.walkthrough.tour[window.walkthrough.tourIndex], c = window.walkthrough.camera
    return Math.hypot(c.position.x - p.transform[12], c.position.z - p.transform[14]) < 1e-3
  }), 'returning to the tour restores the exact photo camera')

  await page.click('.wt-modes button[data-mode=dollhouse]')
  for (const layer of ['mesh', 'model', 'furniture', 'photos']) await page.locator(`[data-layer=${layer}]`).setChecked(layer === 'model')
  await page.waitForTimeout(150)
  await page.screenshot({ path: path.join(out, 'roomplan-only.png') })
  check(errors.length === 0, `no errors (${errors.join(' | ')})`)
  await page.close()
}

console.log('web app (zip opened in the browser)')
{
  const server = http.createServer(async (req, res) => {
    const u = decodeURIComponent(new URL(req.url, 'http://x').pathname)
    const file = u === '/scan.zip' ? path.join(out, 'FakeHouse.zip') : path.join(repo, u)
    if (!file.startsWith(repo) && !file.startsWith(out)) return void res.writeHead(403).end()
    try {
      const body = await readFile(file)
      const type = file.endsWith('.js') ? 'text/javascript' : file.endsWith('.html') ? 'text/html' : 'application/octet-stream'
      res.writeHead(200, { 'content-type': type }).end(body)
    } catch { res.writeHead(404).end() }
  }).listen(0)
  const { page, errors } = await open(`http://localhost:${server.address().port}/web/index.html?zip=/scan.zip`)
  const f = await coloredFraction(page)
  check(f > 0.5, `web app: mesh photo-colored (${Math.round(f * 100)}%)`)
  check(errors.length === 0, `web app: no errors (${errors.join(' | ')})`)
  await page.close()
  server.close()
}

// ---- 2. edge cases -------------------------------------------------------------------------------
console.log('edge-case bundles')
for (const [name, expect] of Object.entries({
  'single-room': { colored: 0.5 }, 'no-mesh': { colored: null }, 'no-depth': { colored: 0.3 },
  'no-photos': { tour: false }, 'ascii-ply': { colored: 0.5 }, 'raw-depth': { colored: 0.5 }, 'flat-zip': { colored: 0.5 },
})) {
  const { page, errors } = await open('file://' + path.join(out, 'variants', `${name}.html`))
  const ready = await page.evaluate(() => !!window.walkthrough)
  check(ready && errors.length === 0, `${name}: loads without errors ${errors.length ? '(' + errors.join(' | ') + ')' : ''}`)
  if (ready && 'colored' in expect) {
    const f = await coloredFraction(page)
    check(expect.colored === null ? f === null : f >= expect.colored, `${name}: mesh coloring ${f === null ? 'n/a' : Math.round(f * 100) + '%'}`)
  }
  if (ready && expect.tour === false) check(await page.isDisabled('.wt-modes button[data-mode=tour]'), `${name}: photo tour disabled`)
  await page.screenshot({ path: path.join(out, 'variants', `${name}.png`) })
  await page.close()
}

// ---- 4. renders from every photo's camera (compared by compare_poses.py) ----------------------
console.log('renders from each photo camera')
{
  // 600×800 = the photos' upright 3:4 aspect, so photo and render frame the same view
  const { page, errors } = await open('file://' + path.join(out, 'walkthrough.html'), { width: 600, height: 800 })
  const tour = await page.evaluate(() => window.walkthrough.tour.map((p) => p.file))
  for (let i = 0; i < tour.length; i++) {
    await page.evaluate((i) => { location.hash = `photo=${i}&ui=0&layers=mesh` }, i)
    await page.waitForTimeout(250)
    await page.screenshot({ path: path.join(out, `pose-${i}.png`) })
  }
  writeFileSync(path.join(out, 'pose-index.json'), JSON.stringify(tour))
  check(errors.length === 0 && tour.length > 0, `${tour.length} photo-camera renders saved`)
  await page.close()
}

// ---- 5. the clean model (make_model.py): loads, looks like a dollhouse, all modes work -----------
console.log('clean model (make_model.py)')
{
  const file = 'file://' + path.join(out, 'model', 'model.html')
  const { page, errors } = await open(file)
  const ready = await page.evaluate(() => !!window.walkthrough)
  check(ready && errors.length === 0, `model loads without errors ${errors.join(' | ')}`)
  const stats = await page.evaluate(() => {
    let meshes = 0, textured = 0
    window.walkthrough.scene.traverse((o) => {
      if (!o.isMesh) return
      meshes++
      for (const m of [].concat(o.material)) if (m.map && m.map.image?.width >= 256) textured++
    })
    const s = window.walkthrough.spec
    return { meshes, textured, rooms: s.rooms.length, items: s.items.length, labels: document.querySelectorAll('.hm-label').length }
  })
  check(stats.meshes > 40, `walls, trims, floors and furniture built (${stats.meshes} meshes)`)
  check(stats.textured > 0, 'floor textures from the photos are applied')
  check(stats.labels === stats.rooms, `one label per room (${stats.labels})`)
  await page.waitForTimeout(300)
  await page.screenshot({ path: path.join(out, 'model-dollhouse.png') })
  // software rendering makes ambient-occlusion frames slow: turn it off for the interaction checks
  await page.locator('.hm [data-t=quality]').setChecked(false); await page.waitForTimeout(500)
  // the dollhouse cuts away the walls between the camera and the rooms
  const cut = () => page.evaluate(() => { let n = 0; window.walkthrough.scene.traverse((o) => { if (o.userData.wall && !o.visible) n++ }); return n })
  const hidden = await cut()
  check(hidden > 0, `near walls cut away in the dollhouse (${hidden})`)
  await page.locator('.hm [data-t=cutaway]').setChecked(false); await page.waitForTimeout(100)
  check(await cut() === 0, 'unchecking "Cut away walls" shows them all')

  await page.click('.hm-modes button[data-mode=walk]')
  check(await page.evaluate(() => window.walkthrough.mode) === 'walk', 'model: Walk mode')
  const eye = await page.waitForFunction(() => Math.abs(window.walkthrough.camera.position.y - 1.6) < 0.05, null, { timeout: 15000 }).then(() => true, () => false)
  const a = await cam(page)
  // software rendering is slow, so hold W until the walk shows (or give up after 15 s)
  await page.keyboard.down('KeyW')
  await page.waitForFunction((a) => Math.hypot(window.walkthrough.camera.position.x - a.x, window.walkthrough.camera.position.z - a.z) > 0.3,
    a, { timeout: 15000 }).catch(() => {})
  await page.keyboard.up('KeyW')
  const b = await cam(page)
  check(Math.hypot(b.x - a.x, b.z - a.z) > 0.3, `model: W walks forward (${Math.hypot(b.x - a.x, b.z - a.z).toFixed(2)} m)`)
  check(eye, `model: walking at eye height (${a.y.toFixed(2)} m)`)
  check(await page.isVisible('.hm-move') && !(await page.isVisible('.hm-photo')), 'model: touch walk buttons shown in Walk')
  await page.screenshot({ path: path.join(out, 'model-walk.png') })

  await page.click('.hm-modes button[data-mode=photo]'); await page.waitForTimeout(800)
  const t = await page.evaluate(() => {
    const p = window.walkthrough.spec.photos[0], c = window.walkthrough.camera
    return { d: Math.hypot(c.position.x - p.transform[12], c.position.y - p.transform[13], c.position.z - p.transform[14]),
             fov: c.fov, want: 2 * Math.atan(p.width / 2 / p.fx) * 180 / Math.PI }
  })
  check(t.d < 1e-3 && Math.abs(t.fov - t.want) < 0.01, `model: photo camera sits exactly at the photo (Δ ${t.d.toExponential(1)} m)`)
  await page.click('.hm-photo [data-a=next]'); await page.waitForTimeout(300)
  check(await page.textContent('.hm-photo .count') === `2 / ${await page.evaluate(() => window.walkthrough.spec.photos.length)}`, 'model: next photo')
  await page.locator('.hm-photo .ov').fill('50')
  check(await page.evaluate(() => { const o = document.querySelector('.hm-overlay'); return !o.hidden && +o.style.opacity === 0.5 }), 'model: compare overlay')
  await page.screenshot({ path: path.join(out, 'model-photo.png') })
  await page.click('.hm-modes button[data-mode=dollhouse]'); await page.waitForTimeout(300)
  check(await page.evaluate(() => window.walkthrough.camera.position.y > 4), 'model: back to Dollhouse restores the overview camera')
  check(errors.length === 0, `model: no errors after interaction (${errors.join(' | ')})`)
  await page.close()

  // phone-sized: the toolbar must not cover the title
  const phone = await open(file + '#quality=0', { width: 390, height: 844 })
  check(phone.errors.length === 0, 'model on a phone-sized screen loads')
  await phone.page.screenshot({ path: path.join(out, 'model-phone.png') })
  await phone.page.close()

  // renders from each photo camera for compare_poses.py (model- prefix)
  const r = await open(file + '#ui=0&quality=0', { width: 600, height: 800 })
  const files = await r.page.evaluate(() => window.walkthrough.spec.photos.map((p) => p.file))
  for (let i = 0; i < files.length; i++) {
    await r.page.evaluate((i) => window.walkthrough.goToPhoto(i), i)
    await r.page.waitForTimeout(250)
    await r.page.screenshot({ path: path.join(out, `model-pose-${i}.png`) })
  }
  writeFileSync(path.join(out, 'model-pose-index.json'), JSON.stringify(files))
  await r.page.close()

  for (const v of ['single-room', 'no-depth', 'no-photos']) {
    const m = await open('file://' + path.join(out, 'variants', `${v}-model`, 'model.html') + '#quality=0')
    const ok = await m.page.evaluate(() => !!window.walkthrough)
    check(ok && m.errors.length === 0, `${v}: model loads without errors ${m.errors.join(' | ')}`)
    if (v === 'no-photos') check(await m.page.isDisabled('.hm-modes button[data-mode=photo]'), 'no-photos: model photo mode disabled')
    await m.page.screenshot({ path: path.join(out, 'variants', `${v}-model.png`) })
    await m.page.close()
  }
}

await browser.close()
console.log(failures.length ? `\n${failures.length} FAILED:\n- ${failures.join('\n- ')}` : '\nall browser checks passed')
process.exit(failures.length ? 1 : 0)
