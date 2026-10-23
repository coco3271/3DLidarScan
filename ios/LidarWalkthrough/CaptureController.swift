import ARKit
import Combine
import RoomPlan
import SwiftUI
import UIKit

/// Runs one property capture: Apple's RoomPlan (RoomCaptureView) builds the parametric room
/// model while, on the same ARSession, we record the LiDAR mesh, depth frames, automatic
/// reference photos and full-resolution shutter photos, each tagged with GPS + compass.
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

  let arSession = ARSession()
  private let roomDelegate = RoomViewDelegate()
  private(set) lazy var roomCaptureView: RoomCaptureView = {
    let view = RoomCaptureView(frame: .zero, arSession: arSession)
    view.delegate = roomDelegate
    return view
  }()
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
  private var roomMeshRecord: MeshRecord?

  /// long edge of saved shutter photos (full-resolution stills are ~4032×3024)
  private static let maxManualEdge: CGFloat = 4032
  /// long edge of automatic photos (ARKit video frames are 1920×1440)
  private static let maxAutoEdge: CGFloat = 1920

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
    roomDelegate.onRoomData = { [weak self] data in
      MainActor.assumeIsolated { self?.saveRoomData(data) }
    }
    roomDelegate.onRoom = { [weak self] room, error in
      MainActor.assumeIsolated {
        guard let self else { return }
        Task { await self.roomProcessed(room, error: error) }
      }
    }
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
    roomCaptureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
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
    let anchors = arSession.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
    let index = roomIndex
    let url = folder.appendingPathComponent("mesh/room-\(index).ply")
    Task {
      let record = await Task.detached(priority: .userInitiated) { () -> MeshRecord? in
        guard !anchors.isEmpty, var r = try? MeshExporter.writePLY(anchors: anchors, to: url) else { return nil }
        r.file = "mesh/room-\(index).ply"
        return r
      }.value
      self.roomMeshRecord = record
      self.meshFaces = record?.faces ?? 0
      self.roomCaptureView.captureSession.stop(pauseARSession: false)
    }
  }

  /// RoomPlan's raw capture data, so RoomBuilder can be re-run on it later
  private func saveRoomData(_ data: CapturedRoomData) {
    guard let json = try? JSONEncoder().encode(data) else { return }
    try? json.write(to: folder.appendingPathComponent("rooms/room-\(roomIndex)-data.json"))
  }

  private func roomProcessed(_ room: CapturedRoom, error: Error?) async {
    guard phase == .processingRoom || phase == .scanning else { return }
    ticker?.invalidate()
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
    if phase == .scanning || phase == .processingRoom { roomCaptureView.captureSession.stop() }
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
    try? posesCSV().write(to: folder.appendingPathComponent("poses.csv"), atomically: true, encoding: .utf8)
  }

  /// One row per photo and depth frame: where the phone was, where it pointed, and which
  /// photo ↔ LiDAR frame belong together. Same numbers as the JSON, easy to read.
  private func posesCSV() -> String {
    func f(_ v: Float) -> String { String(format: "%.3f", v) }
    func g(_ v: Double?) -> String { v.map { String(format: "%.7f", $0) } ?? "" }
    var rows = ["kind,file,room,timestamp,x,y,z,dir_x,dir_y,dir_z,yaw_deg,pitch_deg,manual,high_res,paired_file,latitude,longitude,gps_accuracy_m,compass_heading_deg"]
    for p in photos {
      let pose = p.pose ?? CameraPose(simd_float4x4(columnMajor: p.transform))
      rows.append(["photo", p.file, "\(p.room)", String(format: "%.3f", p.timestamp),
                   f(pose.position[0]), f(pose.position[1]), f(pose.position[2]),
                   f(pose.direction[0]), f(pose.direction[1]), f(pose.direction[2]), f(pose.yaw), f(pose.pitch),
                   p.manual ? "1" : "0", (p.highRes ?? false) ? "1" : "0", p.depthFrame ?? "",
                   g(p.location?.latitude), g(p.location?.longitude), g(p.location?.horizontalAccuracy), g(p.location?.heading)]
        .joined(separator: ","))
    }
    for d in depthFrames {
      let pose = d.pose ?? CameraPose(simd_float4x4(columnMajor: d.transform))
      rows.append(["depth", d.file, "\(d.room)", String(format: "%.3f", d.timestamp),
                   f(pose.position[0]), f(pose.position[1]), f(pose.position[2]),
                   f(pose.direction[0]), f(pose.direction[1]), f(pose.direction[2]), f(pose.yaw), f(pose.pitch),
                   "", "", d.photo ?? "", "", "", "", ""].joined(separator: ","))
    }
    return rows.joined(separator: "\n") + "\n"
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
    considerDepth(frame)
    considerAutoPhoto(frame)
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

  /// A sharp reference photo whenever you've moved ~0.6 m or turned ~25° and are holding steady
  private func considerAutoPhoto(_ frame: ARFrame) {
    let pose = frame.camera.transform
    guard writer.inFlight < 3, !highResInFlight else { return }
    if let prev = previousPose {
      let dt = max(0.001, frame.timestamp - prev.time)
      // steady: < ~10°/s rotation and < 0.25 m/s
      guard turned(pose, prev.pose) / Float(dt) < 0.17, moved(pose, prev.pose) / Float(dt) < 0.25 else { return }
    } else { return }
    if let last = lastAutoPhoto {
      guard frame.timestamp - last.time > 1.0, moved(pose, last.pose) > 0.6 || turned(pose, last.pose) > 0.44 else { return }
    }
    lastAutoPhoto = (frame.timestamp, pose)
    savePhoto(frame, manual: false, highRes: false)
  }

  // MARK: shutter

  /// Full-resolution still of where you're standing (falls back to the video frame)
  func takePhoto() {
    guard phase == .scanning, !highResInFlight else { return }
    highResInFlight = true
    flash = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.flash = false }
    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    arSession.captureHighResolutionFrame { [weak self] frame, _ in
      DispatchQueue.main.async {
        guard let self else { return }
        self.highResInFlight = false
        guard self.phase == .scanning else { return }
        if let frame {
          self.savePhoto(frame, manual: true, highRes: true)
        } else if let current = self.arSession.currentFrame {
          self.savePhoto(current, manual: true, highRes: false)
        }
      }
    }
  }

  private func savePhoto(_ frame: ARFrame, manual: Bool, highRes: Bool) {
    let file = String(format: "photos/%04d.jpg", nextPhoto)
    let geo = location.sample
    let maxEdge = manual ? Self.maxManualEdge : Self.maxAutoEdge
    guard let size = writer.writePhoto(frame.capturedImage, to: folder.appendingPathComponent(file), maxEdge: maxEdge, geo: geo) else { return }
    nextPhoto += 1
    // the LiDAR depth for this exact view: the photo's own frame, or (for a full-resolution
    // still, which may carry no depth) the live frame from the same moment
    let depthSource = frame.sceneDepth != nil ? frame : arSession.currentFrame
    let depth = depthSource.flatMap { recordDepth($0, photo: file) }
    let scale = Float(size.width) / Float(frame.camera.imageResolution.width)
    var k = frame.camera.intrinsics
    k.columns.0.x *= scale; k.columns.1.y *= scale; k.columns.2.x *= scale; k.columns.2.y *= scale
    photos.append(PhotoRecord(
      file: file, room: roomIndex, timestamp: frame.timestamp, width: Int(size.width), height: Int(size.height),
      transform: frame.camera.transform.columnMajor, intrinsics: k.columnMajor,
      tracking: Self.describe(frame.camera.trackingState), manual: manual,
      exposure: frame.camera.exposureDuration, blurPixels: nil, pass: "scan", highRes: highRes,
      camera: CameraState(exposureOffset: frame.camera.exposureOffset,
                          ambientIntensity: frame.lightEstimate.map { Float($0.ambientIntensity) },
                          colorTemperature: frame.lightEstimate.map { Float($0.ambientColorTemperature) }),
      capturedAt: Date(), location: geo, pose: CameraPose(frame.camera.transform), depthFrame: depth?.file))
    photoSpots.append(MapSpot(frame.camera.transform, manual: manual))
    photoCount = photos.count
    if manual { manualPhotoCount += 1 }
  }

  // MARK: helpers

  private func moved(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
    simd_distance(simd_make_float3(a.columns.3), simd_make_float3(b.columns.3))
  }

  private func turned(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
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

/// RoomCaptureView's delegate. Kept apart from the controller because the protocol inherits
/// NSCoding (meant for view controllers); RoomPlan calls it on the main thread.
final class RoomViewDelegate: NSObject, RoomCaptureViewDelegate {
  var onRoomData: ((CapturedRoomData) -> Void)?
  var onRoom: ((CapturedRoom, Error?) -> Void)?

  override init() { super.init() }
  required init?(coder: NSCoder) { super.init() }
  func encode(with coder: NSCoder) {}

  func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: (any Error)?) -> Bool {
    onRoomData?(roomDataForProcessing)
    return true
  }

  func captureView(didPresent processedResult: CapturedRoom, error: (any Error)?) {
    onRoom?(processedResult, error)
  }
}

/// A camera position + heading on the floor plan (x/z of the session world, yaw in radians,
/// 0 = facing world -Z, counter-clockwise seen from above)
struct MapSpot: Equatable {
  var point: SIMD2<Float>
  var yaw: Float
  var manual: Bool

  init(_ t: simd_float4x4, manual: Bool) {
    point = SIMD2(t.columns.3.x, t.columns.3.z)
    let f = -simd_make_float3(t.columns.2)
    yaw = atan2(-f.x, -f.z)
    self.manual = manual
  }
}

extension simd_float4x4 {
  init(columnMajor m: [Float]) {
    self.init(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
              SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
  }
}
