// Photoreal walkthrough of a Gaussian-splat scene (train.py → make_splat_html.py).
//
//   startSplat(THREE, container, source)   THREE = spark.bundle.min.js (three.js + Spark)
//   source = { files: string[], read(path) -> ArrayBuffer }
//
// Files: scene.sog (PlayCanvas SOG) or scene.splat, in the model frame (meters, +Y up, floor at
// y = 0); dollhouse.sog (optional, the scene without its ceiling); cameras.json (photo cameras,
// OpenGL camera-to-world) and photos/*.jpg (upright). Modes:
//   Dollhouse  orbit from above; splats above `cut` (the ceiling, the top of the walls) are left
//              out so you see into the rooms
//   Walk       eye height, drag to look, WASD / arrows / on-screen buttons to move
//   Photos     the exact camera of each photo, with a Compare slider that blends the photo in
// Hash options: #photo=N&ui=0&overlay=0.5&mode=walk|dollhouse&cut=2.0

const BG = '#0b1626'

export async function startSplat(THREE, container, source) {
  const ui = buildUI(container)
  const has = new Set(source.files)
  const cams = has.has('cameras.json') ? JSON.parse(new TextDecoder().decode(await source.read('cameras.json'))) : { cameras: [] }
  const splatFile = ['scene.sog', 'scene.splat', 'scene.spz', 'scene.ply'].find((f) => has.has(f))
  if (!splatFile) throw new Error('no splat scene in this file')
  const bytes = new Uint8Array(await source.read(splatFile))
  const typeOf = (f) => ({ sog: 'pcsogszip' })[f.split('.').pop()] || f.split('.').pop()

  const renderer = new THREE.WebGLRenderer({ antialias: false, preserveDrawingBuffer: true })
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2))
  ui.stage.appendChild(renderer.domElement)
  const scene = new THREE.Scene()
  scene.background = new THREE.Color(BG)
  const camera = new THREE.PerspectiveCamera(50, 1, 0.03, 300)
  const spark = new THREE.SparkRenderer({ renderer })
  scene.add(spark)

  const fileType = typeOf(splatFile)
  const full = new THREE.SplatMesh({ fileBytes: bytes.slice().buffer, fileType })
  scene.add(full)
  // the dollhouse: the same splats without the ceiling: dollhouse.sog (made by playcanvas.py),
  // or cut here from a .splat (32-byte records, y at byte 4)
  const params = new URLSearchParams(location.hash.slice(1))
  let cut = +(params.get('cut') || 0) || cams.dollhouse_cut || 0
  let doll = null
  const stats = splatStats(bytes, fileType) || boundsStats(cams)
  if (!cut && stats?.ceiling) cut = Math.max(1.2, stats.ceiling - 0.45)
  if (has.has('dollhouse.sog') && !params.get('cut')) {
    doll = new THREE.SplatMesh({ fileBytes: await source.read('dollhouse.sog'), fileType: 'pcsogszip' })
    scene.add(doll)
  } else if (fileType === 'splat') {
    doll = new THREE.SplatMesh({ fileBytes: filterSplat(bytes, cut).buffer, fileType })
    scene.add(doll)
  }
  await Promise.all([full.initialized, doll?.initialized].filter(Boolean))

  // the house's extent from the splats (robust: the middle 98%) or from the cameras
  const box = stats ? stats.box : new THREE.Box3(new THREE.Vector3(-3, 0, -3), new THREE.Vector3(3, 2.5, 3))
  const center = box.getCenter(new THREE.Vector3()), size = box.getSize(new THREE.Vector3())
  const radius = Math.max(2, Math.hypot(size.x, size.z) / 2)

  const orbit = new THREE.OrbitControls(camera, renderer.domElement)
  orbit.enableDamping = true
  orbit.target.set(center.x, 0.3, center.z)
  orbit.maxPolarAngle = Math.PI * 0.49
  orbit.maxDistance = radius * 6
  function frameHouse() {
    const aspect = Math.max(0.4, (ui.stage.clientWidth || 1) / (ui.stage.clientHeight || 1))
    const vfov = THREE.MathUtils.degToRad(50) / 2, hfov = Math.atan(Math.tan(vfov) * aspect)
    const dist = (radius + 0.3) / Math.sin(Math.min(vfov, hfov)) * 0.9
    camera.position.copy(orbit.target).addScaledVector(new THREE.Vector3(0.5, 1.2, 0.75).normalize(), dist)
    orbit.update()
  }
  frameHouse()

  // photo cameras (upright: sensor frame turned 90°, vertical fov from the sensor's width)
  const photos = (cams.cameras || []).filter((c) => c.photo && has.has(c.photo))
  const upright = new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), Math.PI / 2)
  const photoPose = (c) => {
    const m = new THREE.Matrix4().fromArray(c.transform.flat()).transpose() // row-major → three
    return { pos: new THREE.Vector3().setFromMatrixPosition(m), quat: new THREE.Quaternion().setFromRotationMatrix(m).multiply(upright),
             fov: THREE.MathUtils.radToDeg(2 * Math.atan(c.w / 2 / c.fl_x)) }
  }

  let mode = 'dollhouse', photoIndex = -1, exact = null, dollhouseView = null
  const start = photos.length ? photoPose(photos[0]).pos.clone().setY(1.6) : new THREE.Vector3(center.x, 1.6, center.z)
  const walk = { pos: start.clone(), yaw: 0, pitch: 0 }
  const keys = new Set()
  addEventListener('keydown', (e) => { if (!e.target.closest?.('textarea,input:not([type=range]):not([type=checkbox])')) keys.add(e.code) })
  addEventListener('keyup', (e) => keys.delete(e.code))
  for (const b of ui.moveButtons) {
    b.addEventListener('pointerdown', (e) => { e.preventDefault(); keys.add(b.dataset.key) })
    for (const ev of ['pointerup', 'pointerleave', 'pointercancel']) b.addEventListener(ev, () => keys.delete(b.dataset.key))
  }
  let drag = null
  renderer.domElement.addEventListener('pointerdown', (e) => { if (mode !== 'dollhouse') drag = { x: e.clientX, y: e.clientY } })
  addEventListener('pointerup', () => { drag = null })
  addEventListener('pointermove', (e) => {
    if (!drag || mode === 'dollhouse') return
    if (mode === 'photo') setMode('walk')
    walk.yaw += (e.clientX - drag.x) * 0.004
    walk.pitch = Math.max(-1.3, Math.min(1.3, walk.pitch + (e.clientY - drag.y) * 0.004))
    drag = { x: e.clientX, y: e.clientY }
  })

  function setMode(m) {
    const prev = mode
    if (prev === 'dollhouse' && m !== 'dollhouse') dollhouseView = camera.position.clone()
    mode = m
    orbit.enabled = m === 'dollhouse'
    ui.move.hidden = m !== 'walk'
    ui.photoPanel.hidden = m !== 'photo'
    for (const b of ui.modeButtons) b.classList.toggle('on', b.dataset.mode === m)
    if (m !== 'photo') { exact = null; ui.overlay.hidden = true }
    if (m === 'walk') {
      const d = camera.getWorldDirection(new THREE.Vector3())
      if (prev === 'dollhouse') walk.pos.copy(start)
      walk.yaw = Math.atan2(-d.x, -d.z); walk.pitch = 0
    }
    if (m === 'dollhouse' && prev !== 'dollhouse') {
      camera.fov = 50; camera.updateProjectionMatrix()
      if (dollhouseView) camera.position.copy(dollhouseView); else frameHouse()
      orbit.update()
    }
    updateCut()
    if (m === 'photo' && photos.length && !exact) goToPhoto(Math.max(0, photoIndex))
  }
  function updateCut() {
    const cutaway = mode === 'dollhouse' && ui.cut.checked && doll
    full.visible = !cutaway
    if (doll) doll.visible = !!cutaway
  }
  ui.cut.onchange = updateCut

  function goToPhoto(i) {
    if (!photos.length) return
    photoIndex = (i + photos.length) % photos.length
    const c = photos[photoIndex]
    exact = photoPose(c)
    walk.pos.copy(exact.pos)
    if (mode !== 'photo') setMode('photo')
    ui.photoCount.textContent = `${photoIndex + 1} / ${photos.length}`
    source.read(c.photo).then((buf) => {
      const url = URL.createObjectURL(new Blob([buf], { type: 'image/jpeg' }))
      ui.overlay.src = url; ui.photoImg.src = url
    })
    applyOverlay()
  }
  function applyOverlay() {
    const v = +ui.overlaySlider.value / 100
    ui.overlay.hidden = mode !== 'photo' || v <= 0
    ui.overlay.style.opacity = v
  }
  ui.overlaySlider.oninput = applyOverlay
  ui.prev.onclick = () => goToPhoto(photoIndex - 1)
  ui.next.onclick = () => goToPhoto(photoIndex + 1)
  for (const b of ui.modeButtons) b.onclick = () => setMode(b.dataset.mode)
  if (!photos.length) ui.modeButtons.find((b) => b.dataset.mode === 'photo').disabled = true
  if (!doll) ui.cut.closest('label').hidden = true
  ui.title.textContent = cams.property || 'Photoreal walkthrough'
  ui.subtitle.textContent = `${(stats?.count ?? cams.splats ?? 0).toLocaleString()} splats · ${photos.length} photo spots`

  function applyHash() {
    const q = new URLSearchParams(location.hash.slice(1))
    if (q.get('ui') === '0') ui.root.dataset.ui = '0'
    if (q.has('overlay')) ui.overlaySlider.value = Math.round(Math.min(1, Math.max(0, +q.get('overlay') || 0)) * 100)
    if (q.has('photo') && photos.length) goToPhoto(+q.get('photo') || 0)
    else if (q.get('mode')) setMode(q.get('mode'))
    applyOverlay()
  }
  applyHash()
  addEventListener('hashchange', applyHash)
  updateCut()

  let last = performance.now()
  renderer.setAnimationLoop((now) => {
    const dt = Math.min(0.1, (now - last) / 1000); last = now
    const w = ui.stage.clientWidth, h = ui.stage.clientHeight
    const pr = renderer.getPixelRatio()
    if (renderer.domElement.width !== Math.round(w * pr) || renderer.domElement.height !== Math.round(h * pr)) {
      renderer.setSize(w, h, false)
      camera.aspect = w / Math.max(1, h); camera.updateProjectionMatrix()
    }
    if (mode === 'dollhouse') orbit.update()
    else if (mode === 'photo' && exact) {
      camera.position.copy(exact.pos); camera.quaternion.copy(exact.quat)
      if (camera.fov !== exact.fov) { camera.fov = exact.fov; camera.updateProjectionMatrix() }
    } else {
      if (camera.fov !== 70) { camera.fov = 70; camera.updateProjectionMatrix() }
      const fwd = new THREE.Vector3(-Math.sin(walk.yaw), 0, -Math.cos(walk.yaw)), right = new THREE.Vector3(-fwd.z, 0, fwd.x)
      let f = 0, r = 0
      if (keys.has('KeyW') || keys.has('ArrowUp')) f += 1
      if (keys.has('KeyS') || keys.has('ArrowDown')) f -= 1
      if (keys.has('KeyD')) r += 1
      if (keys.has('KeyA')) r -= 1
      if (keys.has('ArrowLeft')) walk.yaw += dt * 1.8
      if (keys.has('ArrowRight')) walk.yaw -= dt * 1.8
      walk.pos.addScaledVector(fwd, f * dt * 1.4).addScaledVector(right, r * dt * 1.4)
      walk.pos.y += (1.6 - walk.pos.y) * Math.min(1, dt * 4)
      camera.position.copy(walk.pos)
      camera.rotation.set(walk.pitch, walk.yaw, 0, 'YXZ')
    }
    renderer.render(scene, camera)
  })
  return { scene, camera, renderer, setMode, goToPhoto, photos, cut, get mode() { return mode }, get ready() { return true } }
}

