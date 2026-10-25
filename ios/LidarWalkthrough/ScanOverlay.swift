import ARKit
import RoomPlan
import SceneKit
import UIKit

/// The live scanning view: the camera feed with ARKit's LiDAR mesh drawn over it. Each
/// triangle is tinted by photo coverage (red = needs photos, amber = almost, green = captured)
/// with the LiDAR triangles traced in white, and RoomPlan's walls (white) and doors/windows
/// (cyan) outlined as it finds them. Only surfaces the LiDAR has reached have a mesh at all.
///
/// ARSCNView renders the session RoomPlan runs; it observes the session without taking over
/// its delegate. Mesh snapshots are copied on SceneKit's render thread, colored on a work
/// queue, and handed to SceneKit on the main thread.
@MainActor
final class ScanOverlay: NSObject {
  let view = ARSCNView(frame: .zero)
  let coverage: CoverageMap
  /// fraction of the LiDAR mesh that is well photographed, 0…1 (main thread)
  var onCoverage: (@MainActor (Float) -> Void)?
  /// how many LiDAR mesh anchors are drawn (main thread)
  var onMeshAnchors: (@MainActor (Int) -> Void)?

  var meshVisible = true {
    didSet { for node in state.allNodes() { node.isHidden = !meshVisible } }
  }

  private let state = OverlayState()
  private let work = DispatchQueue(label: "scan-overlay", qos: .userInitiated)
  private var timer: DispatchSourceTimer?
  private let outline = SCNNode()
  private var lastOutline: CFTimeInterval = 0


  init(session: ARSession, coverage: CoverageMap) {
    self.coverage = coverage
    super.init()
    view.session = session
    view.delegate = state
    view.scene = SCNScene()
    view.automaticallyUpdatesLighting = false
    view.rendersCameraGrain = false
    view.rendersMotionBlur = false
    view.antialiasingMode = .multisampling4X
    outline.renderingOrder = 10
    view.scene.rootNode.addChildNode(outline)
    timer = startRefreshing()
  }

  /// Color whatever changed, ~4× a second, on the work queue (built outside the main actor so
  /// the timer's closure isn't main-actor code running off the main thread)
  private nonisolated func startRefreshing() -> DispatchSourceTimer {
    let t = DispatchSource.makeTimerSource(queue: work)
    t.schedule(deadline: .now() + 0.25, repeating: 0.25)
    t.setEventHandler { [weak self] in self?.refresh() }
    t.resume()
    return t
  }

  /// A photo was saved: what its depth frame saw is now photographed
  func addPhoto(_ depth: DepthSample) {
    let coverage = coverage
    work.async { coverage.add(depth.pointsSeen()) }
  }

  /// RoomPlan's current walls (white) and doors/windows/openings (cyan), as outlines
  func showRoom(_ room: CapturedRoom?) {
    let now = CACurrentMediaTime()
    guard room == nil || now - lastOutline > 0.4 else { return } // RoomPlan updates a lot
    lastOutline = now
    outline.childNodes.forEach { $0.removeFromParentNode() }
    guard let room else { return }
    for w in room.walls { outline.addChildNode(Self.rectangle(w.transform, w.dimensions, OverlayStyle.wallLine)) }
    for o in room.doors + room.windows + room.openings {
      outline.addChildNode(Self.rectangle(o.transform, o.dimensions, OverlayStyle.openingLine))
    }
  }

