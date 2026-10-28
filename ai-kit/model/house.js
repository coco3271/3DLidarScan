// Clean, measured 3D model of a scanned property — the "architectural dollhouse" look:
// thick cut-away walls, framed doors and windows, baseboards, textured floors, furniture built
// from parts, soft shadows + ambient occlusion + environment light, on a blueprint grid.
//
//   startModel(THREE, container, source)   source = { files: string[], read(path) -> ArrayBuffer }
//
// Everything comes from model.json (written by make_model.py, then refined by hand or by an AI):
//
//   { name, subtitle,
//     style:  { background, grid, wallColor, wallThickness, baseboard },
//     rooms:  [{ name, polygon: [[x,z]...], floor: "<material name>" | "#hex", label: true }],
//     walls:  [{ a:[x,z], b:[x,z], height, thickness?, color?, n?:[nx,nz] (into the room),
//                centered? (true: the wall straddles a–b, e.g. between two rooms; else it sits
//                outside the room, behind the measured interior face),
//                openings: [{ kind: "door"|"window"|"opening", u0, u1, v0, v1, open? }] }],
//     items:  [{ type, center:[x,y,z], size:[w,h,d], rotY, color?, colors?:{}, label?, parts? }],
//     materials: { name: { color?, map?: "textures/x.jpg", tile?: meters, roughness? } },
//     photos: [{ file, transform (col-major 4x4, model frame), width, height, fx }] }
//
// Units are meters, +Y up, floor at y = 0. Item size is [width (x), height (y), depth (z)] in the
// item's own frame, centered on `center`; `rotY` turns its +z (its front) around +Y.
// Wall u runs from a to b; v is height above the floor; n points into the room. Wall ends are
// extended automatically into the walls they meet, so corners close.

const GRID_BG = '#0b1626'

/** How the phone was held when a photo was taken, from its pose (the same rule as the app's EXIF
 *  orientation): `right`/`up` = how much the sensor's x / y axes point up in the world. Returns
 *  the roll that turns the sensor camera upright, and whether the picture is portrait. */
function photoHold(right, up) {
  if (Math.abs(up) >= Math.abs(right)) return { roll: up >= 0 ? 0 : Math.PI, portrait: false } // sideways (landscape)
  return { roll: right < 0 ? Math.PI / 2 : -Math.PI / 2, portrait: true }                       // upright (portrait)
}