/** extent and ceiling height of a .splat file (robust percentiles of a sample) */
function splatStats(bytes, type) {
  if (type !== 'splat') return null
  const n = Math.floor(bytes.byteLength / 32)
  if (!n) return null
  const f = new Float32Array(bytes.buffer, bytes.byteOffset, n * 8)
  const step = Math.max(1, Math.floor(n / 20000))
  const xs = [], ys = [], zs = []
  for (let i = 0; i < n; i += step) { xs.push(f[i * 8]); ys.push(f[i * 8 + 1]); zs.push(f[i * 8 + 2]) }
  const q = (a, p) => { const s = [...a].sort((x, y) => x - y); return s[Math.min(s.length - 1, Math.floor(p * s.length))] }
  const box = { min: [q(xs, 0.01), q(ys, 0.01), q(zs, 0.01)], max: [q(xs, 0.99), q(ys, 0.99), q(zs, 0.99)] }
  return {
    count: n, ceiling: q(ys, 0.985),
    box: { getCenter: (v) => v.set((box.min[0] + box.max[0]) / 2, (box.min[1] + box.max[1]) / 2, (box.min[2] + box.max[2]) / 2),
           getSize: (v) => v.set(box.max[0] - box.min[0], box.max[1] - box.min[1], box.max[2] - box.min[2]) },
  }
}

