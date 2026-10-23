// 3D property walkthrough for a house-capture/5 scan bundle (iPhone LiDAR + RoomPlan + photos).
//
// Shared by web/index.html (open a .zip in the browser) and make_walkthrough.py (one offline
// .html file). It never imports three itself: the caller passes the THREE namespace in, so the
// same file works from a CDN, a vendored bundle, or a blob: URL inside a single HTML file.
//
//   startWalkthrough(THREE, container, source)
//   source = { files: string[]  (paths relative to the bundle root, i.e. next to manifest.json),
//              read(path) -> Promise<ArrayBuffer> }
//
// Coordinates are the capture session's ARKit world: meters, +Y up, right-handed — the same
// convention as three.js, so geometry goes in untransformed. Matrices are column-major arrays
// (Matrix4.fromArray reads them directly). Photo/depth pixels are raw landscape sensor frames.

const CLASS_COLORS = [ // ARMeshClassification: none wall floor ceiling table seat window door
  [0.62, 0.62, 0.64], [0.80, 0.79, 0.76], [0.55, 0.47, 0.40], [0.88, 0.88, 0.88],
  [0.55, 0.40, 0.30], [0.35, 0.45, 0.60], [0.55, 0.75, 0.90], [0.60, 0.45, 0.35],
]
const EYE_HEIGHT = 1.6
const MAX_COLOR_VIEWS = 400

