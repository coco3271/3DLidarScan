import ARKit
import Combine
import RoomPlan
import SwiftUI
import UIKit

/// Runs one property capture: Apple's RoomPlan (a headless RoomCaptureSession) builds the
/// parametric room model while, on the same ARSession, we record the LiDAR mesh, depth frames,
/// automatic reference photos and full-resolution shutter photos, each tagged with GPS +
/// compass. ScanOverlay draws the live mesh, colored by how well the photos cover it.
/// Several rooms in a row share one ARKit world, so StructureBuilder can merge them into a
/// floor plan and every pose in the bundle lines up.
@MainActor
final class CaptureController: NSObject, ObservableObject {
  enum Phase: Equatable {
    case ready, scanning, processingRoom, roomDone, finishing, finished
    case failed(String)
  }

  @Published private(set) var phase: Phase = .ready
  @Published private(set) var roomIndex = 0
  @Published var roomName = "Room 1"
  @Published private(set) var photoCount = 0
  @Published private(set) var manualPhotoCount = 0
  @Published private(set) var depthFrameCount = 0
  @Published private(set) var meshFaces = 0
  @Published private(set) var flash = false
  @Published private(set) var warning: String?
  @Published private(set) var finishingStep = ""
  /// live floor-plan data for the mini map: where you walked, where you are, where photos were taken
  @Published private(set) var trail: [SIMD2<Float>] = []
  @Published private(set) var here: MapSpot?
  @Published private(set) var photoSpots: [MapSpot] = []
  /// share of the LiDAR mesh that is well photographed (the "Photo detail" ring), 0…100
  @Published private(set) var coveragePercent = 0
  /// RoomPlan's coaching ("Move closer to the wall", …), nil when all is well
  @Published private(set) var instruction: String?
  /// coverage stopped improving: tell the user they can save
  @Published private(set) var coverageStalled = false
  /// auto photos + depth recording paused (RoomPlan keeps tracking)
  @Published private(set) var paused = false
  @Published var meshVisible = true {
    didSet { overlay.meshVisible = meshVisible }
  }

  let arSession = ARSession()
  /// what the photos have captured, shared with the overlay that colors the mesh
  let coverage = CoverageMap()
  /// camera + LiDAR mesh tinted red/green by photo coverage + RoomPlan outlines
  private(set) lazy var overlay = ScanOverlay(session: arSession, coverage: coverage)
  /// RoomPlan runs headless on our ARSession; the overlay draws what it finds
  private let roomDelegate = RoomSessionDelegate()
  private lazy var roomSession: RoomCaptureSession = {
    let session = RoomCaptureSession(arSession: arSession)
    session.delegate = roomDelegate
    return session
  }()
  private var coverageHistory: [(time: TimeInterval, percent: Int)] = []
  let location = LocationTracker()

  let folder: URL
  private var manifest: Manifest
  private var rooms: [CapturedRoom] = []
  private var photos: [PhotoRecord] = []
  private var depthFrames: [DepthRecord] = []
  private let writer = MediaWriter()
  private var ticker: Timer?
  private var locationSink: AnyCancellable?
  private var nextPhoto = 0
  private var lastAutoPhoto: (time: TimeInterval, pose: simd_float4x4)?
  private var lastDepth: (time: TimeInterval, pose: simd_float4x4)?
  private var previousPose: (time: TimeInterval, pose: simd_float4x4)?
  private var lastConfigCheck: TimeInterval = 0
  private var configRuns = 0
  private var highResInFlight = false
  /// the device/RoomPlan configuration refused a full-resolution still: stop asking for auto photos
  private var highResSupported = true
  private var lastHighResRequest: CFTimeInterval = 0
  private var roomMeshRecord: MeshRecord?

  /// long edge of saved shutter photos (full-resolution stills are ~4032×3024)
  private static let maxManualEdge: CGFloat = 4032
  /// long edge of automatic photos: full-resolution stills scaled to 3024, video frames stay 1920×1440
  private static let maxAutoEdge: CGFloat = 3024
  /// predicted motion smear (pixels at 1920 wide) above which an automatic photo is skipped
  private static let maxAutoBlur: Float = 2.5

