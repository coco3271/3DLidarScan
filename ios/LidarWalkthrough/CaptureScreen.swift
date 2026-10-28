import ARKit
import SwiftUI

/// Scanning: the camera with the LiDAR mesh drawn over it (red = not captured yet, green =
/// captured), RoomPlan's outlines, a coverage ring, the recording time, a speed meter that
/// warns when the phone moves too fast for sharp video, the live map and the controls.
struct CaptureScreen: View {
  @ObservedObject var controller: CaptureController
  @Environment(\.dismiss) private var dismiss
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
      VStack(spacing: 10) {
        topBar
        if let warning = controller.warning {
          Text(warning).font(.footnote).padding(10).background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        }
        Spacer()
        if controller.phase == .scanning && controller.motion == .tooFast && !controller.paused {
          slowDown
        }
        hints
        bottom
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
    .statusBarHidden()
    .onAppear {
      guard controller.phase == .ready else { return }
      if tutorialSeen { askRoomName = true } else { showTutorial = true }
    }
    .sheet(isPresented: $showTutorial, onDismiss: {
      tutorialSeen = true
      if controller.phase == .ready { askRoomName = true }
    }) {
      ScanTutorial { showTutorial = false }
    }
    .animation(.easeOut(duration: 0.2), value: controller.motion)
    .onChange(of: controller.phase) { _, phase in
      switch phase {
      case .finished, .failed: dismiss()
      default: break
      }
    }
    .alert("Name this room", isPresented: $askRoomName) {
      TextField("Kitchen, Living room…", text: $controller.roomName)
      Button("Start scanning") { controller.startRoom() }
      if controller.phase == .ready { Button("Cancel", role: .cancel) { Task { await controller.abandon() } } }
    } message: {
      Text("Film the room slowly, like a smooth video: high, middle and low. Red parts aren't captured yet; keep filming them until they turn green. Tap the shutter wherever you want a stop in the tour.")
    }
    .confirmationDialog("Stop scanning?", isPresented: $confirmExit, titleVisibility: .visible) {
      Button("Save finished rooms and exit") { Task { await controller.abandon() } }
      Button("Keep scanning", role: .cancel) {}
    } message: {
      Text("Rooms you already saved are kept. The room in progress is discarded.")
    }
  }

  // MARK: top