/** extent from cameras.json's bounds (written by playcanvas.py with the .sog files) */
function boundsStats(cams) {
  const b = cams.bounds
  if (!b) return null
  return {
    count: cams.splats, ceiling: b[1][1],
    box: { getCenter: (v) => v.set((b[0][0] + b[1][0]) / 2, (b[0][1] + b[1][1]) / 2, (b[0][2] + b[1][2]) / 2),
           getSize: (v) => v.set(b[1][0] - b[0][0], b[1][1] - b[0][1], b[1][2] - b[0][2]) },
  }
}

/** the .splat records whose center is below `cut` meters */
function filterSplat(bytes, cut) {
  const n = Math.floor(bytes.byteLength / 32)
  const f = new Float32Array(bytes.buffer, bytes.byteOffset, n * 8)
  const out = new Uint8Array(n * 32)
  let k = 0
  for (let i = 0; i < n; i++) {
    if (f[i * 8 + 1] < cut) { out.set(bytes.subarray(i * 32, i * 32 + 32), k * 32); k++ }
  }
  return out.slice(0, k * 32)
}

function buildUI(container) {
  const style = document.createElement('style')
  style.textContent = `
  .sv{position:relative;width:100%;height:100%;overflow:hidden;font:14px/1.35 system-ui,-apple-system,sans-serif;color:#eef2f8;background:${BG};touch-action:none;user-select:none}
  .sv-stage,.sv-stage canvas{position:absolute;inset:0;width:100%;height:100%;display:block}
  .sv-card{background:rgba(12,22,38,.78);backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);border:1px solid rgba(150,190,240,.14);border-radius:12px;padding:8px 12px}
  .sv-top{position:absolute;left:12px;right:12px;top:12px;display:flex;gap:8px;flex-wrap:wrap;align-items:flex-start;pointer-events:none}
  .sv-top>*{pointer-events:auto}.sv-title{font-weight:650;font-size:15px}.sv-sub{opacity:.7;font-size:12px}
  .sv-modes{margin-left:auto;display:flex;gap:4px}
  .sv button{font:inherit;color:inherit;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.14);border-radius:9px;padding:7px 12px;cursor:pointer;white-space:nowrap}
  .sv button.on{background:#3d8bfd;border-color:#3d8bfd}.sv button:disabled{opacity:.35}
  .sv-bottom{position:absolute;left:12px;bottom:12px;display:flex;gap:12px;font-size:12px;align-items:center}
  .sv-bottom label{display:flex;gap:5px;align-items:center}
  .sv-overlay{position:absolute;top:0;left:50%;height:100%;transform:translateX(-50%);pointer-events:none}
  .sv-overlay[hidden],.sv-move[hidden],.sv label[hidden]{display:none}
  .sv-photo{position:absolute;right:12px;bottom:12px;width:min(240px,40vw)}
  .sv-photo img{width:100%;border-radius:8px;display:block}
  .sv-photo .row{display:flex;gap:6px;align-items:center;margin-top:6px;font-size:12px}
  .sv-photo .count{white-space:nowrap}.sv-photo input{min-width:0;width:100%}
  .sv-move{position:absolute;right:16px;bottom:64px;display:flex;flex-direction:column;gap:8px}
  .sv-move button{width:56px;height:56px;border-radius:50%;font-size:20px;padding:0;touch-action:none}
  .sv[data-ui="0"] .sv-top,.sv[data-ui="0"] .sv-bottom,.sv[data-ui="0"] .sv-photo,.sv[data-ui="0"] .sv-move{display:none!important}
  @media (max-width:600px){.sv-modes{margin-left:0}.sv-hint{display:none}}`
  const root = document.createElement('div')
  root.className = 'sv'
  root.innerHTML = `
    <div class="sv-stage"></div>
    <img class="sv-overlay" alt="" hidden>
    <div class="sv-top">
      <div class="sv-card"><div class="sv-title"></div><div class="sv-sub"></div></div>
      <div class="sv-card sv-modes"><button data-mode="dollhouse" class="on">Dollhouse</button><button data-mode="walk">Walk</button><button data-mode="photo">Photos</button></div>
    </div>
    <div class="sv-card sv-bottom">
      <label><input type="checkbox" data-t="cut" checked>Cut away ceiling</label>
      <span class="sv-hint" style="opacity:.6">Drag to orbit · scroll to zoom · WASD in Walk</span>
    </div>
    <div class="sv-move" hidden><button data-key="KeyW" aria-label="Walk forward">▲</button><button data-key="KeyS" aria-label="Walk back">▼</button></div>
    <div class="sv-card sv-photo" hidden>
      <img alt="Photo from this spot">
      <div class="row"><button data-a="prev">‹</button><span class="count"></span><button data-a="next">›</button>
      <label style="flex:1;min-width:0;display:flex;gap:6px;align-items:center">Compare <input type="range" min="0" max="100" value="0" class="ov"></label></div>
    </div>`
  container.append(style, root)
  const q = (s) => root.querySelector(s)
  return {
    root, stage: q('.sv-stage'), overlay: q('.sv-overlay'), title: q('.sv-title'), subtitle: q('.sv-sub'),
    modeButtons: [...root.querySelectorAll('[data-mode]')], cut: q('[data-t=cut]'),
    move: q('.sv-move'), moveButtons: [...root.querySelectorAll('.sv-move button')],
    photoPanel: q('.sv-photo'), photoImg: q('.sv-photo img'), photoCount: q('.sv-photo .count'),
    prev: q('[data-a=prev]'), next: q('[data-a=next]'), overlaySlider: q('.ov'),
  }
}