  private static func rectangle(_ t: simd_float4x4, _ d: SIMD3<Float>, _ material: SCNMaterial) -> SCNNode {
    let hw = d.x / 2, hh = d.y / 2
    let corners = [SCNVector3(-hw, -hh, 0.01), SCNVector3(hw, -hh, 0.01), SCNVector3(hw, hh, 0.01), SCNVector3(-hw, hh, 0.01)]
    let element = SCNGeometryElement(indices: [UInt16(0), 1, 1, 2, 2, 3, 3, 0], primitiveType: .line)
    let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: corners)], elements: [element])
    geometry.materials = [material]
    let node = SCNNode(geometry: geometry)
    node.simdTransform = t
    node.renderingOrder = 10
    return node
  }

  /// Forget the mesh coloring state (a new capture)
  func clear() {
    state.reset()
    showRoom(nil)
  }

  // MARK: work queue

  /// Color new/changed mesh anchors, and recolor everything when photos changed the coverage
  private nonisolated func refresh() {
    let version = coverage.version
    let recolorAll = version != state.coloredVersion
    let changed = state.takePending()
    var meshes: [UUID: MeshSnapshot] = [:]
    for anchor in changed { meshes[anchor.identifier] = MeshSnapshot(anchor) }
    state.store(meshes)
    let targets = recolorAll ? state.allSnapshots() : Array(meshes.values)
    guard !targets.isEmpty else { return }
    state.coloredVersion = version
    var built: [(UUID, SCNGeometry?)] = []
    for mesh in targets {
      let result = MeshCoverage(triangles: mesh.triangles, scores: coverage.scores(for: mesh.world))
      state.setCounts(mesh.id, captured: result.capturedVertices, total: result.totalVertices)
      built.append((mesh.id, Self.geometry(mesh, result)))
    }
    let fraction = state.capturedFraction()
    let anchorCount = state.allSnapshots().count
    Task { @MainActor [weak self] in
      guard let self else { return }
      for (id, geometry) in built { self.state.apply(geometry, to: id, hidden: !self.meshVisible) }
      self.onCoverage?(fraction)
      self.onMeshAnchors?(anchorCount)
    }
  }

  private nonisolated static func geometry(_ mesh: MeshSnapshot, _ coverage: MeshCoverage) -> SCNGeometry? {
    guard !mesh.local.isEmpty, !mesh.triangles.isEmpty else { return nil }
    let positions = mesh.local.withUnsafeBufferPointer { Data(buffer: $0) }
    // Swift pads SIMD3<Float> to 16 bytes
    let vertices = SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: mesh.local.count,
                                     usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                     dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
    var elements: [SCNGeometryElement] = []
    var materials: [SCNMaterial] = []
    for (band, indices) in coverage.bands.enumerated() where !indices.isEmpty {
      elements.append(SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) },
                                         primitiveType: .triangles, primitiveCount: indices.count / 3, bytesPerIndex: 4))
      materials.append(OverlayStyle.bandMaterials[band])
    }
    let fill = SCNGeometry(sources: [vertices], elements: elements)
    fill.materials = materials
    return fill
  }

}


/// Materials for the overlay. Kept out of the main-actor class: the work queue builds
/// geometry with them too.
enum OverlayStyle {
  // red / amber / green, see-through so the room stays visible
  static let bandMaterials: [SCNMaterial] = [
    (UIColor(red: 1.0, green: 0.23, blue: 0.23, alpha: 1), 0.30),
    (UIColor(red: 1.0, green: 0.72, blue: 0.20, alpha: 1), 0.26),
    (UIColor(red: 0.22, green: 0.93, blue: 0.46, alpha: 1), 0.24),
  ].map { color, alpha in
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = color
    m.transparency = alpha
    m.blendMode = .alpha
    m.writesToDepthBuffer = true
    m.readsFromDepthBuffer = true
    return m
  }
  static let wireMaterial: SCNMaterial = {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = UIColor.white
    m.transparency = 0.38
    m.fillMode = .lines
    m.blendMode = .alpha
    m.writesToDepthBuffer = false
    return m
  }()
  static func lineMaterial(_ color: UIColor) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .constant
    m.diffuse.contents = color
    m.readsFromDepthBuffer = false // always on top, like RoomPlan's own outlines
    return m
  }
  static let wallLine = lineMaterial(.white)
  static let openingLine = lineMaterial(.cyan)

  static func wire(for fill: SCNGeometry) -> SCNGeometry {
    let wire = SCNGeometry(sources: fill.sources, elements: fill.elements)
    wire.materials = [wireMaterial]
    return wire
  }
}

/// One mesh anchor copied out of ARKit's buffers
struct MeshSnapshot {
  let id: UUID
  /// anchor-local (what SceneKit draws under the anchor's node)
  let local: [SIMD3<Float>]
  /// world space (what coverage is looked up with)
  let world: [SIMD3<Float>]
  let triangles: [UInt32]

  init(_ anchor: ARMeshAnchor) {
    id = anchor.identifier
    let g = anchor.geometry
    let v = g.vertices
    let base = v.buffer.contents().advanced(by: v.offset)
    var local: [SIMD3<Float>] = []
    local.reserveCapacity(v.count)
    for i in 0..<v.count {
      // packed 12-byte float3s: read the components, never a padded SIMD3
      let p = base.advanced(by: i * v.stride)
      local.append(SIMD3(p.load(as: Float.self), p.load(fromByteOffset: 4, as: Float.self), p.load(fromByteOffset: 8, as: Float.self)))
    }
    let m = anchor.transform
    world = local.map { let w = m * SIMD4($0, 1); return SIMD3(w.x, w.y, w.z) }
    self.local = local
    let f = g.faces
    let fb = f.buffer.contents()
    var tris: [UInt32] = []
    tris.reserveCapacity(f.count * 3)
    for i in 0..<(f.count * f.indexCountPerPrimitive) {
      let at = i * f.bytesPerIndex
      tris.append(f.bytesPerIndex == 2 ? UInt32(fb.load(fromByteOffset: at, as: UInt16.self)) : fb.load(fromByteOffset: at, as: UInt32.self))
    }
    triangles = tris
  }
}