export async function startWalkthrough(THREE, container, source) {
  const ui = buildUI(container)
  const status = (text) => { ui.status.textContent = text; ui.status.hidden = !text }
  status('Reading scan…')

  const has = new Set(source.files)
  const text = async (p) => new TextDecoder().decode(await source.read(p))
  const json = async (p) => JSON.parse(await text(p))
  const optionalJSON = async (p) => (p && has.has(p) ? json(p) : null)

  const manifest = await json('manifest.json')
  if (!String(manifest.format || '').startsWith('house-capture/')) {
    throw new Error(`Not a house-capture bundle (format: ${manifest.format})`)
  }
  const rooms = manifest.rooms || []
  const photos = (await optionalJSON(manifest.photos || 'photos/photos.json')) || []
  const depthFrames = (await optionalJSON(manifest.depthFrames || 'depth/frames.json')) || []
  const geo = manifest.property || null

  // ---- scene ---------------------------------------------------------------------------
  const renderer = new THREE.WebGLRenderer({ antialias: true })
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2))
  renderer.outputColorSpace = THREE.SRGBColorSpace
  ui.stage.appendChild(renderer.domElement)
  const scene = new THREE.Scene()
  scene.background = new THREE.Color(0x15171c)
  scene.add(new THREE.HemisphereLight(0xffffff, 0x444455, 2.2))
  const sun = new THREE.DirectionalLight(0xffffff, 1.2)
  sun.position.set(3, 10, 4)
  scene.add(sun)
  const camera = new THREE.PerspectiveCamera(70, 1, 0.03, 300)
  camera.rotation.order = 'YXZ'

  const layers = {
    mesh: new THREE.Group(), model: new THREE.Group(), furniture: new THREE.Group(), photos: new THREE.Group(),
  }
  for (const g of Object.values(layers)) scene.add(g)

  // ---- RoomPlan model (Apple's parametric walls/doors/windows/objects) ------------------
  const structure = await optionalJSON(manifest.structure)
  const roomJSONs = structure ? [structure] : (await Promise.all(rooms.map((r) => optionalJSON(r.file)))).filter(Boolean)
  const elements = (key) => roomJSONs.flatMap((r) => r[key] || [])
  const walls = elements('walls'), floors = elements('floors')
  const openings = [...elements('doors').map((e) => ['door', e]), ...elements('windows').map((e) => ['window', e]),
    ...elements('openings').map((e) => ['opening', e])]
  const objects = elements('objects')

  const m4 = (t) => new THREE.Matrix4().fromArray(t)
  const pos = (t) => new THREE.Vector3(t[12], t[13], t[14])
  let floorY = floors.length ? Math.min(...floors.map((f) => f.transform[13]))
    : walls.length ? Math.min(...walls.map((w) => w.transform[13] - w.dimensions[1] / 2)) : NaN

  const wallMat = new THREE.MeshStandardMaterial({ color: 0xe9e5dc, roughness: 0.9, side: THREE.DoubleSide, transparent: true, opacity: 0.55, depthWrite: false })
  const edgeMat = new THREE.LineBasicMaterial({ color: 0xffffff, transparent: true, opacity: 0.6 })
  for (const w of walls) {
    const [ww, wh] = w.dimensions
    const M = m4(w.transform), inv = M.clone().invert()
    const shape = new THREE.Shape()
    shape.moveTo(-ww / 2, -wh / 2); shape.lineTo(ww / 2, -wh / 2); shape.lineTo(ww / 2, wh / 2); shape.lineTo(-ww / 2, wh / 2)
    for (const [, e] of openings.filter(([, e]) => e.parentIdentifier === w.identifier)) {
      const c = pos(e.transform).applyMatrix4(inv)
      const eps = 0.01
      const x0 = Math.max(-ww / 2 + eps, c.x - e.dimensions[0] / 2), x1 = Math.min(ww / 2 - eps, c.x + e.dimensions[0] / 2)
      const y0 = Math.max(-wh / 2 + eps, c.y - e.dimensions[1] / 2), y1 = Math.min(wh / 2 - eps, c.y + e.dimensions[1] / 2)
      if (x1 - x0 < 0.05 || y1 - y0 < 0.05) continue
      const hole = new THREE.Path()
      hole.moveTo(x0, y0); hole.lineTo(x0, y1); hole.lineTo(x1, y1); hole.lineTo(x1, y0)
      shape.holes.push(hole)
    }
    const geom = new THREE.ShapeGeometry(shape)
    const mesh = new THREE.Mesh(geom, wallMat)
    mesh.applyMatrix4(M)
    layers.model.add(mesh)
    const edges = new THREE.LineSegments(new THREE.EdgesGeometry(geom), edgeMat)
    edges.applyMatrix4(M)
    layers.model.add(edges)
  }
  const kindColor = { door: 0x8a5a3c, window: 0x7fc8ff, opening: 0x55ff99 }
  for (const [kind, e] of openings) {
    const [ew, eh] = e.dimensions
    const isOpen = kind === 'door' && e.category?.door?.isOpen
    if (kind === 'opening' || isOpen) continue
    const mesh = new THREE.Mesh(new THREE.PlaneGeometry(ew, eh), new THREE.MeshStandardMaterial({
      color: kindColor[kind], transparent: true, opacity: kind === 'window' ? 0.25 : 0.5, side: THREE.DoubleSide, depthWrite: false,
    }))
    mesh.applyMatrix4(m4(e.transform))
    layers.model.add(mesh)
  }
  const floorMat = new THREE.MeshStandardMaterial({ color: 0x9b8a78, roughness: 1, side: THREE.DoubleSide, transparent: true, opacity: 0.85 })
  for (const f of floors) {
    const M = m4(f.transform)
    let corners = (f.polygonCorners || []).map((p) => new THREE.Vector3(p[0], p[1], p[2]).applyMatrix4(M))
    if (corners.length < 3) {
      const [fw, fh] = f.dimensions
      corners = [[-1, -1], [1, -1], [1, 1], [-1, 1]].map(([a, b]) => new THREE.Vector3(a * fw / 2, b * fh / 2, 0).applyMatrix4(M))
    }
    const shape = new THREE.Shape(corners.map((p) => new THREE.Vector2(p.x, -p.z)))
    const mesh = new THREE.Mesh(new THREE.ShapeGeometry(shape), floorMat)
    mesh.rotation.x = -Math.PI / 2
    mesh.position.y = f.transform[13] - 0.005
    layers.model.add(mesh)
  }
  const objMat = new THREE.MeshStandardMaterial({ color: 0xf0a040, transparent: true, opacity: 0.35, depthWrite: false })
  const objEdge = new THREE.LineBasicMaterial({ color: 0xffc070 })
  for (const o of objects) {
    const [ow, oh, od] = o.dimensions
    const box = new THREE.BoxGeometry(ow, oh, od)
    const M = m4(o.transform)
    const mesh = new THREE.Mesh(box, objMat); mesh.applyMatrix4(M); layers.furniture.add(mesh)
    const edges = new THREE.LineSegments(new THREE.EdgesGeometry(box), objEdge); edges.applyMatrix4(M); layers.furniture.add(edges)
    const label = textSprite(THREE, Object.keys(o.category || { object: 0 })[0])
    label.position.copy(pos(o.transform)).add(new THREE.Vector3(0, oh / 2 + 0.15, 0))
    layers.furniture.add(label)
  }

  // ---- LiDAR mesh (latest room's PLY holds the whole session's mesh) ---------------------
  const meshFile = manifest.mesh?.file || [...rooms].reverse().find((r) => r.mesh)?.mesh.file
  let scanMesh = null
  if (meshFile && has.has(meshFile)) {
    status('Loading LiDAR mesh…')
    const ply = parsePLY(await source.read(meshFile))
    if (Number.isNaN(floorY)) floorY = percentile(ply.positions.filter((_, i) => i % 3 === 1), 0.02)
    scanMesh = buildScanMesh(THREE, ply, floorY)
    layers.mesh.add(scanMesh.mesh)
  }
  if (Number.isNaN(floorY)) floorY = 0

  // ---- photo markers -----------------------------------------------------------------------
  const tour = photos.filter((p) => p.manual).length >= 2 ? photos.filter((p) => p.manual) : photos
  tour.sort((a, b) => a.timestamp - b.timestamp)
  const markerGeo = new THREE.SphereGeometry(0.07, 12, 8)
  const markerMat = new THREE.MeshBasicMaterial({ color: 0xff4f9a })
  const frustumMat = new THREE.LineBasicMaterial({ color: 0xff4f9a })
  const pickables = []
  tour.forEach((p, i) => {
    const M = m4(p.transform)
    const marker = new THREE.Mesh(markerGeo, markerMat)
    marker.position.copy(pos(p.transform))
    marker.userData.tourIndex = i
    pickables.push(marker)
    layers.photos.add(marker)
    // portrait frustum: image up = sensor -X
    const s = 0.22, hw = (p.height / p.width) * s * 0.5, hh = s * 0.5
    const corners = [[-hh, hw], [hh, hw], [hh, -hw], [-hh, -hw]].map(([x, y]) => new THREE.Vector3(x, y, -s))
    const pts = []
    for (let k = 0; k < 4; k++) pts.push(new THREE.Vector3(), corners[k], corners[k], corners[(k + 1) % 4])
    const lines = new THREE.LineSegments(new THREE.BufferGeometry().setFromPoints(pts), frustumMat)
    lines.applyMatrix4(M)
    layers.photos.add(lines)
  })

  // ---- framing -----------------------------------------------------------------------------
  const bounds = new THREE.Box3()
  for (const g of [layers.model, layers.mesh, layers.photos]) bounds.expandByObject(g)
  if (bounds.isEmpty()) bounds.set(new THREE.Vector3(-3, floorY, -3), new THREE.Vector3(3, floorY + 2.5, 3))
  const center = bounds.getCenter(new THREE.Vector3())
  const radius = Math.max(2, bounds.getSize(new THREE.Vector3()).length() / 2)

  // ---- controls ----------------------------------------------------------------------------
  const orbit = { target: new THREE.Vector3(center.x, floorY + 1, center.z), yaw: Math.PI / 4, pitch: 0.9, dist: radius * 1.6 }
  const walk = { pos: new THREE.Vector3(center.x, floorY + EYE_HEIGHT, center.z), yaw: 0, pitch: 0 }
  if (tour.length) setWalkFromPhoto(tour[0])
  let mode = 'dollhouse'
  const keys = new Set()
  const joy = { x: 0, y: 0 }
  let tourIndex = -1
  let anim = null

  function setWalkFromPhoto(p) {
    const t = p.transform
    walk.pos.set(t[12], t[13], t[14])
    const f = new THREE.Vector3(-t[8], -t[9], -t[10]).normalize()
    walk.pitch = Math.asin(Math.max(-1, Math.min(1, f.y)))
    walk.yaw = Math.atan2(-f.x, -f.z)
  }

  function setMode(m) {
    mode = m
    ui.root.dataset.mode = m
    for (const b of ui.modeButtons) b.classList.toggle('on', b.dataset.mode === m)
    if (scanMesh) scanMesh.setDollhouse(m === 'dollhouse')
    layers.photos.visible = ui.toggles.photos.checked && m === 'dollhouse'
    if (m !== 'tour') ui.photoPanel.hidden = true
    if (m === 'tour' && tourIndex < 0 && tour.length) goToPhoto(0)
  }

  function goToPhoto(i) {
    if (!tour.length) return
    tourIndex = (i + tour.length) % tour.length
    const p = tour[tourIndex]
    const from = { pos: walk.pos.clone(), yaw: walk.yaw, pitch: walk.pitch }
    setWalkFromPhoto(p)
    const to = { pos: walk.pos.clone(), yaw: walk.yaw, pitch: walk.pitch }
    if (mode !== 'dollhouse') {
      // shortest yaw path
      let dy = to.yaw - from.yaw
      while (dy > Math.PI) dy -= 2 * Math.PI
      while (dy < -Math.PI) dy += 2 * Math.PI
      to.yaw = from.yaw + dy
      anim = { from, to, t0: performance.now(), dur: 900 }
      Object.assign(walk, { pos: from.pos.clone(), yaw: from.yaw, pitch: from.pitch })
    }
    if (mode === 'dollhouse') setMode('tour')
    showPhoto(p)
  }

  async function showPhoto(p) {
    ui.photoPanel.hidden = false
    ui.photoCounter.textContent = `${tourIndex + 1} / ${tour.length}`
    const room = rooms.find((r) => r.index === p.room)
    const loc = p.location
    ui.photoMeta.innerHTML = [
      room ? `<b>${esc(room.name || `Room ${room.index + 1}`)}</b>` : '',
      p.highRes ? `${p.width}×${p.height} high-res` : `${p.width}×${p.height}`,
      p.capturedAt ? esc(new Date(p.capturedAt).toLocaleString()) : '',
      loc ? `<a target="_blank" rel="noopener" href="https://maps.apple.com/?ll=${loc.latitude},${loc.longitude}&q=Photo">` +
        `${loc.latitude.toFixed(6)}, ${loc.longitude.toFixed(6)}</a> ±${Math.round(loc.horizontalAccuracy)} m` : '',
      loc && loc.heading != null ? `heading ${Math.round(loc.heading)}°` : '',
      p.note ? esc(p.note) : '',
    ].filter(Boolean).join(' · ')
    ui.photoImg.removeAttribute('src')
    if (has.has(p.file)) {
      const url = URL.createObjectURL(new Blob([await source.read(p.file)], { type: 'image/jpeg' }))
      if (tour[tourIndex] === p) ui.photoImg.src = url
    }
  }

  // pointer handling: drag = look (walk/tour) or orbit (dollhouse); pinch/wheel = zoom
  const pointers = new Map()
  let pinch = 0
  let downAt = null
  const el = renderer.domElement
  el.addEventListener('pointerdown', (e) => {
    el.setPointerCapture(e.pointerId)
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY, button: e.button })
    downAt = { x: e.clientX, y: e.clientY, t: performance.now() }
    if (pointers.size === 2) pinch = pinchDistance()
  })
  el.addEventListener('pointermove', (e) => {
    const p = pointers.get(e.pointerId)
    if (!p) return
    const dx = e.clientX - p.x, dy = e.clientY - p.y
    p.x = e.clientX; p.y = e.clientY
    if (pointers.size === 2) {
      const d = pinchDistance()
      if (pinch) zoom(pinch / d)
      pinch = d
      return
    }
    if (mode === 'dollhouse') {
      if (p.button === 2 || e.shiftKey) {
        const right = new THREE.Vector3().setFromMatrixColumn(camera.matrixWorld, 0)
        const fwd = new THREE.Vector3(-Math.sin(orbit.yaw), 0, -Math.cos(orbit.yaw))
        const k = orbit.dist / 600
        orbit.target.addScaledVector(right, -dx * k).addScaledVector(fwd, dy * k)
      } else {
        orbit.yaw -= dx * 0.006
        orbit.pitch = clamp(orbit.pitch + dy * 0.006, 0.05, 1.5)
      }
    } else {
      anim = null
      walk.yaw += dx * 0.004
      walk.pitch = clamp(walk.pitch + dy * 0.004, -1.4, 1.4)
    }
  })
  const up = (e) => {
    pointers.delete(e.pointerId)
    pinch = 0
    if (downAt && Math.hypot(e.clientX - downAt.x, e.clientY - downAt.y) < 6 && performance.now() - downAt.t < 400) click(e)
    downAt = null
  }
  el.addEventListener('pointerup', up)
  el.addEventListener('pointercancel', up)
  el.addEventListener('contextmenu', (e) => e.preventDefault())
  el.addEventListener('wheel', (e) => { e.preventDefault(); zoom(Math.exp(e.deltaY * 0.001)) }, { passive: false })
  function pinchDistance() {
    const [a, b] = [...pointers.values()]
    return Math.hypot(a.x - b.x, a.y - b.y)
  }
  function zoom(f) {
    if (mode === 'dollhouse') orbit.dist = clamp(orbit.dist * f, 0.5, radius * 6)
    else walk.pos.addScaledVector(lookDir(), (1 - f) * 3)
  }
  function lookDir() {
    return new THREE.Vector3(-Math.sin(walk.yaw) * Math.cos(walk.pitch), Math.sin(walk.pitch), -Math.cos(walk.yaw) * Math.cos(walk.pitch))
  }
  const raycaster = new THREE.Raycaster()
  function click(e) {
    const r = el.getBoundingClientRect()
    raycaster.setFromCamera(new THREE.Vector2(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1), camera)
    if (mode === 'dollhouse' && layers.photos.visible) {
      const hit = raycaster.intersectObjects(pickables)[0]
      if (hit) return goToPhoto(hit.object.userData.tourIndex)
    }
    if (mode === 'dollhouse' && scanMesh) {
      // tap the floor to walk in from there
      const hit = raycaster.intersectObject(scanMesh.mesh)[0]
      if (hit && hit.point.y < floorY + 0.5) {
        walk.pos.set(hit.point.x, floorY + EYE_HEIGHT, hit.point.z)
        walk.yaw = orbit.yaw + Math.PI
        walk.pitch = 0
        setMode('walk')
      }
    }
  }
  addEventListener('keydown', (e) => { if (!e.target.closest?.('input,textarea')) keys.add(e.code) })
  addEventListener('keyup', (e) => keys.delete(e.code))

  // on-screen joystick (phones)
  ui.joystick.addEventListener('pointerdown', (e) => { ui.joystick.setPointerCapture(e.pointerId); moveJoy(e) })
  ui.joystick.addEventListener('pointermove', (e) => { if (ui.joystick.hasPointerCapture(e.pointerId)) moveJoy(e) })
  const endJoy = () => { joy.x = joy.y = 0; ui.knob.style.transform = '' }
  ui.joystick.addEventListener('pointerup', endJoy)
  ui.joystick.addEventListener('pointercancel', endJoy)
  function moveJoy(e) {
    const r = ui.joystick.getBoundingClientRect()
    let x = (e.clientX - r.left) / r.width * 2 - 1, y = (e.clientY - r.top) / r.height * 2 - 1
    const l = Math.hypot(x, y)
    if (l > 1) { x /= l; y /= l }
    joy.x = x; joy.y = y
    ui.knob.style.transform = `translate(${x * 30}px, ${y * 30}px)`
  }

  // ---- UI wiring -----------------------------------------------------------------------------
  for (const b of ui.modeButtons) b.onclick = () => setMode(b.dataset.mode)
  ui.prev.onclick = () => goToPhoto(tourIndex - 1)
  ui.next.onclick = () => goToPhoto(tourIndex + 1)
  ui.closePhoto.onclick = () => { ui.photoPanel.hidden = true }
  for (const [name, input] of Object.entries(ui.toggles)) {
    input.onchange = () => { layers[name].visible = input.checked && (name !== 'photos' || mode === 'dollhouse') }
  }
  if (!scanMesh) { ui.toggles.mesh.checked = false; ui.toggles.mesh.disabled = true }
  if (!walls.length) { ui.toggles.model.checked = false; ui.toggles.model.disabled = true }
  if (scanMesh) { ui.toggles.model.checked = false; layers.model.visible = false } // the mesh is the better default
  if (!tour.length) ui.modeButtons.find((b) => b.dataset.mode === 'tour').disabled = true
  ui.title.textContent = geo?.name || manifest.houseName || manifest.house || 'Property scan'
  ui.subtitle.textContent = [
    geo?.address,
    `${rooms.length} room${rooms.length === 1 ? '' : 's'}`,
    `${photos.length} photos`,
    geo?.latitude != null ? `${geo.latitude.toFixed(5)}, ${geo.longitude.toFixed(5)}` : '',
  ].filter(Boolean).join(' · ')
  setMode('dollhouse')

  // ---- render loop ---------------------------------------------------------------------------
  let last = performance.now()
  function frame(now) {
    const dt = Math.min(0.05, (now - last) / 1000)
    last = now
    const w = ui.stage.clientWidth, h = ui.stage.clientHeight
    if (el.width !== Math.round(w * renderer.getPixelRatio()) || el.height !== Math.round(h * renderer.getPixelRatio())) {
      renderer.setSize(w, h, false)
      camera.aspect = w / Math.max(1, h)
      camera.updateProjectionMatrix()
    }
    if (mode === 'dollhouse') {
      camera.position.set(
        orbit.target.x + orbit.dist * Math.cos(orbit.pitch) * Math.sin(orbit.yaw),
        orbit.target.y + orbit.dist * Math.sin(orbit.pitch),
        orbit.target.z + orbit.dist * Math.cos(orbit.pitch) * Math.cos(orbit.yaw))
      camera.lookAt(orbit.target)
    } else {
      if (anim) {
        const k = Math.min(1, (now - anim.t0) / anim.dur), s = k * k * (3 - 2 * k)
        walk.pos.lerpVectors(anim.from.pos, anim.to.pos, s)
        walk.yaw = anim.from.yaw + (anim.to.yaw - anim.from.yaw) * s
        walk.pitch = anim.from.pitch + (anim.to.pitch - anim.from.pitch) * s
        if (k >= 1) anim = null
      }
      const fwd = new THREE.Vector3(-Math.sin(walk.yaw), 0, -Math.cos(walk.yaw))
      const right = new THREE.Vector3(-fwd.z, 0, fwd.x)
      let f = -joy.y, r = joy.x
      if (keys.has('KeyW') || keys.has('ArrowUp')) f += 1
      if (keys.has('KeyS') || keys.has('ArrowDown')) f -= 1
      if (keys.has('KeyD')) r += 1
      if (keys.has('KeyA')) r -= 1
      if (keys.has('ArrowLeft')) walk.yaw += dt * 1.8
      if (keys.has('ArrowRight')) walk.yaw -= dt * 1.8
      if (f || r) {
        anim = null
        if (mode === 'tour') setMode('walk')
        walk.pos.addScaledVector(fwd, f * dt * 1.4).addScaledVector(right, r * dt * 1.4)
        walk.pos.y += (floorY + EYE_HEIGHT - walk.pos.y) * Math.min(1, dt * 4) // settle to eye height
      }
      camera.position.copy(walk.pos)
      camera.rotation.set(walk.pitch, walk.yaw, 0)
    }
    renderer.render(scene, camera)
    requestAnimationFrame(frame)
  }
  requestAnimationFrame(frame)

  // ---- photo-color the LiDAR mesh from the depth frames' RGB (visibility-tested) --------------
  if (scanMesh) {
    try {
      await colorMesh(THREE, scanMesh, depthFrames.length ? depthFrames : photos, depthFrames.length > 0, source, has,
        (k, n) => status(`Coloring mesh from photos… ${Math.round((k / n) * 100)}%`))
    } catch (err) {
      console.warn('mesh coloring failed', err)
    }
  }
  status('')
  return { scene, camera, setMode, goToPhoto }
}