  private var topBar: some View {
    HStack(alignment: .top) {
      VStack(spacing: 8) {
        Button { confirmExit = true } label: {
          Image(systemName: "xmark").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
        }
        .disabled(controller.phase == .finishing)
        Button { showTutorial = true } label: {
          Image(systemName: "questionmark").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel("How to scan")
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 8) {
        HStack(alignment: .center, spacing: 10) {
          CoverageRing(percent: controller.coveragePercent)
          VStack(alignment: .trailing, spacing: 2) {
            Text(controller.roomName).font(.headline).lineLimit(1)
            if controller.phase == .scanning {
              HStack(spacing: 4) {
                Circle().fill(controller.paused ? .gray : .red).frame(width: 7, height: 7)
                Text("\(controller.paused ? "PAUSED" : "REC") \(Self.clock(controller.videoSeconds))")
              }
              .font(.caption.bold()).monospacedDigit()
            }
            Text("\(controller.photoCount) photos · \(controller.manualPhotoCount) high-res")
              .font(.caption).monospacedDigit()
            Text("\(controller.depthFrameCount) depth · \(controller.location.accuracyText)")
              .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
          }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        if controller.phase == .scanning || controller.phase == .roomDone {
          // live map: green = you, yellow cones = photos (bright = shutter shots)
          PlanCanvas(trail: controller.trail, spots: controller.photoSpots, here: controller.here, minSpan: 3)
            .frame(width: 120, height: 120)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
        }
      }
    }
  }

  // MARK: hints

  @ViewBuilder private var hints: some View {
    if controller.phase == .scanning {
      VStack(spacing: 6) {
        if controller.meshAnchors == 0 {
          hint("Waiting for the LiDAR mesh… move the phone slowly around the room.",
               systemImage: "hourglass", tint: .white)
        }
        if let instruction = controller.instruction {
          hint(instruction, systemImage: "exclamationmark.triangle.fill", tint: .yellow)
        }
        if controller.paused {
          hint("Paused: no photos are taken. RoomPlan keeps tracking.", systemImage: "pause.circle.fill", tint: .orange)
        } else if controller.coverageStalled {
          hint("Photo detail isn't improving much. You can save the room, or point at the red areas.",
               systemImage: "checkmark.circle", tint: .green)
        } else {
          hint("Recording. Walk slowly and film red areas from a few angles until they turn green.",
               systemImage: "video.fill", tint: .red)
        }
        HStack(spacing: 12) {
          legend(.red, "not captured")
          legend(.green, "captured")
          Spacer()
          SpeedMeter(value: controller.speedMeter, level: controller.motion)
        }
      }
    }
  }

  /// The "too fast" warning: big, red, impossible to miss
  private var slowDown: some View {
    Label("Slow down: moving too fast for a sharp video", systemImage: "tortoise.fill")
      .font(.headline)
      .padding(.horizontal, 14).padding(.vertical, 10)
      .frame(maxWidth: .infinity)
      .background(.red.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
      .transition(.scale.combined(with: .opacity))
      .accessibilityAddTraits(.updatesFrequently)
  }

  static func clock(_ t: TimeInterval) -> String {
    let s = Int(t.rounded(.down))
    return String(format: "%d:%02d", s / 60, s % 60)
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

  // MARK: bottom

  @ViewBuilder private var bottom: some View {
    switch controller.phase {
    case .ready:
      Button("Start scanning") { askRoomName = true }.buttonStyle(.borderedProminent).controlSize(.large)
    case .scanning:
      HStack(spacing: 10) {
        Button { controller.togglePause() } label: {
          Image(systemName: controller.paused ? "play.fill" : "pause.fill").font(.title3).frame(width: 46, height: 46)
            .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(controller.paused ? "Resume photos" : "Pause photos")
        Button { controller.meshVisible.toggle() } label: {
          Image(systemName: controller.meshVisible ? "square.grid.3x3.fill" : "square.grid.3x3").font(.title3)
            .frame(width: 46, height: 46).background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(controller.meshVisible ? "Hide the scan mesh" : "Show the scan mesh")
        Spacer()
        Button { controller.takePhoto() } label: {
          ZStack {
            Circle().fill(.white).frame(width: 62, height: 62)
            Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
            Image(systemName: "camera.fill").font(.title2).foregroundStyle(.black)
          }
        }
        .accessibilityLabel("Take a full-resolution photo (tour stop)")
        Spacer()
        Button { controller.finishRoom() } label: {
          Text("Save room").lineLimit(1).fixedSize()
        }
        .buttonStyle(.borderedProminent).tint(.blue).controlSize(.large)
        .layoutPriority(1)
      }
      .padding(10)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    case .processingRoom:
      ProgressView("Building the room model…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    case .roomDone:
      VStack(spacing: 10) {
        Text("“\(controller.roomName)” saved · \(controller.coveragePercent)% captured · \(Self.clock(controller.videoSeconds)) video").font(.headline)
        Text("Recording has stopped for this room, so the colors no longer change. Walk to the next room without closing the app so all rooms line up.")
          .font(.caption).multilineTextAlignment(.center)
        HStack {
          Button("Scan next room") {
            controller.prepareNextRoom()
            askRoomName = true
          }
          .buttonStyle(.borderedProminent)
          Button("Finish property") { Task { await controller.finishProperty() } }
            .buttonStyle(.bordered)
        }
      }
      .padding()
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    case .finishing:
      ProgressView(controller.finishingStep).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    case .finished, .failed:
      EmptyView()
    }
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