export async function startModel(THREE, container, source) {
  const ui = buildUI(container)
  const text = async (p) => new TextDecoder().decode(await source.read(p))
  const has = new Set(source.files)
  const spec = JSON.parse(await text('model.json'))
  const style = { background: GRID_BG, grid: true, wallColor: '#eceae4', wallThickness: 0.12, baseboard: true, ...(spec.style || {}) }

  // ---- renderer: tone mapping, soft shadows, environment light, ambient occlusion --------------
  const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true })
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2))
  renderer.outputColorSpace = THREE.SRGBColorSpace
  renderer.toneMapping = THREE.ACESFilmicToneMapping
  renderer.toneMappingExposure = 1.0
  renderer.shadowMap.enabled = true
  renderer.shadowMap.type = THREE.PCFSoftShadowMap
  ui.stage.appendChild(renderer.domElement)

  const scene = new THREE.Scene()
  scene.background = new THREE.Color(style.background)
  const pmrem = new THREE.PMREMGenerator(renderer)
  scene.environment = pmrem.fromScene(new THREE.RoomEnvironment(), 0.04).texture
  scene.environmentIntensity = 0.55
  scene.add(new THREE.HemisphereLight(0xfff4e6, 0x3a4252, 0.6))

  const camera = new THREE.PerspectiveCamera(40, 1, 0.05, 400)
  const house = new THREE.Group()
  scene.add(house)

  // ---- materials ---------------------------------------------------------------------------------
  const texLoader = new THREE.TextureLoader()
  const matCache = new Map()
  const textures = new Map()
  async function loadTexture(path) {
    if (textures.has(path)) return textures.get(path)
    let tex = null
    if (has.has(path)) {
      const url = URL.createObjectURL(new Blob([await source.read(path)], { type: 'image/jpeg' }))
      tex = await texLoader.loadAsync(url)
      tex.colorSpace = THREE.SRGBColorSpace
      tex.wrapS = tex.wrapT = THREE.MirroredRepeatWrapping
      tex.anisotropy = renderer.capabilities.getMaxAnisotropy()
    }
    textures.set(path, tex)
    return tex
  }
  for (const m of Object.values(spec.materials || {})) if (m.map) await loadTexture(m.map)

  /** A material from a "#hex" color or a named entry in spec.materials */
  function material(ref, opts = {}) {
    const key = JSON.stringify([ref, opts])
    if (matCache.has(key)) return matCache.get(key)
    const named = typeof ref === 'string' && !ref.startsWith('#') ? spec.materials?.[ref] : null
    const color = named?.color || (typeof ref === 'string' && ref.startsWith('#') ? ref : opts.color || '#cccccc')
    const m = new THREE.MeshStandardMaterial({
      color: named?.map ? '#ffffff' : color,
      roughness: named?.roughness ?? opts.roughness ?? 0.8,
      metalness: opts.metalness ?? 0,
      transparent: opts.opacity != null && opts.opacity < 1,
      opacity: opts.opacity ?? 1,
      emissive: opts.emissive || '#000000',
      side: opts.side ?? THREE.FrontSide,
    })
    if (named?.map) {
      const t = textures.get(named.map)
      if (t) {
        m.map = t.clone()
        m.map.needsUpdate = true
        const tile = named.tile || 1
        m.map.repeat.set(1 / tile, 1 / tile)
      } else m.color.set(named.color || color)
    }
    matCache.set(key, m)
    return m
  }
  const C = (c, fallback) => (typeof c === 'string' && c ? c : fallback)

  // ---- architecture -----------------------------------------------------------------------------
  const trimMat = material('#f6f5f1', { roughness: 0.6 })
  const glassMat = material('#bcd8ea', { opacity: 0.28, roughness: 0.05, metalness: 0.1, side: THREE.DoubleSide })
  const doorMat = material('#f2f0ea', { roughness: 0.55 })
  const handleMat = material('#b9b2a5', { roughness: 0.3, metalness: 0.8 })

  for (const room of spec.rooms || []) {
    if (!room.polygon || room.polygon.length < 3) continue
    const shape = new THREE.Shape(room.polygon.map(([x, z]) => new THREE.Vector2(x, -z)))
    const slab = new THREE.ExtrudeGeometry(shape, { depth: 0.12, bevelEnabled: false })
    slab.rotateX(-Math.PI / 2) // shape xy → world x,-z ; extrusion goes up: move it down below 0
    slab.translate(0, -0.12, 0)
    const floor = new THREE.Mesh(slab, [material(room.floor || '#c9b79c', { roughness: 0.7 }), material('#d9d6cf')])
    floor.receiveShadow = true
    house.add(floor)
  }

  // ceilings face down only, so the dollhouse (seen from above) has none and Walk/Photos do
  const heights = (spec.walls || []).map((w) => w.height || 2.6).sort((p, q) => p - q)
  const ceilingH = heights.length ? heights[heights.length >> 1] : 2.6
  const ceilingMat = material('#f5f4f0', { roughness: 0.95, emissive: '#4a4945' })
  for (const room of spec.rooms || []) {
    if (!room.polygon || room.polygon.length < 3) continue
    const geo = new THREE.ShapeGeometry(new THREE.Shape(room.polygon.map(([x, z]) => new THREE.Vector2(x, z))))
    geo.rotateX(Math.PI / 2) // shape (x, z) → world (x, z), facing down
    const c = new THREE.Mesh(geo, ceilingMat)
    c.position.y = room.height || ceilingH
    c.receiveShadow = true
    c.castShadow = false
    house.add(c)
  }

  const CUT = 0.3 // height of cut-away walls
  const cutaways = []
  const walls = (spec.walls || []).map((w) => wallFrame(w)).filter(Boolean)
  joinCorners(walls)
  for (const w of walls) addWall(w)

  /** a wall's measured line, height and interior normal; solid spans [lo, hi] along n */
  function wallFrame(w) {
    const a = new THREE.Vector2(...w.a), b = new THREE.Vector2(...w.b)
    const L = a.distanceTo(b)
    if (L < 0.05) return null
    const T = w.thickness ?? style.wallThickness
    const u = new THREE.Vector3(b.x - a.x, 0, b.y - a.y).normalize()
    const n = w.n ? new THREE.Vector3(w.n[0], 0, w.n[1]).normalize() : new THREE.Vector3(-u.z, 0, u.x)
    // keep the frame right-handed: u × up = n
    if (new THREE.Vector3().crossVectors(u, new THREE.Vector3(0, 1, 0)).dot(n) < 0) n.negate()
    // `centered` walls (between two rooms) straddle their line; others sit outside the room
    const lo = w.centered ? -T / 2 : -T, hi = w.centered ? T / 2 : 0
    return { w, a, L, T, u, n, lo, hi, H: w.height || 2.6, ext: [0, 0] }
  }

  /** Extend each wall end into the wall it meets, so corners close without notches or gaps */
  function joinCorners(list) {
    for (const A of list) for (const end of [0, 1]) {
      const P = end ? new THREE.Vector3(A.a.x, 0, A.a.y).addScaledVector(A.u, A.L) : new THREE.Vector3(A.a.x, 0, A.a.y)
      const d = A.u.clone().multiplyScalar(end ? 1 : -1) // pointing past this end
      let best = 0
      for (const B of list) {
        if (B === A) continue
        const dn = d.dot(B.n)
        if (Math.abs(dn) < 0.7) continue // only walls running across this one
        const rel = P.clone().sub(new THREE.Vector3(B.a.x, 0, B.a.y))
        const along = rel.dot(B.u), off = rel.dot(B.n)
        if (along < -0.4 || along > B.L + 0.4 || off < B.lo - 0.4 || off > B.hi + 0.4) continue
        // reach B's far face (the one d points toward), never backwards
        for (const o of [B.lo, B.hi]) {
          const e = (o - off) / dn
          if (e > best && e < 0.6) best = e
        }
      }
      A.ext[end] = best
    }
  }

  function addWall(F) {
    const { w, a, L, T, u, n, lo, H } = F
    const [e0, e1] = F.ext
    const S = 0.12 // walls run down to the bottom of the floor slab
    const eps = 0.02
    const ops = (w.openings || []).map((o) => ({ ...o, v0: o.v0 || 0, u0: Math.max(eps, o.u0), u1: Math.min(L - eps, o.u1), v1: Math.min(H - 0.05, o.v1) }))
      .filter((o) => o.u1 - o.u0 > 0.1 && o.v1 - o.v0 > 0.1).sort((p, q) => p.u0 - q.u0)
    const shape = new THREE.Shape()
    shape.moveTo(-e0, -S); shape.lineTo(L + e1, -S); shape.lineTo(L + e1, H); shape.lineTo(-e0, H); shape.lineTo(-e0, -S)
    for (const o of ops) {
      const hole = new THREE.Path()
      hole.moveTo(o.u0, o.v0); hole.lineTo(o.u0, o.v1); hole.lineTo(o.u1, o.v1); hole.lineTo(o.u1, o.v0)
      shape.holes.push(hole)
    }
    const geo = new THREE.ExtrudeGeometry(shape, { depth: T, bevelEnabled: false })
    // local z = n: the solid spans lo..lo+T; z = 0 is the interior face of an outer wall
    geo.translate(0, 0, lo)
    const frame = new THREE.Matrix4().makeBasis(u, new THREE.Vector3(0, 1, 0), n).setPosition(a.x, 0, a.y)
    const wallGroup = new THREE.Group()
    wallGroup.applyMatrix4(frame)
    const mesh = new THREE.Mesh(geo, material(w.color || style.wallColor, { roughness: 0.92 }))
    mesh.castShadow = mesh.receiveShadow = true
    wallGroup.add(mesh)
    // the faces that get trim: the room side, and for centered walls both sides
    const faces = w.centered ? [[lo + T, 1], [lo, -1]] : [[0, 1]]
    if (style.baseboard) {
      const floorOps = ops.filter((o) => o.v0 < 0.03)
      for (const [z, s] of faces) {
        let start = 0
        for (const o of [...floorOps, { u0: L, u1: L }]) {
          if (o.u0 - start > 0.05) wallGroup.add(box(o.u0 - start, 0.08, 0.014, trimMat, start + (o.u0 - start) / 2, 0.04, z + s * 0.007))
          start = o.u1
        }
      }
    }
    for (const o of ops) addOpening(wallGroup, o, T, lo, faces)
    house.add(wallGroup)
    // dollhouse cut-away: a low stub shown instead when the camera is outside this wall
    if (!w.centered) {
      const stub = new THREE.Group()
      stub.applyMatrix4(frame)
      let start = -e0
      for (const o of [...ops.filter((o) => o.v0 < 0.03), { u0: L + e1, u1: L + e1 }]) {
        const len = o.u0 - start
        if (len > 0.02) {
          const m = new THREE.Mesh(new THREE.BoxGeometry(len, CUT + S, T), mesh.material)
          m.position.set(start + len / 2, (CUT - S) / 2, lo + T / 2)
          m.castShadow = m.receiveShadow = true
          stub.add(m)
        }
        start = o.u1
      }
      stub.visible = false
      wallGroup.userData.wall = true
      house.add(stub)
      cutaways.push({ full: wallGroup, stub, mid: new THREE.Vector3(a.x, 0, a.y).addScaledVector(u, L / 2), n })
    }
  }

  function addOpening(g, o, T, lo, faces) {
    const w = o.u1 - o.u0, v0 = o.v0, h = o.v1 - v0, cx = (o.u0 + o.u1) / 2
    const t = 0.05, depth = T + 0.02, mid = lo + T / 2
    if (o.kind === 'window') {
      // frame, sill (on the room side), mullion, glass
      g.add(box(w + 0.1, t, depth, trimMat, cx, o.v1 + t / 2, mid))
      g.add(box(w + 0.16, 0.035, depth + 0.06, trimMat, cx, v0 - 0.018, mid + 0.03))
      g.add(box(t, h, depth, trimMat, o.u0 - t / 2, v0 + h / 2, mid))
      g.add(box(t, h, depth, trimMat, o.u1 + t / 2, v0 + h / 2, mid))
      g.add(box(0.03, h, 0.04, trimMat, cx, v0 + h / 2, mid))
      g.add(box(w, h, 0.01, glassMat, cx, v0 + h / 2, mid, false))
      return
    }
    // door casing around the opening on each trimmed face
    for (const [z, s] of faces) {
      const cz = z + s * 0.01
      g.add(box(w + 0.14, 0.07, 0.02, trimMat, cx, o.v1 + 0.035, cz))
      g.add(box(0.07, h, 0.02, trimMat, o.u0 - 0.035, v0 + h / 2, cz))
      g.add(box(0.07, h, 0.02, trimMat, o.u1 + 0.035, v0 + h / 2, cz))
    }
    if (o.kind !== 'door') return
    // the door leaf: closed, or swung into the room
    const leaf = new THREE.Group()
    leaf.add(box(w - 0.01, h - 0.01, 0.04, doorMat, (w - 0.01) / 2, h / 2, 0))
    for (const y of [0.3, 0.7]) for (const s of [1, -1]) leaf.add(box(w * 0.7, h * 0.32, 0.006, trimMat, (w - 0.01) / 2, h * y, s * 0.023, false))
    for (const s of [1, -1]) leaf.add(box(0.12, 0.02, 0.05, handleMat, w - 0.1, 1.0, s * 0.04))
    leaf.position.set(o.u0, v0, mid)
    if (o.open) leaf.rotation.y = -1.3
    g.add(leaf)
  }

  function box(w, h, d, mat, x, y, z, shadows = true) {
    const m = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), mat)
    m.position.set(x, y, z)
    m.castShadow = m.receiveShadow = shadows
    return m
  }

  // ---- furniture --------------------------------------------------------------------------------
  const builders = makeBuilders(THREE, material, C)
  for (const item of spec.items || []) {
    const build = builders[item.type] || builders.box
    const g = new THREE.Group()
    try { build(g, item) } catch (e) { console.warn('item failed', item, e); builders.box(g, item) }
    const s = item.size || [0.5, 0.5, 0.5]
    g.position.set(item.center[0], item.center[1] - s[1] / 2, item.center[2]) // builders work from the floor up
    g.rotation.y = item.rotY || 0
    g.traverse((o) => { if (o.isMesh) { o.castShadow = o.castShadow !== false; o.receiveShadow = true } })
    g.userData.item = item
    house.add(g)
  }

  // ---- lights fitted to the house ---------------------------------------------------------------
  const bounds = new THREE.Box3().setFromObject(house)
  if (bounds.isEmpty()) bounds.set(new THREE.Vector3(-3, 0, -3), new THREE.Vector3(3, 2.6, 3))
  const center = bounds.getCenter(new THREE.Vector3())
  const size = bounds.getSize(new THREE.Vector3())
  const radius = Math.max(3, Math.hypot(size.x, size.z) / 2)
  const sun = new THREE.DirectionalLight(0xfff1dd, 2.2)
  sun.position.set(center.x + radius * 0.5, radius * 2.2, center.z + radius * 0.8)
  sun.target.position.copy(center)
  sun.castShadow = true
  const mobile = /Mobi|Android|iPhone|iPad/.test(navigator.userAgent)
  sun.shadow.mapSize.setScalar(mobile ? 2048 : 4096)
  sun.shadow.bias = -0.0004
  sun.shadow.normalBias = 0.02
  sun.shadow.radius = 4
  const sc = sun.shadow.camera
  sc.left = sc.bottom = -radius * 1.3; sc.right = sc.top = radius * 1.3; sc.near = 0.5; sc.far = radius * 6
  scene.add(sun, sun.target)
  // interior fill so rooms aren't dark under the walls' shadows
  const fill = new THREE.DirectionalLight(0xdfe8ff, 0.5)
  fill.position.set(center.x - radius, radius, center.z - radius * 0.6)
  scene.add(fill)

  // blueprint grid ground
  if (style.grid) {
    const c = document.createElement('canvas'); c.width = c.height = 512
    const g = c.getContext('2d')
    g.fillStyle = style.background; g.fillRect(0, 0, 512, 512)
    g.strokeStyle = 'rgba(120,160,210,0.16)'; g.lineWidth = 1
    for (let i = 0; i <= 512; i += 32) { g.beginPath(); g.moveTo(i + 0.5, 0); g.lineTo(i + 0.5, 512); g.stroke(); g.beginPath(); g.moveTo(0, i + 0.5); g.lineTo(512, i + 0.5); g.stroke() }
    g.strokeStyle = 'rgba(140,180,230,0.32)'; g.lineWidth = 2; g.strokeRect(1, 1, 510, 510)
    const tex = new THREE.CanvasTexture(c)
    tex.wrapS = tex.wrapT = THREE.RepeatWrapping
    tex.colorSpace = THREE.SRGBColorSpace
    const extent = radius * 12
    tex.repeat.set(extent / 4, extent / 4) // 4 m per tile, 0.5 m minor lines
    const ground = new THREE.Mesh(new THREE.PlaneGeometry(extent, extent), new THREE.MeshBasicMaterial({ map: tex, toneMapped: false }))
    ground.rotation.x = -Math.PI / 2
    ground.position.set(center.x, -0.13, center.z)
    scene.add(ground)
    const shadowCatcher = new THREE.Mesh(new THREE.PlaneGeometry(extent, extent), new THREE.ShadowMaterial({ opacity: 0.35 }))
    shadowCatcher.rotation.x = -Math.PI / 2
    shadowCatcher.position.set(center.x, -0.125, center.z)
    shadowCatcher.receiveShadow = true
    scene.add(shadowCatcher)
  }

  // ---- post-processing: ambient occlusion -------------------------------------------------------
  const composer = new THREE.EffectComposer(renderer)
  composer.addPass(new THREE.RenderPass(scene, camera))
  const ao = new THREE.GTAOPass(scene, camera, 1, 1)
  ao.updateGtaoMaterial({ radius: 0.35, distanceExponent: 1.5, thickness: 1, scale: 1.2, samples: 16 })
  ao.blendIntensity = 0.85
  composer.addPass(ao)
  composer.addPass(new THREE.OutputPass())
  let quality = !mobile
  ui.toggles.quality.checked = quality
  ui.toggles.quality.onchange = () => { quality = ui.toggles.quality.checked }

  // ---- labels --------------------------------------------------------------------------------------
  const labels = (spec.rooms || []).filter((r) => r.polygon?.length >= 3 && r.label !== false).map((r) => {
    const el = document.createElement('div')
    el.className = 'hm-label'
    const area = polyArea(r.polygon)
    el.innerHTML = `<b>${esc(r.name || 'Room')}</b><span>${area.toFixed(1)} m²</span>`
    ui.labels.appendChild(el)
    const cx = r.polygon.reduce((s, p) => s + p[0], 0) / r.polygon.length, cz = r.polygon.reduce((s, p) => s + p[1], 0) / r.polygon.length
    return { el, pos: new THREE.Vector3(cx, 1.2, cz) }
  })
  ui.toggles.labels.onchange = () => { ui.labels.hidden = !ui.toggles.labels.checked }

  // ---- controls: dollhouse orbit, first-person walk, exact photo cameras -------------------------
  const orbit = new THREE.OrbitControls(camera, renderer.domElement)
  orbit.enableDamping = true
  orbit.target.set(center.x, 0.4, center.z)
  orbit.maxPolarAngle = Math.PI * 0.49
  orbit.minDistance = 1
  orbit.maxDistance = radius * 8
  /** look at the whole house from above at an angle (the dollhouse view) */
  function frameHouse() {
    const aspect = Math.max(0.4, (ui.stage.clientWidth || 1) / (ui.stage.clientHeight || 1))
    const fit = Math.hypot(size.x, size.z) / 2 + 0.3
    const vfov = THREE.MathUtils.degToRad(40) / 2, hfov = Math.atan(Math.tan(vfov) * aspect)
    const dist = fit / Math.sin(Math.min(vfov, hfov)) * 0.95
    const dir = new THREE.Vector3(0.55, 1.15, 0.8).normalize()
    camera.position.copy(orbit.target).addScaledVector(dir, dist)
    orbit.update()
  }
  frameHouse()

  const photos = spec.photos || []
  let mode = 'dollhouse', photoIndex = -1, exact = null
  const v3 = new THREE.Vector3()
  // walking starts in the middle of the biggest room
  const big = (spec.rooms || []).filter((r) => r.polygon?.length >= 3).map((r) => ({ r, a: polyArea(r.polygon) })).sort((p, q) => q.a - p.a)[0]
  const start = big ? new THREE.Vector3(big.r.polygon.reduce((s, p) => s + p[0], 0) / big.r.polygon.length, 1.6, big.r.polygon.reduce((s, p) => s + p[1], 0) / big.r.polygon.length) : new THREE.Vector3(center.x, 1.6, center.z)
  const walk = { pos: start.clone(), yaw: 0, pitch: 0 }
  const keys = new Set()
  addEventListener('keydown', (e) => { if (!e.target.closest?.('textarea,input:not([type=range]):not([type=checkbox])')) keys.add(e.code) })
  addEventListener('keyup', (e) => keys.delete(e.code))
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

  // hold-to-walk buttons for touch screens (they feed the same keys as WASD)
  for (const b of ui.moveButtons) {
    const down = (e) => { e.preventDefault(); keys.add(b.dataset.key) }
    const up = () => keys.delete(b.dataset.key)
    b.addEventListener('pointerdown', down)
    for (const ev of ['pointerup', 'pointerleave', 'pointercancel']) b.addEventListener(ev, up)
  }

  let dollhouseView = null // where the orbit camera was, to come back to it from Walk/Photos
  function setMode(m) {
    const prev = mode
    if (prev === 'dollhouse' && m !== 'dollhouse') dollhouseView = camera.position.clone()
    mode = m
    ui.move.hidden = m !== 'walk'
    ui.photoPanel.hidden = m !== 'photo'
    orbit.enabled = m === 'dollhouse'
    for (const b of ui.modeButtons) b.classList.toggle('on', b.dataset.mode === m)
    if (m !== 'photo') { exact = null; ui.overlay.hidden = true }
    if (m === 'walk') {
      const d = camera.getWorldDirection(new THREE.Vector3())
      if (photoIndex < 0 && exact == null) walk.pos.copy(start)
      walk.yaw = Math.atan2(-d.x, -d.z); walk.pitch = 0
    }
    if (m === 'dollhouse') {
      camera.fov = 40; camera.updateProjectionMatrix()
      if (prev !== 'dollhouse') { if (dollhouseView) camera.position.copy(dollhouseView); else frameHouse(); orbit.update() }
    }
    updateCutaway()
    if (m === 'photo' && photos.length && !exact) goToPhoto(Math.max(0, photoIndex))
  }

  function goToPhoto(i) {
    if (!photos.length) return
    photoIndex = (i + photos.length) % photos.length
    const p = photos[photoIndex]
    const m4 = new THREE.Matrix4().fromArray(p.transform)
    const hold = photoHold(p.transform[1], p.transform[5])
    exact = {
      pos: new THREE.Vector3().setFromMatrixPosition(m4),
      // turned upright the way the phone was held (portrait or landscape)
      quat: new THREE.Quaternion().setFromRotationMatrix(m4).multiply(new THREE.Quaternion().setFromAxisAngle(new THREE.Vector3(0, 0, 1), hold.roll)),
      fov: THREE.MathUtils.radToDeg(2 * Math.atan(hold.portrait ? p.width / 2 / p.fx : p.height / 2 / (p.fy || p.fx))),
    }
    walk.pos.copy(exact.pos)
    if (mode !== 'photo') setMode('photo')
    ui.photoCount.textContent = `${photoIndex + 1} / ${photos.length}`
    ui.photoPanel.hidden = false
    if (has.has(p.file)) source.read(p.file).then((buf) => {
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
  ui.title.textContent = spec.name || 'Property model'
  ui.subtitle.textContent = spec.subtitle || ''

  // #photo=N&ui=0&overlay=0.5 — render from a photo's exact camera (for photo-vs-model comparisons)
  function applyHash() {
    const q = new URLSearchParams(location.hash.slice(1))
    if (q.get('ui') === '0') ui.root.dataset.ui = '0'
    if (q.has('overlay')) ui.overlaySlider.value = Math.round(Math.min(1, Math.max(0, +q.get('overlay') || 0)) * 100)
    if (q.has('photo') && photos.length) goToPhoto(+q.get('photo') || 0)
    else if (q.get('mode')) setMode(q.get('mode'))
    if (q.has('quality')) { quality = q.get('quality') !== '0'; ui.toggles.quality.checked = quality }
    if (q.has('cutaway')) { ui.toggles.cutaway.checked = q.get('cutaway') !== '0'; updateCutaway() }
    applyOverlay()
  }
  applyHash()
  addEventListener('hashchange', applyHash)

  /** in the dollhouse, walls between the camera and the rooms drop to a low stub */
  function updateCutaway() {
    const on = mode === 'dollhouse' && ui.toggles.cutaway.checked
    for (const c of cutaways) {
      const cut = on && v3.copy(camera.position).sub(c.mid).dot(c.n) < -0.05
      c.full.visible = !cut
      c.stub.visible = cut
    }
  }
  ui.toggles.cutaway.onchange = updateCutaway

  // ---- render loop ---------------------------------------------------------------------------------
  let last = performance.now()
  function frame(now) {
    const dt = Math.min(0.05, (now - last) / 1000); last = now
    const w = ui.stage.clientWidth, h = ui.stage.clientHeight
    const pr = renderer.getPixelRatio()
    if (renderer.domElement.width !== Math.round(w * pr) || renderer.domElement.height !== Math.round(h * pr)) {
      renderer.setSize(w, h, false); composer.setSize(w, h); ao.setSize(w * pr, h * pr)
      camera.aspect = w / Math.max(1, h); camera.updateProjectionMatrix()
    }
    if (mode === 'dollhouse') { orbit.update(); updateCutaway() }
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
      walk.pos.addScaledVector(fwd, f * dt * 1.5).addScaledVector(right, r * dt * 1.5)
      walk.pos.y += (1.6 - walk.pos.y) * Math.min(1, dt * 4)
      camera.position.copy(walk.pos)
      camera.rotation.set(walk.pitch, walk.yaw, 0, 'YXZ')
    }
    // labels follow their rooms
    if (!ui.labels.hidden) for (const l of labels) {
      v3.copy(l.pos).project(camera)
      const vis = v3.z < 1 && mode === 'dollhouse'
      l.el.style.display = vis ? '' : 'none'
      if (vis) l.el.style.transform = `translate(-50%,-50%) translate(${(v3.x + 1) / 2 * w}px, ${(1 - v3.y) / 2 * h}px)`
    }
    if (quality) composer.render(dt)
    else renderer.render(scene, camera)
    requestAnimationFrame(frame)
  }
  requestAnimationFrame(frame)
  return { scene, camera, renderer, spec, setMode, goToPhoto, get mode() { return mode } }
}

// ---- furniture builders: each draws into g, from the floor (y = 0) up, centered on x/z, front +z -----
function makeBuilders(THREE, material, C) {
  const R = THREE.RoundedBoxGeometry
  const add = (g, geo, mat, x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0) => {
    const m = new THREE.Mesh(geo, mat)
    m.position.set(x, y, z); m.rotation.set(rx, ry, rz)
    g.add(m)
    return m
  }
  const rbox = (w, h, d, r = 0.03) => new R(Math.max(w, 0.01), Math.max(h, 0.01), Math.max(d, 0.01), 3, Math.min(r, w / 2, h / 2, d / 2) * 0.999)
  const cbox = (w, h, d) => new THREE.BoxGeometry(Math.max(w, 0.005), Math.max(h, 0.005), Math.max(d, 0.005))
  const cyl = (r, h, s = 20) => new THREE.CylinderGeometry(r, r, h, s)
  const dims = (it) => it.size || [0.5, 0.5, 0.5]
  const wood = (it) => material(C(it.colors?.wood || it.color, '#9a6b43'), { roughness: 0.6 })
  const metal = (c = '#2b2b2e') => material(c, { roughness: 0.35, metalness: 0.7 })
  const legs = (g, w, d, h, r, mat, inset = 0.05) => {
    for (const [sx, sz] of [[-1, -1], [1, -1], [1, 1], [-1, 1]]) add(g, cyl(r, h, 10), mat, sx * (w / 2 - inset), h / 2, sz * (d / 2 - inset))
  }
  const rng = (seed) => () => ((seed = (seed * 16807) % 2147483647) / 2147483647)
  const seedOf = (it) => Math.abs(Math.round((it.center[0] * 73 + it.center[2] * 191) * 100)) + 1

  const B = {
    box(g, it) {
      const [w, h, d] = dims(it)
      add(g, rbox(w, h, d, 0.02), material(C(it.color, '#c8c2b8')), 0, h / 2, 0)
    },
    custom(g, it) {
      // declarative composition: parts [{ shape: box|rbox|cyl|sphere|cone, size, pos, rot, color, roughness, metalness }]
      for (const p of it.parts || []) {
        const s = p.size || [0.1, 0.1, 0.1]
        const geo = p.shape === 'cyl' ? cyl(s[0] / 2, s[1], 24) : p.shape === 'sphere' ? new THREE.SphereGeometry(s[0] / 2, 24, 16)
          : p.shape === 'cone' ? new THREE.ConeGeometry(s[0] / 2, s[1], 24) : p.shape === 'rbox' ? rbox(...s, p.radius ?? 0.02) : cbox(...s)
        const m = add(g, geo, material(C(p.color, '#bbbbbb'), { roughness: p.roughness ?? 0.7, metalness: p.metalness ?? 0, opacity: p.opacity }),
          ...(p.pos || [0, s[1] / 2, 0]), ...(p.rot || [0, 0, 0]))
        if (p.shape === 'sphere' && s[1]) m.scale.set(1, s[1] / s[0], (s[2] || s[0]) / s[0])
      }
    },
    bed(g, it) {
      const [w, h, d] = dims(it)
      const frameH = Math.min(0.3, h * 0.35), matH = Math.min(0.25, h * 0.3)
      const frameMat = wood(it)
      add(g, rbox(w, frameH, d, 0.02), frameMat, 0, frameH / 2, 0)
      add(g, rbox(w - 0.04, matH, d - 0.06, 0.06), material('#f4f2ee', { roughness: 0.95 }), 0, frameH + matH / 2, 0.01)
      const top = frameH + matH
      // duvet over the front two thirds, hanging over the sides
      add(g, rbox(w + 0.02, 0.07, d * 0.66, 0.035), material(C(it.colors?.blanket || it.color, '#d8d2c8'), { roughness: 0.95 }), 0, top + 0.01, d / 2 - d * 0.33)
      // pillows at the head (back, -z)
      const n = w > 1.2 ? 2 : 1
      for (let i = 0; i < n; i++) {
        const px = n === 1 ? 0 : (i - 0.5) * w * 0.48
        add(g, rbox(w / n * 0.8, 0.12, 0.38, 0.06), material(C(it.colors?.pillow, '#fbfaf7'), { roughness: 0.95 }), px, top + 0.06, -d / 2 + 0.3)
      }
      if (h > top + 0.2) add(g, rbox(w + 0.04, h, 0.08, 0.02), frameMat, 0, h / 2, -d / 2 + 0.04)
    },
    sofa(g, it) {
      const [w, h, d] = dims(it)
      const fabric = material(C(it.color, '#8f8a83'), { roughness: 0.95 })
      const armW = Math.min(0.2, w * 0.12), seatH = Math.min(0.45, h * 0.55), baseH = seatH - 0.14
      add(g, rbox(w, baseH, d, 0.04), fabric, 0, baseH / 2 + 0.06, 0)
      for (const s of [-1, 1]) add(g, rbox(armW, h * 0.75, d, 0.06), fabric, s * (w / 2 - armW / 2), h * 0.375, 0)
      add(g, rbox(w - 2 * armW + 0.02, h - baseH, 0.22, 0.08), fabric, 0, baseH + (h - baseH) / 2, -d / 2 + 0.11)
      const n = Math.max(1, Math.round((w - 2 * armW) / 0.75)), cw = (w - 2 * armW) / n
      for (let i = 0; i < n; i++) {
        const x = -w / 2 + armW + cw * (i + 0.5)
        add(g, rbox(cw - 0.02, 0.16, d - 0.26, 0.07), fabric, x, baseH + 0.14, 0.1)
        add(g, rbox(cw - 0.04, (h - seatH) * 0.85, 0.16, 0.07), fabric, x, seatH + (h - seatH) * 0.45, -d / 2 + 0.28, -0.12)
      }
      legs(g, w, d, 0.06, 0.02, metal('#3a3530'), 0.08)
    },
    chair(g, it) {
      const [w, h, d] = dims(it)
      const seatY = Math.min(0.47, h * 0.5), mat = material(C(it.color, '#4b4b50'), { roughness: 0.7 })
      add(g, rbox(w * 0.92, 0.06, d * 0.85, 0.02), mat, 0, seatY, 0.02)
      add(g, rbox(w * 0.9, h - seatY, 0.05, 0.02), mat, 0, seatY + (h - seatY) / 2, -d / 2 + 0.06, -0.08)
      legs(g, w * 0.86, d * 0.8, seatY - 0.03, 0.016, metal(), 0.03)
    },
    table(g, it) {
      const [w, h, d] = dims(it)
      add(g, rbox(w, 0.04, d, 0.01), wood(it), 0, h - 0.02, 0)
      legs(g, w, d, h - 0.04, 0.025, it.colors?.legs ? material(it.colors.legs) : wood(it), 0.06)
    },
    desk(g, it) {
      const [w, h, d] = dims(it)
      add(g, rbox(w, 0.035, d, 0.008), material(C(it.color, '#e9e5dd'), { roughness: 0.5 }), 0, h - 0.0175, 0)
      const lm = metal(C(it.colors?.legs, '#2a2a2c'))
      for (const s of [-1, 1]) { add(g, cbox(0.05, h - 0.035, 0.05), lm, s * (w / 2 - 0.06), (h - 0.035) / 2, -d / 2 + 0.08); add(g, cbox(0.05, h - 0.035, 0.05), lm, s * (w / 2 - 0.06), (h - 0.035) / 2, d / 2 - 0.08) }
      add(g, cbox(w - 0.14, 0.04, 0.03), lm, 0, h - 0.08, -d / 2 + 0.08)
    },
    storage(g, it) {
      const [w, h, d] = dims(it)
      if (h > 1.1 && d < 0.5) return B.shelf(g, it)
      const body = material(C(it.color, '#e8e3da'), { roughness: 0.6 })
      add(g, rbox(w, h, d, 0.01), body, 0, h / 2, 0)
      const doors = Math.max(1, Math.round(w / 0.5)), dw = w / doors
      const front = material(C(it.colors?.front || it.color, '#efebe3'), { roughness: 0.5 })
      const rows = h > 1.2 ? 1 : Math.max(1, Math.round(h / 0.3))
      for (let i = 0; i < doors; i++) for (let r = 0; r < rows; r++) {
        const rh = (h - 0.06) / rows
        add(g, cbox(dw - 0.02, rh - 0.02, 0.012), front, -w / 2 + dw * (i + 0.5), 0.03 + rh * (r + 0.5), d / 2 + 0.006)
        add(g, cbox(rows > 1 ? 0.12 : 0.015, rows > 1 ? 0.015 : 0.12, 0.02), metal('#9c958a'), -w / 2 + dw * (i + 0.5) + (rows > 1 ? 0 : (i % 2 ? -dw / 2 + 0.05 : dw / 2 - 0.05)), 0.03 + rh * (r + (rows > 1 ? 0.8 : 0.5)), d / 2 + 0.02)
      }
    },
    shelf(g, it) {
      const [w, h, d] = dims(it)
      const m = wood(it), r = rng(seedOf(it))
      for (const s of [-1, 1]) add(g, cbox(0.025, h, d), m, s * (w / 2 - 0.0125), h / 2, 0)
      add(g, cbox(w, h, 0.01), m, 0, h / 2, -d / 2 + 0.005)
      const n = Math.max(2, Math.round(h / 0.35))
      for (let i = 0; i <= n; i++) {
        const y = 0.02 + (h - 0.04) * (i / n)
        add(g, cbox(w - 0.05, 0.025, d), m, 0, y, 0)
        if (i === n || it.books === false) continue
        // a row of books / boxes on each shelf
        let x = -w / 2 + 0.04
        while (x < w / 2 - 0.08) {
          const bw = 0.025 + r() * 0.04, bh = Math.min((h - 0.04) / n - 0.05, 0.18 + r() * 0.12)
          if (r() > 0.18) add(g, cbox(bw, bh, d * 0.75), material(['#b24b3e', '#355c7d', '#e8d8b0', '#2f4f4f', '#c9a227', '#6c5b7b', '#f2efe8'][Math.floor(r() * 7)], { roughness: 0.8 }), x + bw / 2, y + 0.0125 + bh / 2, 0.01)
          x += bw + (r() > 0.85 ? 0.08 : 0.003)
        }
      }
    },
    television(g, it) {
      const [w, h, d] = dims(it)
      const th = Math.min(0.05, d)
      add(g, rbox(w, h, th, 0.01), material('#111214', { roughness: 0.3 }), 0, h / 2, 0)
      add(g, cbox(w - 0.03, h - 0.03, 0.002), material('#1b2430', { roughness: 0.15, metalness: 0.3 }), 0, h / 2, th / 2 + 0.001)
    },
    refrigerator(g, it) {
      const [w, h, d] = dims(it)
      const m = material(C(it.color, '#d7d9db'), { roughness: 0.3, metalness: 0.5 })
      add(g, rbox(w, h, d, 0.03), m, 0, h / 2, 0)
      add(g, cbox(w - 0.02, 0.008, 0.01), material('#888'), 0, h * 0.62, d / 2 + 0.002)
      for (const y of [h * 0.35, h * 0.82]) add(g, cbox(0.02, h * 0.18, 0.03), metal('#aaa'), w / 2 - 0.07, y, d / 2 + 0.02)
    },
    stove(g, it) {
      const [w, h, d] = dims(it)
      add(g, rbox(w, h, d, 0.01), material(C(it.color, '#e4e4e2'), { roughness: 0.4, metalness: 0.3 }), 0, h / 2, 0)
      add(g, cbox(w - 0.02, 0.01, d - 0.04), material('#141414', { roughness: 0.2 }), 0, h + 0.004, 0)
      add(g, cbox(w * 0.75, h * 0.38, 0.01), material('#202022', { roughness: 0.15 }), 0, h * 0.42, d / 2 + 0.004)
      for (let i = 0; i < 4; i++) add(g, cyl(0.018, 0.02), material('#333'), -w / 2 + w * (i + 1) / 5, h * 0.8, d / 2 + 0.01, Math.PI / 2)
    },
    oven(g, it) { B.stove(g, it) },
    dishwasher(g, it) {
      const [w, h, d] = dims(it)
      add(g, rbox(w, h, d, 0.01), material(C(it.color, '#cfd2d4'), { roughness: 0.3, metalness: 0.5 }), 0, h / 2, 0)
      add(g, cbox(w * 0.6, 0.02, 0.03), metal('#aaa'), 0, h - 0.08, d / 2 + 0.015)
    },
    washerDryer(g, it) {
      const [w, h, d] = dims(it)
      add(g, rbox(w, h, d, 0.03), material(C(it.color, '#f2f2f0'), { roughness: 0.4 }), 0, h / 2, 0)
      add(g, cyl(Math.min(w, h) * 0.28, 0.03, 32), material('#2b3440', { roughness: 0.1, metalness: 0.3 }), 0, h * 0.45, d / 2 + 0.01, Math.PI / 2)
      add(g, new THREE.TorusGeometry(Math.min(w, h) * 0.3, 0.02, 10, 40), metal('#bbb'), 0, h * 0.45, d / 2 + 0.02)
    },
    sink(g, it) {
      const [w, h, d] = dims(it)
      B.storage(g, { ...it, size: [w, h - 0.04, d] })
      add(g, rbox(w + 0.02, 0.04, d + 0.02, 0.005), material(C(it.colors?.counter, '#dedbd4'), { roughness: 0.3 }), 0, h - 0.02, 0)
      add(g, cbox(Math.min(0.6, w * 0.6), 0.012, d * 0.55), material('#9fa4a8', { roughness: 0.2, metalness: 0.8 }), 0, h + 0.002, 0)
      add(g, cyl(0.015, 0.25), metal('#c0c0c0'), 0, h + 0.12, -d / 2 + 0.08)
      add(g, cyl(0.012, 0.15), metal('#c0c0c0'), 0, h + 0.24, -d / 2 + 0.15, Math.PI / 2)
    },
    toilet(g, it) {
      const [w, h, d] = dims(it)
      const p = material('#f7f7f5', { roughness: 0.2 })
      add(g, cyl(w * 0.32, 0.38, 24), p, 0, 0.19, d * 0.1)
      add(g, new THREE.CylinderGeometry(w * 0.42, w * 0.36, 0.08, 28), p, 0, 0.4, d * 0.12)
      add(g, rbox(w * 0.9, h - 0.38, 0.18, 0.03), p, 0, 0.38 + (h - 0.38) / 2, -d / 2 + 0.09)
    },
    bathtub(g, it) {
      const [w, h, d] = dims(it)
      add(g, rbox(w, h, d, 0.05), material('#f5f5f3', { roughness: 0.25 }), 0, h / 2, 0)
      add(g, rbox(w - 0.14, 0.02, d - 0.14, 0.01), material('#e4ecef', { roughness: 0.1 }), 0, h - 0.005, 0)
    },
    fireplace(g, it) {
      const [w, h, d] = dims(it)
      add(g, rbox(w, h, d, 0.01), material(C(it.color, '#d9d4cc'), { roughness: 0.8 }), 0, h / 2, 0)
      add(g, cbox(w * 0.55, h * 0.5, 0.02), material('#1a1715', { roughness: 0.9 }), 0, h * 0.3, d / 2 + 0.005)
      add(g, cbox(w + 0.1, 0.05, d + 0.08), material('#c7c1b6'), 0, h + 0.025, 0.02)
    },
    stairs(g, it) {
      const [w, h, d] = dims(it)
      const n = Math.max(3, Math.round(h / 0.18)), rise = h / n, run = d / n
      const m = material(C(it.color, '#e6e3dd'), { roughness: 0.7 })
      for (let i = 0; i < n; i++) add(g, cbox(w, rise * (i + 1), run), m, 0, rise * (i + 1) / 2, d / 2 - run * (i + 0.5))
      if (it.railing !== false) {
        const rm = metal(C(it.colors?.railing, '#1b1b1b'))
        const len = Math.hypot(h, d)
        add(g, cbox(0.04, 0.04, len), rm, w / 2 - 0.03, h / 2 + 0.9, 0, Math.atan2(h, d))
        for (let i = 0; i <= n; i += 2) add(g, cbox(0.02, 0.9, 0.02), rm, w / 2 - 0.03, rise * i + 0.45, d / 2 - run * i)
      }
    },
    rug(g, it) {
      const [w, , d] = dims(it)
      const m = it.material ? material(it.material) : material(C(it.color, '#d8cfc0'), { roughness: 1 })
      const r = add(g, rbox(w, 0.012, d, 0.005), m, 0, 0.006, 0)
      r.castShadow = false
    },
    plant(g, it) {
      const [w, h] = dims(it)
      add(g, new THREE.CylinderGeometry(w * 0.3, w * 0.22, h * 0.3, 20), material(C(it.colors?.pot, '#e9e4dc'), { roughness: 0.6 }), 0, h * 0.15, 0)
      const leaf = material(C(it.color, '#4f7a3a'), { roughness: 0.8 }), r = rng(seedOf(it))
      for (let i = 0; i < 9; i++) {
        const s = w * (0.22 + r() * 0.16)
        add(g, new THREE.IcosahedronGeometry(s, 0), leaf, (r() - 0.5) * w * 0.5, h * (0.45 + r() * 0.45), (r() - 0.5) * w * 0.5, r() * 3, r() * 3)
      }
    },
    lamp(g, it) {
      const [w, h] = dims(it)
      add(g, cyl(w * 0.25, 0.03), metal(), 0, 0.015, 0)
      add(g, cyl(0.012, h * 0.8), metal(), 0, h * 0.4, 0)
      const shade = add(g, new THREE.CylinderGeometry(w * 0.3, w * 0.45, h * 0.22, 24, 1, true), material(C(it.color, '#f3ead8'), { emissive: '#3a3020', side: THREE.DoubleSide }), 0, h * 0.86, 0)
      shade.castShadow = false
    },
    curtain(g, it) {
      const [w, h, d] = dims(it)
      const m = material(C(it.color, '#bfb5a8'), { roughness: 1 })
      const folds = Math.max(3, Math.round(w / 0.12)), fw = w / folds
      for (let i = 0; i < folds; i++) add(g, cyl(fw * 0.55, h - 0.04, 8), m, -w / 2 + fw * (i + 0.5), (h - 0.04) / 2, (i % 2 ? 0.015 : -0.015) * Math.min(1, d / 0.05))
      add(g, cyl(0.012, w + 0.2), metal('#5a5a5a'), 0, h - 0.02, 0, 0, 0, Math.PI / 2)
    },
    wallArt(g, it) {
      const [w, h, d] = dims(it)
      add(g, cbox(w, h, Math.max(0.02, Math.min(d, 0.04))), material(C(it.colors?.frame, '#2a2522'), { roughness: 0.5 }), 0, h / 2, 0)
      add(g, cbox(w - 0.06, h - 0.06, 0.005), it.material ? material(it.material) : material(C(it.color, '#d9cbb0'), { roughness: 0.9 }), 0, h / 2, Math.min(d, 0.04) / 2 + 0.002)
    },
  }
  return B
}

const polyArea = (poly) => Math.abs(poly.reduce((s, [x, z], i) => { const [x2, z2] = poly[(i + 1) % poly.length]; return s + x * z2 - x2 * z }, 0) / 2)
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c])