// ---- LiDAR mesh ---------------------------------------------------------------------------------

function buildScanMesh(THREE, ply, floorY) {
  const n = ply.vertexCount
  const colors = new Float32Array(n * 3)
  const vclass = new Uint8Array(n)
  for (let f = 0; f < ply.faceCount; f++) {
    const c = ply.faceClass ? ply.faceClass[f] : 0
    for (let k = 0; k < 3; k++) vclass[ply.indices[f * 3 + k]] = c
  }
  for (let i = 0; i < n; i++) {
    const c = CLASS_COLORS[vclass[i]] || CLASS_COLORS[0]
    colors.set(c, i * 3)
  }
  const geom = new THREE.BufferGeometry()
  geom.setAttribute('position', new THREE.BufferAttribute(ply.positions, 3))
  geom.setAttribute('color', new THREE.BufferAttribute(colors, 3))
  if (ply.normals) geom.setAttribute('normal', new THREE.BufferAttribute(ply.normals, 3))
  const full = new THREE.BufferAttribute(ply.indices, 1)
  // dollhouse: drop the ceiling (and anything near it) so you can see in from above
  const cut = floorY + 2.0
  const keep = []
  const P = ply.positions, I = ply.indices
  for (let f = 0; f < ply.faceCount; f++) {
    if (ply.faceClass && ply.faceClass[f] === 3) continue
    const a = I[f * 3], b = I[f * 3 + 1], c = I[f * 3 + 2]
    if ((P[a * 3 + 1] + P[b * 3 + 1] + P[c * 3 + 1]) / 3 > cut) continue
    keep.push(a, b, c)
  }
  const dollhouse = new THREE.BufferAttribute(new Uint32Array(keep), 1)
  geom.setIndex(dollhouse)
  geom.computeBoundingSphere()
  if (!ply.normals) geom.computeVertexNormals()
  const mesh = new THREE.Mesh(geom, new THREE.MeshBasicMaterial({ vertexColors: true, side: THREE.DoubleSide }))
  return {
    mesh, ply, colors, geom,
    setDollhouse(on) { geom.setIndex(on ? dollhouse : full) },
  }
}

