import ARKit
import SwiftUI

/// Scanning, in landscape: the camera with the LiDAR mesh drawn over it (red = not captured
/// yet, green = captured), RoomPlan's outlines, the status and mini map on the left, the controls
/// on the right (like the Camera app). It asks for the phone to be held sideways before it
/// starts, and pauses the recording with a big prompt if it's turned upright mid-scan.
/// Finish scanning → review → Resume (same room) or Save room.
struct CaptureScreen: View {
  @ObservedObject var controller: CaptureController
  @Environment(\.dismiss) private var dismiss
  @StateObject private var holdMonitor = HoldMonitor()
  @State private var askRoomName = false
  @State private var confirmExit = false
  @State private var showTutorial = false
  @AppStorage("scanTutorialSeen") private var tutorialSeen = false

  var body: some View {
    ZStack {
      ScanContainer(view: controller.overlay.view).ignoresSafeArea()
      if controller.flash {
        Color.white.opacity(0.6).ignoresSafeArea().allowsHitTesting(false)
      }
      HStack(alignment: .top, spacing: 12) {
        leftColumn
        Spacer(minLength: 0)
        rightColumn
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      centerPrompts
    }
    .statusBarHidden()
    .onAppear {
      OrientationLock.set(.landscape, prefer: .landscapeRight)
      holdMonitor.start()
      guard controller.phase == .ready else { return }
      if tutorialSeen { askRoomName = true } else { showTutorial = true }
    }
    .onDisappear {
      holdMonitor.stop()
      OrientationLock.set(.portrait)
    }
    .onChange(of: holdMonitor.hold) { _, hold in controller.setHold(hold) }
    .onChange(of: controller.phase) { _, phase in
      switch phase {
      case .finished, .failed: dismiss()
      default: break
      }
    }
    .sheet(isPresented: $showTutorial, onDismiss: {
      tutorialSeen = true
      if controller.phase == .ready { askRoomName = true }
    }) {
      ScanTutorial { showTutorial = false }
    }
    .animation(.easeOut(duration: 0.2), value: controller.motion)
    .animation(.easeOut(duration: 0.2), value: controller.heldUpright)
    .alert("Name this room", isPresented: $askRoomName) {
      TextField("Kitchen, Living room…", text: $controller.roomName)
      Button("Start scanning") { controller.requestStart() }
      if controller.phase == .ready { Button("Cancel", role: .cancel) { Task { await controller.abandon() } } }
    } message: {
      Text("Hold your iPhone sideways and film the room slowly, high, middle and low. Red parts aren't captured yet; keep filming them until they turn green.")
    }
    .confirmationDialog("Stop scanning?", isPresented: $confirmExit, titleVisibility: .visible) {
      Button("Save finished rooms and exit") { Task { await controller.abandon() } }
      Button("Keep scanning", role: .cancel) {}
    } message: {
      Text("Rooms you already saved are kept. The room in progress is discarded.")
    }
  }

  // MARK: left: status, map, hints

  private var leftColumn: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 8) {
        VStack(spacing: 8) {
          circleButton("xmark", label: "Close") { confirmExit = true }
            .disabled(controller.phase == .finishing)
          circleButton("questionmark", label: "How to scan") { showTutorial = true }
        }
        statusCard
        if ([.scanning, .reviewing, .roomDone] as [CaptureController.Phase]).contains(controller.phase) {
          // live map: green = you, yellow cones = photos (bright = shutter shots)
          PlanCanvas(trail: controller.trail, spots: controller.photoSpots, here: controller.here, minSpan: 3)
            .frame(width: 104, height: 104)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
        }
      }
      if let warning = controller.warning {
        Text(warning).font(.footnote).padding(10).frame(maxWidth: 380, alignment: .leading)
          .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
      }
      Spacer(minLength: 0)
      hints.frame(maxWidth: 380)
    }
  }

  private var statusCard: some View {
    HStack(alignment: .center, spacing: 10) {
      CoverageRing(percent: controller.coveragePercent)
      VStack(alignment: .leading, spacing: 2) {
        Text(controller.roomName).font(.headline).lineLimit(1)
        if controller.phase == .scanning || controller.phase == .reviewing {
          HStack(spacing: 4) {
            Circle().fill(recordingNow ? .red : .gray).frame(width: 7, height: 7)
            Text("\(recordingNow ? "REC" : controller.phase == .reviewing ? "STOPPED" : "PAUSED") \(Self.clock(controller.videoSeconds))")
          }
          .font(.caption.bold()).monospacedDigit()
        }
        Text("\(controller.photoCount) photos · \(controller.depthFrameCount) depth")
          .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        if controller.earlierRooms > 0 {
          Text("+ \(controller.earlierRooms) earlier room\(controller.earlierRooms == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
        }
      }
    }
    .padding(8)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
  }

  private var recordingNow: Bool {
    controller.phase == .scanning && !controller.paused && !controller.heldUpright
  }

  @ViewBuilder private var hints: some View {
    if controller.phase == .scanning {
      VStack(alignment: .leading, spacing: 6) {
        if controller.meshAnchors == 0 {
          hint("Waiting for the LiDAR mesh… move the phone slowly around the room.", systemImage: "hourglass", tint: .white)
        }
        if let instruction = controller.instruction {
          hint(instruction, systemImage: "exclamationmark.triangle.fill", tint: .yellow)
        }
        if controller.paused {
          hint("Paused: nothing is recorded. RoomPlan keeps tracking.", systemImage: "pause.circle.fill", tint: .orange)
        } else if controller.coverageStalled {
          hint("Coverage isn't improving much. Film the red areas, or tap Finish.", systemImage: "checkmark.circle", tint: .green)
        } else {
          hint("Recording. Walk slowly and film red areas from a few angles until they turn green.", systemImage: "video.fill", tint: .red)
        }
        HStack(spacing: 10) {
          legend(.red, "not captured")
          legend(.green, "captured")
          SpeedMeter(value: controller.speedMeter, level: controller.motion)
        }
      }
    } else if controller.phase == .relocalizing, let instruction = controller.instruction {
      hint(instruction, systemImage: "location.viewfinder", tint: .cyan)
    }
  }

  private func hint(_ text: String, systemImage: String, tint: Color) -> some View {
    Label { Text(text) } icon: { Image(systemName: systemImage).foregroundStyle(tint) }
      .font(.caption)
      .padding(.horizontal, 10).padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
  }

  private func legend(_ color: Color, _ text: String) -> some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(text).font(.caption2)
    }
    .padding(.horizontal, 8).padding(.vertical, 4)
    .background(.ultraThinMaterial, in: Capsule())
  }

  private func circleButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.headline).frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
    }
    .accessibilityLabel(label)
  }

  // MARK: right: controls

  @ViewBuilder private var rightColumn: some View {
    switch controller.phase {
    case .ready, .relocalizing:
      VStack {
        Spacer()
        if controller.phase == .ready {
          Button("Start scanning") { askRoomName = true }.buttonStyle(.borderedProminent).controlSize(.large)
        } else {
          ProgressView("Finding your place…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        Spacer()
      }
    case .scanning:
      VStack(spacing: 14) {
        circleButton(controller.paused ? "play.fill" : "pause.fill", label: controller.paused ? "Resume recording" : "Pause recording") {
          controller.togglePause()
        }
        circleButton(controller.meshVisible ? "square.grid.3x3.fill" : "square.grid.3x3",
                     label: controller.meshVisible ? "Hide the scan mesh" : "Show the scan mesh") { controller.meshVisible.toggle() }
        Spacer(minLength: 0)
        Button { controller.takePhoto() } label: {
          ZStack {
            Circle().fill(.white).frame(width: 58, height: 58)
            Circle().stroke(.white, lineWidth: 4).frame(width: 70, height: 70)
            Image(systemName: "camera.fill").font(.title2).foregroundStyle(.black)
          }
        }
        .accessibilityLabel("Take a full-resolution photo (tour stop)")
        Spacer(minLength: 0)
        Button { controller.finishScanning() } label: {
          Label("Finish", systemImage: "stop.fill").labelStyle(.titleAndIcon).lineLimit(1).fixedSize()
        }
        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
        .accessibilityLabel("Finish scanning this room")
      }
      .padding(10)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    case .reviewing:
      panel {
        Text("“\(controller.roomName)” · \(controller.coveragePercent)% captured").font(.headline)
        Text("\(Self.clock(controller.videoSeconds)) of video. Still red somewhere? Resume and film it; everything stays lined up.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Button { controller.resumeScanning() } label: {
          Label("Resume scanning", systemImage: "record.circle").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.large)
        Button { controller.finishRoom() } label: {
          Label("Save room", systemImage: "checkmark").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent).controlSize(.large)
      }
    case .processingRoom:
      VStack { Spacer(); ProgressView("Building the room model…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)); Spacer() }
    case .roomDone:
      panel {
        Text("“\(controller.roomName)” saved").font(.headline)
        Text("Walk to the next room without closing the app so all rooms line up.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Button {
          controller.prepareNextRoom()
          askRoomName = true
        } label: { Label("Scan next room", systemImage: "plus").frame(maxWidth: .infinity) }
        .buttonStyle(.borderedProminent).controlSize(.large)
        Button { Task { await controller.finishProperty() } } label: {
          Label("Finish project", systemImage: "flag.checkered").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.large)
      }
    case .finishing:
      VStack { Spacer(); ProgressView(controller.finishingStep).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)); Spacer() }
    case .finished, .failed:
      EmptyView()
    }
  }

  private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 10) { content() }
      .padding(14)
      .frame(width: 270)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
      .frame(maxHeight: .infinity, alignment: .center)
  }

  // MARK: center: turn sideways, slow down

  @ViewBuilder private var centerPrompts: some View {
    if controller.waitingForLandscape || controller.heldUpright {
      VStack(spacing: 12) {
        Image(systemName: "iphone.landscape")
          .font(.system(size: 64))
          .symbolEffect(.pulse)
        Text(controller.heldUpright ? "Turn your iPhone sideways" : "Turn your iPhone sideways to start")
          .font(.title3.bold())
        Text(controller.heldUpright ? "Recording is paused while it's upright. Landscape sees more of the room in every frame."
                                    : "Scanning works in landscape: every frame sees more of the room.")
          .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
      }
      .padding(24)
      .frame(maxWidth: 420)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
      .transition(.scale.combined(with: .opacity))
    } else if controller.phase == .scanning && controller.motion == .tooFast && !controller.paused {
      VStack {
        Label("Slow down: moving too fast for a sharp video", systemImage: "tortoise.fill")
          .font(.headline)
          .padding(.horizontal, 14).padding(.vertical, 10)
          .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
          .transition(.scale.combined(with: .opacity))
          .accessibilityAddTraits(.updatesFrequently)
        Spacer()
      }
      .padding(.top, 10)
    }
  }

  static func clock(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
  }
}