function buildUI(container) {
  const style = document.createElement('style')
  style.textContent = `
  .hm{position:relative;width:100%;height:100%;overflow:hidden;font:14px/1.35 system-ui,-apple-system,sans-serif;color:#eef2f8;background:${GRID_BG};touch-action:none;user-select:none}
  .hm-stage,.hm-stage canvas{position:absolute;inset:0;width:100%;height:100%;display:block}
  .hm-card{background:rgba(12,22,38,.78);backdrop-filter:blur(8px);-webkit-backdrop-filter:blur(8px);border:1px solid rgba(150,190,240,.14);border-radius:12px;padding:8px 12px}
  .hm-top{position:absolute;left:12px;right:12px;top:12px;display:flex;gap:8px;flex-wrap:wrap;align-items:flex-start;pointer-events:none}
  .hm-top>*{pointer-events:auto}.hm-title{font-weight:650;font-size:15px}.hm-sub{opacity:.7;font-size:12px}
  .hm-modes{margin-left:auto;display:flex;gap:4px}
  .hm button{font:inherit;color:inherit;background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.14);border-radius:9px;padding:7px 12px;cursor:pointer;white-space:nowrap}
  .hm button.on{background:#3d8bfd;border-color:#3d8bfd}.hm button:disabled{opacity:.35}
  .hm-bottom{position:absolute;left:12px;bottom:12px;display:flex;gap:12px;font-size:12px;align-items:center}
  .hm-bottom label{display:flex;gap:5px;align-items:center}
  .hm-labels{position:absolute;inset:0;pointer-events:none}
  .hm-label{position:absolute;left:0;top:0;background:rgba(12,22,38,.82);border:1px solid rgba(150,190,240,.2);border-radius:8px;padding:4px 9px;font-size:12px;white-space:nowrap;display:flex;flex-direction:column;align-items:center}
  .hm-label span{opacity:.7;font-size:11px}
  .hm-overlay{position:absolute;top:0;left:50%;height:100%;transform:translateX(-50%);pointer-events:none}
  .hm-overlay[hidden]{display:none}
  .hm-photo{position:absolute;right:12px;bottom:12px;width:min(260px,40vw)}
  .hm-photo img{width:100%;border-radius:8px;display:block}
  .hm-photo .row{display:flex;gap:6px;align-items:center;margin-top:6px;font-size:12px}
  .hm-photo .count{white-space:nowrap}.hm-photo input{min-width:0;width:100%}
  .hm-move{position:absolute;right:16px;bottom:64px;display:flex;flex-direction:column;gap:8px}
  .hm-move[hidden]{display:none}.hm-move button{width:56px;height:56px;border-radius:50%;font-size:20px;padding:0;touch-action:none}
  .hm[data-ui="0"] .hm-top,.hm[data-ui="0"] .hm-bottom,.hm[data-ui="0"] .hm-photo,.hm[data-ui="0"] .hm-labels,.hm[data-ui="0"] .hm-move{display:none!important}
  @media (max-width:600px){.hm-modes{margin-left:0}.hm-photo{width:42vw}.hm-hint{display:none}.hm-bottom{flex-wrap:wrap;gap:8px;right:12px}}`
  const root = document.createElement('div')
  root.className = 'hm'
  root.innerHTML = `
    <div class="hm-stage"></div><div class="hm-labels"></div>
    <img class="hm-overlay" alt="" hidden>
    <div class="hm-top">
      <div class="hm-card"><div class="hm-title"></div><div class="hm-sub"></div></div>
      <div class="hm-card hm-modes"><button data-mode="dollhouse" class="on">Dollhouse</button><button data-mode="walk">Walk</button><button data-mode="photo">Photos</button></div>
    </div>
    <div class="hm-card hm-bottom">
      <label><input type="checkbox" data-t="labels" checked>Room labels</label>
      <label><input type="checkbox" data-t="cutaway" checked>Cut away walls</label>
      <label><input type="checkbox" data-t="quality">Soft shadows (AO)</label>
      <span class="hm-hint" style="opacity:.6">Drag to orbit · scroll to zoom · WASD in Walk</span>
    </div>
    <div class="hm-move" hidden><button data-key="KeyW" aria-label="Walk forward">▲</button><button data-key="KeyS" aria-label="Walk back">▼</button></div>
    <div class="hm-card hm-photo" hidden>
      <img alt="Photo from this spot">
      <div class="row"><button data-a="prev">‹</button><span class="count"></span><button data-a="next">›</button>
      <label style="flex:1;min-width:0;display:flex;gap:6px;align-items:center">Compare <input type="range" min="0" max="100" value="0" style="flex:1" class="ov"></label></div>
    </div>`
  container.append(style, root)
  const q = (s) => root.querySelector(s)
  return {
    root, stage: q('.hm-stage'), labels: q('.hm-labels'), overlay: q('.hm-overlay'), title: q('.hm-title'), subtitle: q('.hm-sub'),
    modeButtons: [...root.querySelectorAll('[data-mode]')],
    move: q('.hm-move'), moveButtons: [...root.querySelectorAll('.hm-move button')],
    toggles: { labels: q('[data-t=labels]'), quality: q('[data-t=quality]'), cutaway: q('[data-t=cutaway]') },
    photoPanel: q('.hm-photo'), photoImg: q('.hm-photo img'), photoCount: q('.hm-photo .count'),
    prev: q('[data-a=prev]'), next: q('[data-a=next]'), overlaySlider: q('.ov'),
  }
}