async function colorMesh(THREE, scan, views, withDepth, source, has, progress) {
  const { ply, colors, geom } = scan
  const P = ply.positions
  const N = geom.getAttribute('normal').array
  const n = ply.vertexCount
  const best = new Float32Array(n)
  // spatial chunks (ARKit mesh anchors are local, so consecutive vertices are near each other)
  const CH = 2048, chunks = []
  for (let s = 0; s < n; s += CH) {
    const e = Math.min(n, s + CH)
    let cx = 0, cy = 0, cz = 0
    for (let i = s; i < e; i++) { cx += P[i * 3]; cy += P[i * 3 + 1]; cz += P[i * 3 + 2] }
    cx /= e - s; cy /= e - s; cz /= e - s
    let r = 0
    for (let i = s; i < e; i++) r = Math.max(r, Math.hypot(P[i * 3] - cx, P[i * 3 + 1] - cy, P[i * 3 + 2] - cz))
    chunks.push({ s, e, cx, cy, cz, r })
  }
  const step = Math.max(1, Math.ceil(views.length / MAX_COLOR_VIEWS))
  const picked = views.filter((_, i) => i % step === 0).filter((v) => has.has(withDepth ? v.rgb : v.file) && (!withDepth || has.has(v.file)))
  const canvas = document.createElement('canvas')
  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  const inv = new THREE.Matrix4()
  const colorAttr = geom.getAttribute('color')
  const maxDepth = 4.5
  for (let vi = 0; vi < picked.length; vi++) {
    const v = picked[vi]
    progress(vi, picked.length)
    // color image
    const bmp = await createImageBitmap(new Blob([await source.read(withDepth ? v.rgb : v.file)], { type: 'image/jpeg' }), { imageOrientation: 'none' })
    const scale = withDepth ? 1 : Math.min(1, 1024 / Math.max(bmp.width, bmp.height))
    const W = Math.round(bmp.width * scale), H = Math.round(bmp.height * scale)
    canvas.width = W; canvas.height = H
    ctx.drawImage(bmp, 0, 0, W, H)
    bmp.close?.()
    const rgb = ctx.getImageData(0, 0, W, H).data
    const K = withDepth ? v.rgbIntrinsics : v.intrinsics
    const kScale = withDepth ? 1 : W / v.width
    const fx = K[0] * kScale, fy = K[4] * kScale, cxp = K[6] * kScale, cyp = K[7] * kScale
    // depth for visibility
    let depth = null, conf = null, dfx, dfy, dcx, dcy, dw, dh
    if (withDepth) {
      let raw = await source.read(v.file)
      if (v.file.endsWith('.f16z')) raw = await inflateRaw(raw)
      depth = new Uint16Array(raw.slice(0, v.width * v.height * 2))
      if (v.confidence && has.has(v.confidence)) conf = new Uint8Array(await source.read(v.confidence))
      ;[dfx, dfy, dcx, dcy] = [v.intrinsics[0], v.intrinsics[4], v.intrinsics[6], v.intrinsics[7]]
      dw = v.width; dh = v.height
    }
    const T = v.transform
    inv.fromArray(T).invert()
    const e = inv.elements
    const ox = T[12], oy = T[13], oz = T[14]
    const fwx = -T[8], fwy = -T[9], fwz = -T[10]
    for (const c of chunks) {
      const dx = c.cx - ox, dy = c.cy - oy, dz = c.cz - oz
      const along = dx * fwx + dy * fwy + dz * fwz
      if (along < -c.r || Math.hypot(dx, dy, dz) - c.r > maxDepth) continue
      for (let i = c.s; i < c.e; i++) {
        const px = P[i * 3], py = P[i * 3 + 1], pz = P[i * 3 + 2]
        const z = -(e[2] * px + e[6] * py + e[10] * pz + e[14])
        if (z < 0.15 || z > maxDepth) continue
        const x = e[0] * px + e[4] * py + e[8] * pz + e[12]
        const y = e[1] * px + e[5] * py + e[9] * pz + e[13]
        const u = fx * x / z + cxp, w = -fy * y / z + cyp
        if (u < 1 || w < 1 || u >= W - 1 || w >= H - 1) continue
        // facing: vertex normal vs direction to camera
        let vx = ox - px, vy = oy - py, vz = oz - pz
        const vl = Math.hypot(vx, vy, vz)
        vx /= vl; vy /= vl; vz /= vl
        const facing = Math.abs(N[i * 3] * vx + N[i * 3 + 1] * vy + N[i * 3 + 2] * vz)
        if (facing < 0.15) continue
        const ru = (u - W / 2) / (W / 2), rw = (w - H / 2) / (H / 2)
        const score = facing / (z * z) * (1 - 0.35 * (ru * ru + rw * rw))
        if (score <= best[i]) continue
        if (depth) {
          const du = Math.round(dfx * x / z + dcx), dv = Math.round(-dfy * y / z + dcy)
          if (du < 0 || dv < 0 || du >= dw || dv >= dh) continue
          const di = dv * dw + du
          if (conf && conf[di] < 1) continue
          const d = HALF[depth[di]]
          if (!(d > 0) || Math.abs(d - z) > 0.05 + 0.03 * z) continue
        }
        best[i] = score
        const pi = ((w | 0) * W + (u | 0)) * 4
        colors[i * 3] = srgbToLinear(rgb[pi]); colors[i * 3 + 1] = srgbToLinear(rgb[pi + 1]); colors[i * 3 + 2] = srgbToLinear(rgb[pi + 2])
      }
    }
    if (vi % 8 === 7) colorAttr.needsUpdate = true
    await new Promise((r) => setTimeout(r))
  }
  colorAttr.needsUpdate = true
}