/// Everything the render thread, the work queue and main share, behind one lock.
/// Also the ARSCNView delegate (its callbacks arrive on SceneKit's render thread).
private final class OverlayState: NSObject, ARSCNViewDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var nodes: [UUID: SCNNode] = [:]
  private var pending: [UUID: ARMeshAnchor] = [:]
  private var snapshots: [UUID: MeshSnapshot] = [:]
  private var counts: [UUID: (captured: Int, total: Int)] = [:]
  private var lastQueued: [UUID: CFTimeInterval] = [:]
  private var _coloredVersion = -1

  var coloredVersion: Int {
    get { lock.withLock { _coloredVersion } }
    set { lock.withLock { _coloredVersion = newValue } }
  }

  func reset() {
    lock.withLock {
      pending.removeAll(); snapshots.removeAll(); counts.removeAll(); lastQueued.removeAll()
      _coloredVersion = -1
    }
  }

  func allNodes() -> [SCNNode] { lock.withLock { Array(nodes.values) } }
  func allSnapshots() -> [MeshSnapshot] { lock.withLock { Array(snapshots.values) } }
  func takePending() -> [ARMeshAnchor] { lock.withLock { defer { pending.removeAll() }; return Array(pending.values) } }
  func store(_ meshes: [UUID: MeshSnapshot]) { lock.withLock { snapshots.merge(meshes) { $1 } } }
  func setCounts(_ id: UUID, captured: Int, total: Int) { lock.withLock { counts[id] = (captured, total) } }

  func capturedFraction() -> Float {
    lock.withLock {
      let total = counts.values.reduce(0) { $0 + $1.total }
      return total == 0 ? 0 : Float(counts.values.reduce(0) { $0 + $1.captured }) / Float(total)
    }
  }

  /// main thread
  func apply(_ geometry: SCNGeometry?, to id: UUID, hidden: Bool) {
    guard let node = lock.withLock({ nodes[id] }) else { return }
    node.geometry = geometry
    node.isHidden = hidden
    let wire = node.childNode(withName: "wire", recursively: false) ?? {
      let n = SCNNode()
      n.name = "wire"
      n.renderingOrder = 1
      node.addChildNode(n)
      return n
    }()
    wire.geometry = geometry.map(OverlayStyle.wire(for:))
  }

  private func queue(_ anchor: ARMeshAnchor, force: Bool) {
    let now = CACurrentMediaTime()
    lock.withLock {
      // ARKit refines anchors many times a second; re-copying each one ~3×/s is plenty
      guard force || now - lastQueued[anchor.identifier, default: 0] > 0.3 else { return }
      lastQueued[anchor.identifier] = now
      pending[anchor.identifier] = anchor
    }
  }

  // MARK: ARSCNViewDelegate (render thread)

  func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
    guard let mesh = anchor as? ARMeshAnchor else { return nil }
    let node = SCNNode()
    lock.withLock { nodes[mesh.identifier] = node }
    queue(mesh, force: true)
    return node
  }

  func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
    guard let mesh = anchor as? ARMeshAnchor else { return }
    queue(mesh, force: false)
  }

  func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
    guard anchor is ARMeshAnchor else { return }
    let id = anchor.identifier
    lock.withLock {
      nodes[id] = nil; pending[id] = nil; snapshots[id] = nil; counts[id] = nil; lastQueued[id] = nil
    }
  }

  /// Don't draw the mesh right in front of the lens: it only blocks the view
  func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
    if let camera = renderer.pointOfView?.camera, camera.zNear != 0.25 { camera.zNear = 0.25 }
  }

  /// Relocalize after an interruption (a call, the app in the background) instead of a new world
  func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { true }
}

extension DepthSample {
  /// Copy a frame's LiDAR depth (Float32 meters) and confidence out of ARKit's buffers
  init?(_ frame: ARFrame) {
    guard let depth = frame.sceneDepth else { return nil }
    let map = depth.depthMap
    CVPixelBufferLockBaseAddress(map, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
    let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), row = CVPixelBufferGetBytesPerRow(map)
    var values = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
      let src = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
      for x in 0..<w { values[y * w + x] = src[x] }
    }
    var conf: [UInt8]?
    if let c = depth.confidenceMap {
      let bytes = MediaWriter.bytes(c)
      if bytes.count == w * h { conf = [UInt8](bytes) }
    }
    let scale = Float(w) / Float(frame.camera.imageResolution.width)
    var k = frame.camera.intrinsics
    k.columns.0.x *= scale; k.columns.1.y *= scale; k.columns.2.x *= scale; k.columns.2.y *= scale
    self.init(width: w, height: h, depth: values, confidence: conf, intrinsics: k, cameraToWorld: frame.camera.transform)
  }
}