/// How fast the phone moves, for sharp video: green bar, amber when quick, red when too fast
struct SpeedMeter: View {
  let value: Float
  let level: MotionMonitor.Level

  var body: some View {
    let color: Color = level == .tooFast ? .red : level == .fast ? .yellow : .green
    HStack(spacing: 5) {
      Image(systemName: level == .good ? "figure.walk" : "hare.fill").font(.caption2)
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.25))
        Capsule().fill(color).frame(width: 54 * CGFloat(min(1, max(0.05, value))))
      }
      .frame(width: 54, height: 6)
      .animation(.easeOut(duration: 0.15), value: value)
    }
    .padding(.horizontal, 8).padding(.vertical, 4)
    .background(.ultraThinMaterial, in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(level == .tooFast ? "Moving too fast" : level == .fast ? "Moving quickly" : "Speed good")
  }
}

/// How much of the scanned mesh the video and photos have captured well
struct CoverageRing: View {
  let percent: Int

  var body: some View {
    let color: Color = percent >= 80 ? .green : percent >= 50 ? .yellow : .orange
    VStack(spacing: 2) {
      ZStack {
        Circle().stroke(.white.opacity(0.25), lineWidth: 5)
        Circle().trim(from: 0, to: CGFloat(min(100, max(0, percent))) / 100)
          .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .animation(.easeOut(duration: 0.4), value: percent)
        Text("\(percent)%").font(.caption2.bold()).monospacedDigit()
      }
      .frame(width: 44, height: 44)
      Text("Captured").font(.system(size: 9)).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Captured \(percent) percent")
  }
}

/// The AR scan view (camera + colored LiDAR mesh + RoomPlan outlines)
struct ScanContainer: UIViewRepresentable {
  let view: ARSCNView
  func makeUIView(context: Context) -> ARSCNView { view }
  func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