const SRGB = new Float32Array(256).map((_, i) => { const c = i / 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4 })
const srgbToLinear = (v) => SRGB[v]
const HALF = (() => {
  const t = new Float32Array(65536)
  for (let h = 0; h < 65536; h++) {
    const s = h & 0x8000 ? -1 : 1, ex = (h >> 10) & 0x1f, f = h & 0x3ff
    t[h] = ex === 0 ? s * 2 ** -14 * (f / 1024) : ex === 31 ? (f ? NaN : s * Infinity) : s * 2 ** (ex - 15) * (1 + f / 1024)
  }
  return t
})()

async function inflateRaw(buf) {
  const stream = new Blob([buf]).stream().pipeThrough(new DecompressionStream('deflate-raw'))
  return new Response(stream).arrayBuffer()
}

// ---- PLY (binary little endian or ascii) -------------------------------------------------------

export function parsePLY(buffer) {
  const bytes = new Uint8Array(buffer)
  const marker = 'end_header'
  let headerEnd = -1
  for (let i = 0; i < Math.min(bytes.length, 65536); i++) {
    if (bytes[i] === 101 && String.fromCharCode(...bytes.subarray(i, i + marker.length)) === marker) { headerEnd = i + marker.length; break }
  }
  if (headerEnd < 0) throw new Error('PLY: no end_header')
  while (bytes[headerEnd] === 13 || bytes[headerEnd] === 10) { headerEnd++; if (bytes[headerEnd - 1] === 10) break }
  const header = new TextDecoder().decode(bytes.subarray(0, headerEnd)).split(/\r?\n/)
  const SIZES = { char: 1, uchar: 1, int8: 1, uint8: 1, short: 2, ushort: 2, int16: 2, uint16: 2, int: 4, uint: 4, int32: 4, uint32: 4, float: 4, float32: 4, double: 8, float64: 8 }
  let format = 'ascii'
  const elements = []
  for (const line of header) {
    const p = line.trim().split(/\s+/)
    if (p[0] === 'format') format = p[1]
    else if (p[0] === 'element') elements.push({ name: p[1], count: +p[2], props: [] })
    else if (p[0] === 'property') {
      const el = elements[elements.length - 1]
      if (p[1] === 'list') el.props.push({ name: p[4], list: true, countType: p[2], type: p[3] })
      else el.props.push({ name: p[2], type: p[1] })
    }
  }
  if (format !== 'binary_little_endian' && format !== 'ascii') throw new Error(`PLY: unsupported format ${format}`)
  const vEl = elements.find((e) => e.name === 'vertex'), fEl = elements.find((e) => e.name === 'face')
  const vertexCount = vEl?.count || 0, faceCount = fEl?.count || 0
  const positions = new Float32Array(vertexCount * 3)
  const hasNormals = vEl?.props.some((p) => p.name === 'nx')
  const normals = hasNormals ? new Float32Array(vertexCount * 3) : null
  const indices = []
  const faceClass = fEl?.props.some((p) => p.name === 'class') ? new Uint8Array(faceCount) : null
  const target = { x: [positions, 0], y: [positions, 1], z: [positions, 2], nx: [normals, 0], ny: [normals, 1], nz: [normals, 2] }

  if (format === 'ascii') {
    const tokens = new TextDecoder().decode(bytes.subarray(headerEnd)).trim().split(/\s+/).map(Number)
    let t = 0
    for (const el of elements) {
      for (let i = 0; i < el.count; i++) {
        for (const p of el.props) {
          if (p.list) {
            const k = tokens[t++]
            const list = tokens.slice(t, t + k); t += k
            if (el === fEl) for (let j = 1; j + 1 < list.length; j++) indices.push(list[0], list[j], list[j + 1])
          } else {
            const val = tokens[t++]
            if (el === vEl && target[p.name]?.[0]) target[p.name][0][i * 3 + target[p.name][1]] = val
            if (el === fEl && p.name === 'class' && faceClass) faceClass[i] = val
          }
        }
      }
    }
  } else {
    const dv = new DataView(buffer, headerEnd)
    let o = 0
    const read = (type) => {
      let v
      switch (type) {
        case 'char': case 'int8': v = dv.getInt8(o); break
        case 'uchar': case 'uint8': v = dv.getUint8(o); break
        case 'short': case 'int16': v = dv.getInt16(o, true); break
        case 'ushort': case 'uint16': v = dv.getUint16(o, true); break
        case 'int': case 'int32': v = dv.getInt32(o, true); break
        case 'uint': case 'uint32': v = dv.getUint32(o, true); break
        case 'float': case 'float32': v = dv.getFloat32(o, true); break
        default: v = dv.getFloat64(o, true)
      }
      o += SIZES[type]
      return v
    }
    for (const el of elements) {
      // fast path: fixed-size vertex records
      for (let i = 0; i < el.count; i++) {
        for (const p of el.props) {
          if (p.list) {
            const k = read(p.countType)
            if (el === fEl && k === 3) indices.push(read(p.type), read(p.type), read(p.type))
            else {
              const list = []
              for (let j = 0; j < k; j++) list.push(read(p.type))
              if (el === fEl) for (let j = 1; j + 1 < list.length; j++) indices.push(list[0], list[j], list[j + 1])
            }
          } else {
            const val = read(p.type)
            if (el === vEl) { const tg = target[p.name]; if (tg && tg[0]) tg[0][i * 3 + tg[1]] = val }
            else if (el === fEl && p.name === 'class' && faceClass) faceClass[i] = val
          }
        }
      }
    }
  }
  return { vertexCount, faceCount: indices.length / 3, positions, normals, indices: new Uint32Array(indices), faceClass }
}