  init(folder: URL, propertyName: String) {
    self.folder = folder
    manifest = Manifest(
      createdAt: Date(), device: UIDevice.modelIdentifier, systemVersion: UIDevice.current.systemVersion,
      house: folder.lastPathComponent, houseName: propertyName, session: folder.lastPathComponent,
      property: PropertyInfo(name: propertyName), app: AppInfo())
    super.init()
    for sub in ["rooms", "mesh", "photos", "depth"] {
      try? FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    locationSink = location.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.objectWillChange.send() }
    }
    roomDelegate.onUpdate = { [weak self] room in self?.overlay.showRoom(room) }
    roomDelegate.onInstruction = { [weak self] text in self?.instruction = text }
    roomDelegate.onEnd = { [weak self] data, error in
      guard let self else { return }
      Task { await self.roomEnded(data, error: error) }
    }
    overlay.onCoverage = { [weak self] fraction in self?.coverageChanged(fraction) }
  }

  static var isSupported: Bool { RoomCaptureSession.isSupported }

  // MARK: rooms

  func startRoom() {
    guard phase == .ready || phase == .roomDone else { return }
    warning = nil
    if roomName.trimmingCharacters(in: .whitespaces).isEmpty { roomName = "Room \(roomIndex + 1)" }
    location.start()
    configRuns = 0
    lastAutoPhoto = nil
    previousPose = nil
    roomMeshRecord = nil
    instruction = nil
    coverageStalled = false
    coverageHistory = []
    if paused { paused = false }
    roomSession.run(configuration: RoomCaptureSession.Configuration())
    phase = .scanning
    UIApplication.shared.isIdleTimerDisabled = true
    ticker?.invalidate()
    ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }
  }

  /// Done with this room: save the LiDAR mesh while ARKit still has it, then let RoomPlan
  /// build the room. The ARSession keeps running so the next room lands in the same world.
  func finishRoom() {
    guard phase == .scanning else { return }
    phase = .processingRoom
    ticker?.invalidate()
    Task {
      await self.exportMesh()
      self.roomSession.stop(pauseARSession: false)
    }
  }

  /// Write ARKit's current LiDAR mesh (the whole session so far) as mesh/room-N.ply
  private func exportMesh() async {
    let anchors = arSession.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
    let index = roomIndex
    let url = folder.appendingPathComponent("mesh/room-\(index).ply")
    let coverage = coverage
    let record = await Task.detached(priority: .userInitiated) { () -> MeshRecord? in
      guard !anchors.isEmpty, var r = try? MeshExporter.writePLY(anchors: anchors, to: url, coverage: coverage) else { return nil }
      r.file = "mesh/room-\(index).ply"
      return r
    }.value
    roomMeshRecord = record
    meshFaces = record?.faces ?? 0
  }

  /// RoomPlan finished capturing (we stopped it, or it stopped on its own): keep its raw data,
  /// then build the final room model from it
  private func roomEnded(_ data: CapturedRoomData, error: Error?) async {
    guard phase == .processingRoom || phase == .scanning else { return }
    if let json = try? JSONEncoder().encode(data) {
      try? json.write(to: folder.appendingPathComponent("rooms/room-\(roomIndex)-data.json"))
    }
    do {
      let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
      await roomProcessed(room, error: error)
    } catch {
      await roomFailed(error)
    }
  }

  /// RoomPlan couldn't build a model: keep the room's mesh, photos and depth anyway
  private func roomFailed(_ error: Error) async {
    if phase == .scanning {
      phase = .processingRoom
      await exportMesh()
    }
    ticker?.invalidate()
    warning = "RoomPlan couldn't model this room (\(error.localizedDescription)). The LiDAR mesh and photos are saved."
    let index = roomIndex
    manifest.rooms.append(RoomRecord(
      index: index, name: roomName.trimmingCharacters(in: .whitespaces), file: "", usdz: "", capturedAt: Date(),
      walls: 0, doors: 0, windows: 0, openings: 0, objects: 0, mesh: roomMeshRecord, data: nil))
    if let roomMeshRecord { manifest.mesh = roomMeshRecord }
    await saveIndexes()
    phase = .roomDone
  }

  // MARK: coverage

  private func coverageChanged(_ fraction: Float) {
    let percent = Int((fraction * 100).rounded())
    coveragePercent = percent
    guard phase == .scanning else { return }
    // "isn't improving much": under 3 points gained in the last 25 s of scanning, once past 40 %
    let now = CACurrentMediaTime()
    coverageHistory.append((now, percent))
    coverageHistory.removeAll { now - $0.time > 25 }
    if let first = coverageHistory.first, now - first.time > 20 {
      coverageStalled = percent >= 40 && percent - first.percent < 3
    }
  }

  func togglePause() {
    guard phase == .scanning else { return }
    paused.toggle()
  }

  private func roomProcessed(_ room: CapturedRoom, error: Error?) async {
    overlay.showRoom(room)
    guard phase == .processingRoom || phase == .scanning else { return }
    ticker?.invalidate()
    if phase == .scanning {
      // RoomPlan ended the room by itself (error, tracking lost): still keep the LiDAR mesh
      phase = .processingRoom
      await exportMesh()
    }
    if let error { warning = "RoomPlan: \(error.localizedDescription)" }
    let index = roomIndex
    let encoder = BundleJSON.encoder
    do {
      try encoder.encode(room).write(to: folder.appendingPathComponent("rooms/room-\(index).json"))
    } catch {
      warning = "Could not save the room model: \(error.localizedDescription)"
    }
    try? room.export(to: folder.appendingPathComponent("rooms/room-\(index).usdz"), exportOptions: .parametric)
    try? room.export(to: folder.appendingPathComponent("rooms/room-\(index)-mesh.usdz"), exportOptions: .mesh)
    rooms.append(room)
    let dataFile = "rooms/room-\(index)-data.json"
    manifest.rooms.append(RoomRecord(
      index: index, name: roomName.trimmingCharacters(in: .whitespaces), file: "rooms/room-\(index).json",
      usdz: "rooms/room-\(index).usdz", capturedAt: Date(),
      walls: room.walls.count, doors: room.doors.count, windows: room.windows.count, openings: room.openings.count,
      objects: room.objects.count, mesh: roomMeshRecord,
      data: FileManager.default.fileExists(atPath: folder.appendingPathComponent(dataFile).path) ? dataFile : nil))
    if let roomMeshRecord { manifest.mesh = roomMeshRecord }
    await saveIndexes()
    phase = .roomDone
  }

  func prepareNextRoom() {
    roomIndex += 1
    roomName = "Room \(roomIndex + 1)"
  }

  /// Merge all rooms into one structure (floor plan), write the final manifest, stop ARKit.
  func finishProperty() async {
    guard phase == .roomDone || phase == .ready else { return }
    phase = .finishing
    ticker?.invalidate()
    if rooms.count > 1 {
      finishingStep = "Merging rooms into a floor plan…"
      do {
        let structure = try await StructureBuilder(options: [.beautifyObjects]).capturedStructure(from: rooms)
        try BundleJSON.encoder.encode(structure).write(to: folder.appendingPathComponent("structure.json"))
        try? structure.export(to: folder.appendingPathComponent("structure.usdz"), exportOptions: .parametric)
        manifest.structure = "structure.json"
      } catch {
        manifest.structureError = error.localizedDescription
      }
    }
    finishingStep = "Saving…"
    if let loc = location.location, loc.horizontalAccuracy >= 0 {
      manifest.property?.latitude = loc.coordinate.latitude
      manifest.property?.longitude = loc.coordinate.longitude
      manifest.property?.altitude = loc.verticalAccuracy >= 0 ? loc.altitude : nil
      manifest.property?.horizontalAccuracy = loc.horizontalAccuracy
    }
    manifest.property?.address = location.address
    manifest.endedAt = Date()
    if let c = arSession.configuration as? ARWorldTrackingConfiguration {
      manifest.sceneReconstruction = "reconstruction=\(c.sceneReconstruction.rawValue) semantics=\(c.frameSemantics.rawValue)"
    }
    await saveIndexes()
    arSession.pause()
    location.stop()
    UIApplication.shared.isIdleTimerDisabled = false
    phase = rooms.isEmpty ? .failed("No rooms were captured.") : .finished
  }

  /// Leave without finishing: whatever rooms are done are kept as a scan.
  func abandon() async {
    ticker?.invalidate()
    if phase == .scanning || phase == .processingRoom { roomSession.stop() }
    if !rooms.isEmpty {
      phase = .roomDone
      await finishProperty()
    } else {
      arSession.pause()
      location.stop()
      UIApplication.shared.isIdleTimerDisabled = false
      try? FileManager.default.removeItem(at: folder)
      phase = .failed("Cancelled")
    }
  }

  private func saveIndexes() async {
    await writer.drain()
    manifest.photoCount = photos.count
    manifest.depthFrameCount = depthFrames.count
    if manifest.property?.address == nil { manifest.property?.address = location.address }
    let e = BundleJSON.encoder
    try? e.encode(photos).write(to: folder.appendingPathComponent("photos/photos.json"))
    try? e.encode(depthFrames).write(to: folder.appendingPathComponent("depth/frames.json"))
    try? e.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    try? PosesCSV.make(photos: photos, depthFrames: depthFrames).write(to: folder.appendingPathComponent("poses.csv"), atomically: true, encoding: .utf8)
  }

  // MARK: per-frame recording

  private func tick() {
    guard phase == .scanning, let frame = arSession.currentFrame else { return }
    ensureMeshAndDepth(now: frame.timestamp)
    guard case .normal = frame.camera.trackingState else {
      previousPose = (frame.timestamp, frame.camera.transform)
      return
    }
    updateMap(frame)
    if !paused {
      considerDepth(frame)
      considerAutoPhoto(frame)
    }
    previousPose = (frame.timestamp, frame.camera.transform)
  }

  /// RoomPlan's own ARConfiguration doesn't hand out mesh anchors or depth. Adding them to
  /// *its* configuration (no reset, same world) keeps RoomPlan working; check now and then
  /// because RoomPlan may reconfigure. Capped so a device that refuses can't loop forever.
  private func ensureMeshAndDepth(now: TimeInterval) {
    guard now - lastConfigCheck > 1, configRuns < 6,
          let c = arSession.configuration as? ARWorldTrackingConfiguration else { return }
    lastConfigCheck = now
    let wantsDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    let meshOK = c.sceneReconstruction.contains(.meshWithClassification)
    let depthOK = !wantsDepth || c.frameSemantics.contains(.sceneDepth)
    if meshOK && depthOK { return }
    guard let updated = c.copy() as? ARWorldTrackingConfiguration else { return }
    updated.initialWorldMap = nil
    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
      updated.sceneReconstruction = .meshWithClassification
    }
    if wantsDepth { updated.frameSemantics.insert(.sceneDepth) }
    configRuns += 1
    arSession.run(updated, options: [])
  }

  /// Depth while walking: up to 5/s, only when the phone moved or turned a little
  private func considerDepth(_ frame: ARFrame) {
    guard frame.sceneDepth != nil, writer.inFlight < 4 else { return }
    let pose = frame.camera.transform
    if let last = lastDepth {
      guard frame.timestamp - last.time > 0.2, moved(pose, last.pose) > 0.04 || turned(pose, last.pose) > 0.06 else { return }
    }
    recordDepth(frame)
  }

  /// Save the frame's LiDAR depth (+ its 640×480 RGB and pose) as depth/NNNNN.*
  @discardableResult
  private func recordDepth(_ frame: ARFrame, photo: String? = nil) -> DepthRecord? {
    guard let depth = frame.sceneDepth else { return nil }
    lastDepth = (frame.timestamp, frame.camera.transform)
    let name = String(format: "%05d", depthFrames.count)
    guard var record = writer.writeDepth(frame, depth: depth, folder: folder, name: name, room: roomIndex) else { return nil }
    record.photo = photo
    depthFrames.append(record)
    depthFrameCount = depthFrames.count
    return record
  }

  private func updateMap(_ frame: ARFrame) {
    let t = frame.camera.transform
    let spot = MapSpot(t, manual: false)
    here = spot
    if let last = trail.last, simd_distance(last, spot.point) < 0.25 { return }
    trail.append(spot.point)
  }

  /// Automatic reference photos, the bulk of the "hundreds of photos": one whenever you've moved
  /// ~0.4 m or turned ~17° and the view is steady enough to be sharp. A full-resolution still
  /// is requested when possible (every ~2.5 s), otherwise the 1920×1440 video frame is kept.
  private func considerAutoPhoto(_ frame: ARFrame) {
    let pose = frame.camera.transform
    guard writer.inFlight < 3, !highResInFlight, let prev = previousPose else { return }
    let blur = motionBlur(frame, since: prev)
    guard blur < Self.maxAutoBlur else { return }
    if let last = lastAutoPhoto {
      guard frame.timestamp - last.time > 0.8, moved(pose, last.pose) > 0.4 || turned(pose, last.pose) > 0.3 else { return }
    }
    lastAutoPhoto = (frame.timestamp, pose)
    let thermalOK = ProcessInfo.processInfo.thermalState == .nominal || ProcessInfo.processInfo.thermalState == .fair
    if highResSupported, thermalOK, CACurrentMediaTime() - lastHighResRequest > 2.5 {
      requestHighRes(manual: false, near: pose)
    } else {
      savePhoto(frame, manual: false, highRes: false, blur: blur)
    }
  }

  /// Predicted smear in pixels (at 1920 wide) from how fast the camera turns and moves during
  /// the exposure; assumes surfaces ~1.5 m away for the translation part.
  private func motionBlur(_ frame: ARFrame, since prev: (time: TimeInterval, pose: simd_float4x4)) -> Float {
    let dt = Float(max(0.001, frame.timestamp - prev.time))
    let fx = frame.camera.intrinsics.columns.0.x * 1920 / Float(frame.camera.imageResolution.width)
    let angular = turned(frame.camera.transform, prev.pose) / dt
    let linear = moved(frame.camera.transform, prev.pose) / dt
    return (angular + linear / 1.5) * fx * Float(frame.camera.exposureDuration)
  }

  // MARK: shutter

  /// Full-resolution still of where you're standing (falls back to the video frame)
  func takePhoto() {
    guard phase == .scanning, !highResInFlight else { return }
    flash = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.flash = false }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    requestHighRes(manual: true, near: nil)
  }

  /// Ask ARKit for a full-resolution still. Auto photos keep it only if it shows the view that
  /// triggered it (the still arrives a moment later); otherwise the live video frame is used.
  private func requestHighRes(manual: Bool, near pose: simd_float4x4?) {
    highResInFlight = true
    lastHighResRequest = CACurrentMediaTime()
    arSession.captureHighResolutionFrame { [weak self] frame, error in
      DispatchQueue.main.async {
        guard let self else { return }
        self.highResInFlight = false
        guard self.phase == .scanning else { return }
        if error != nil, !manual { self.highResSupported = false }
        func sameView(_ t: simd_float4x4) -> Bool {
          guard let pose else { return true }
          return self.moved(t, pose) < 0.15 && self.turned(t, pose) < 0.12
        }
        if let frame, case .normal = frame.camera.trackingState, sameView(frame.camera.transform) {
          self.savePhoto(frame, manual: manual, highRes: true)
        } else if let current = self.arSession.currentFrame, manual || sameView(current.camera.transform) {
          self.savePhoto(current, manual: manual, highRes: false)
        }
      }
    }
  }

  private func savePhoto(_ frame: ARFrame, manual: Bool, highRes: Bool, blur: Float? = nil) {
    let file = String(format: "photos/%04d.jpg", nextPhoto)
    let geo = location.sample
    let maxEdge = manual ? Self.maxManualEdge : Self.maxAutoEdge
    guard let size = writer.writePhoto(frame.capturedImage, to: folder.appendingPathComponent(file), maxEdge: maxEdge, geo: geo) else { return }
    nextPhoto += 1
    // the LiDAR depth for this exact view: the photo's own frame, or (for a full-resolution
    // still, which may carry no depth) the live frame from the same moment
    let depthSource = frame.sceneDepth != nil ? frame : arSession.currentFrame
    let depth = depthSource.flatMap { recordDepth($0, photo: file) }
    // what this photo saw (its LiDAR depth) is now photographed: the mesh turns green there
    if let source = depthSource, let sample = DepthSample(source) { overlay.addPhoto(sample) }
    let scale = Float(size.width) / Float(frame.camera.imageResolution.width)
    var k = frame.camera.intrinsics
    k.columns.0.x *= scale; k.columns.1.y *= scale; k.columns.2.x *= scale; k.columns.2.y *= scale
    photos.append(PhotoRecord(
      file: file, room: roomIndex, timestamp: frame.timestamp, width: Int(size.width), height: Int(size.height),
      transform: frame.camera.transform.columnMajor, intrinsics: k.columnMajor,
      tracking: Self.describe(frame.camera.trackingState), manual: manual,
      exposure: frame.camera.exposureDuration, blurPixels: blur.map { $0 * scale * Float(frame.camera.imageResolution.width) / 1920 },
      pass: "scan", highRes: highRes,
      camera: CameraState(exposureOffset: frame.camera.exposureOffset,
                          ambientIntensity: frame.lightEstimate.map { Float($0.ambientIntensity) },
                          colorTemperature: frame.lightEstimate.map { Float($0.ambientColorTemperature) }),
      capturedAt: Date(), location: geo, pose: CameraPose(frame.camera.transform), depthFrame: depth?.file))
    photoSpots.append(MapSpot(frame.camera.transform, manual: manual))
    photoCount = photos.count
    if manual { manualPhotoCount += 1 }
  }

  // MARK: helpers

  // pure math: callable from ARKit's completion handlers as well as the main actor
  nonisolated private func moved(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
    simd_distance(simd_make_float3(a.columns.3), simd_make_float3(b.columns.3))
  }

  nonisolated private func turned(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
    acos(min(1, max(-1, simd_dot(simd_make_float3(a.columns.2), simd_make_float3(b.columns.2)))))
  }

  private static func describe(_ state: ARCamera.TrackingState) -> String {
    switch state {
    case .normal: return "normal"
    case .notAvailable: return "notAvailable"
    case .limited(let reason):
      switch reason {
      case .excessiveMotion: return "limited:excessiveMotion"
      case .insufficientFeatures: return "limited:insufficientFeatures"
      case .initializing: return "limited:initializing"
      case .relocalizing: return "limited:relocalizing"
      @unknown default: return "limited"
      }
    @unknown default: return "unknown"
    }
  }
}

/// RoomCaptureSession's delegate, kept apart from the main-actor controller. RoomPlan doesn't
/// promise which thread it calls from, so everything hops to the main actor.
final class RoomSessionDelegate: NSObject, RoomCaptureSessionDelegate, @unchecked Sendable {
  @MainActor var onUpdate: ((CapturedRoom) -> Void)?
  @MainActor var onInstruction: ((String?) -> Void)?
  @MainActor var onEnd: ((CapturedRoomData, Error?) -> Void)?

  func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
    Task { @MainActor in self.onUpdate?(room) }
  }

  func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
    let text = Self.text(instruction)
    Task { @MainActor in self.onInstruction?(text) }
  }

  func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: (any Error)?) {
    Task { @MainActor in self.onEnd?(data, error) }
  }

  static func text(_ instruction: RoomCaptureSession.Instruction) -> String? {
    switch instruction {
    case .moveCloseToWall: return "Move closer to the wall"
    case .moveAwayFromWall: return "Move away from the wall"
    case .slowDown: return "Slow down"
    case .turnOnLight: return "Turn on more light"
    case .lowTexture: return "Point at a part of the room with more detail"
    case .normal: return nil
    @unknown default: return nil
    }
  }
}