// ---- small helpers -------------------------------------------------------------------------------

const clamp = (v, a, b) => Math.max(a, Math.min(b, v))
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])
function percentile(arr, q) {
  const a = Float32Array.from(arr).sort()
  return a.length ? a[Math.floor(q * (a.length - 1))] : 0
}

function textSprite(THREE, text) {
  const c = document.createElement('canvas')
  const ctx = c.getContext('2d')
  ctx.font = '600 28px system-ui, sans-serif'
  c.width = Math.ceil(ctx.measureText(text).width) + 20; c.height = 40
  ctx.font = '600 28px system-ui, sans-serif'
  ctx.fillStyle = 'rgba(0,0,0,.55)'; ctx.fillRect(0, 0, c.width, c.height)
  ctx.fillStyle = '#ffd59a'; ctx.fillText(text, 10, 29)
  const tex = new THREE.CanvasTexture(c)
  tex.colorSpace = THREE.SRGBColorSpace
  const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: tex, depthTest: false }))
  s.scale.set(c.width / 200, c.height / 200, 1)
  return s
}

function buildUI(container) {
  const style = document.createElement('style')
  style.textContent = `
  .wt{position:relative;width:100%;height:100%;overflow:hidden;font:14px/1.35 system-ui,-apple-system,sans-serif;color:#eef0f4;background:#15171c;touch-action:none;user-select:none}
  .wt-stage,.wt-stage canvas{position:absolute;inset:0;width:100%;height:100%;display:block}
  .wt-top{position:absolute;left:12px;right:12px;top:12px;display:flex;flex-wrap:wrap;gap:8px;align-items:flex-start;pointer-events:none}
  .wt-card{background:rgba(20,22,28,.78);backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);border:1px solid rgba(255,255,255,.08);border-radius:12px;padding:8px 12px;pointer-events:auto}
  .wt-title{font-weight:650;font-size:15px}.wt-sub{opacity:.7;font-size:12px}
  .wt-modes{display:flex;gap:4px;margin-left:auto}
  .wt button{font:inherit;color:inherit;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.12);border-radius:9px;padding:7px 12px;cursor:pointer;min-height:36px;white-space:nowrap}
  .wt button.on{background:#ff4f9a;border-color:#ff4f9a;color:#fff}.wt button:disabled{opacity:.35;cursor:default}
  .wt-layers{position:absolute;left:12px;bottom:12px;display:flex;flex-wrap:wrap;gap:10px;font-size:12px}
  .wt-layers label{display:flex;gap:5px;align-items:center}
  .wt-status{position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);pointer-events:none}
  .wt-status:not([hidden]){display:block}
  .wt-photo{position:absolute;right:12px;bottom:12px;width:min(300px,42vw);padding:8px}
  .wt-photo img{display:block;width:100%;border-radius:8px;background:#000;min-height:80px}
  .wt-photo .row{display:flex;gap:6px;align-items:center;margin-top:6px}.wt-photo .meta{font-size:12px;opacity:.85;margin-top:6px;word-break:break-word}
  .wt-photo .meta a{color:#9fd2ff}.wt-photo .count{margin:0 auto;font-variant-numeric:tabular-nums;white-space:nowrap}
  .wt-joy{position:absolute;left:24px;bottom:56px;width:96px;height:96px;border-radius:50%;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.18);display:none;touch-action:none}
  .wt-knob{position:absolute;left:33px;top:33px;width:30px;height:30px;border-radius:50%;background:rgba(255,255,255,.5);pointer-events:none}
  .wt[data-mode=walk] .wt-joy,.wt[data-mode=tour] .wt-joy{display:block}
  .wt-help{font-size:11px;opacity:.6}
  @media (hover:hover){.wt-joy{opacity:.5}}
  .wt-photo img{max-height:52vh;object-fit:contain}
  @media (max-width:600px){
    .wt-modes{margin-left:0}.wt-help{display:none}
    .wt-layers{gap:8px;font-size:11px;padding:6px 10px}
    .wt-joy{bottom:64px}
    .wt-photo{width:46vw;bottom:64px;padding:6px}.wt-photo img{max-height:30vh}
    .wt-photo .meta{font-size:10px}.wt-photo .row button{padding:4px 8px;min-height:30px}.wt-photo .count{font-size:11px}
  }`
  const root = document.createElement('div')
  root.className = 'wt'
  root.innerHTML = `
    <div class="wt-stage"></div>
    <div class="wt-top">
      <div class="wt-card"><div class="wt-title"></div><div class="wt-sub"></div></div>
      <div class="wt-card wt-modes">
        <button data-mode="dollhouse">Dollhouse</button><button data-mode="walk">Walk</button><button data-mode="tour">Photo tour</button>
      </div>
    </div>
    <div class="wt-card wt-status" hidden></div>
    <div class="wt-card wt-layers">
      <label><input type="checkbox" data-layer="mesh" checked>Scan</label>
      <label><input type="checkbox" data-layer="model" checked>Walls</label>
      <label><input type="checkbox" data-layer="furniture" checked>Furniture</label>
      <label><input type="checkbox" data-layer="photos" checked>Photos</label>
      <span class="wt-help">Drag to look · WASD / joystick to walk · tap a pink dot or the floor</span>
    </div>
    <div class="wt-joy"><div class="wt-knob"></div></div>
    <div class="wt-card wt-photo" hidden>
      <img alt="Photo taken at this spot">
      <div class="meta"></div>
      <div class="row"><button data-act="prev">‹ Prev</button><span class="count"></span><button data-act="next">Next ›</button><button data-act="close">✕</button></div>
    </div>`
  container.append(style, root)
  const q = (s) => root.querySelector(s)
  return {
    root, stage: q('.wt-stage'), status: q('.wt-status'), title: q('.wt-title'), subtitle: q('.wt-sub'),
    modeButtons: [...root.querySelectorAll('[data-mode]')],
    toggles: Object.fromEntries([...root.querySelectorAll('[data-layer]')].map((i) => [i.dataset.layer, i])),
    photoPanel: q('.wt-photo'), photoImg: q('.wt-photo img'), photoMeta: q('.wt-photo .meta'), photoCounter: q('.wt-photo .count'),
    prev: q('[data-act=prev]'), next: q('[data-act=next]'), closePhoto: q('[data-act=close]'),
    joystick: q('.wt-joy'), knob: q('.wt-knob'),
  }
}
