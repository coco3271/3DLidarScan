import ARKit
import SwiftUI

/// Scanning: the camera with the LiDAR mesh drawn over it (red = needs photos, green =
/// captured), RoomPlan's outlines, a "Photo detail" ring, the live map and the controls.
struct CaptureScreen: View {
  @ObservedObject var controller: CaptureController
  @Environment(\.dismiss) private var dismiss
  @State private var askRoomName = false
  @State private var confirmExit = false

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
        hints
        bottom
      }
      .padding(.horizontal)
      .padding(.vertical, 8)
    }
    .statusBarHidden()
    .onAppear { if controller.phase == .ready { askRoomName = true } }
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
      Text("Walk slowly around the room. The mesh shows what the LiDAR has scanned: red parts still need photos, green parts are captured. Tap the shutter wherever you want a stop in the tour.")
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
      Button { confirmExit = true } label: {
        Image(systemName: "xmark").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
      }
      .disabled(controller.phase == .finishing)
      Spacer()
      VStack(alignment: .trailing, spacing: 8) {
        HStack(alignment: .center, spacing: 10) {
          CoverageRing(percent: controller.coveragePercent)
          VStack(alignment: .trailing, spacing: 2) {
            Text(controller.roomName).font(.headline).lineLimit(1)
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
        if let instruction = controller.instruction {
          hint(instruction, systemImage: "exclamationmark.triangle.fill", tint: .yellow)
        }
        if controller.paused {
          hint("Paused: no photos are taken. RoomPlan keeps tracking.", systemImage: "pause.circle.fill", tint: .orange)
        } else if controller.coverageStalled {
          hint("Photo detail isn't improving much. You can save the room, or point at the red areas.",
               systemImage: "checkmark.circle", tint: .green)
        } else {
          hint("Photos are saved automatically as you move. Point the camera at red areas until they turn green.",
               systemImage: "camera.aperture", tint: .white)
        }
        HStack(spacing: 12) {
          legend(.red, "needs photos")
          legend(.green, "captured")
          Spacer()
        }
      }
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

  // MARK: bottom

  @ViewBuilder private var bottom: some View {
    switch controller.phase {
    case .ready:
      Button("Start scanning") { askRoomName = true }.buttonStyle(.borderedProminent).controlSize(.large)
    case .scanning:
      HStack(spacing: 14) {
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
        Button("Save room") { controller.finishRoom() }
          .buttonStyle(.borderedProminent).tint(.blue).controlSize(.large)
      }
      .padding(10)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22))
    case .processingRoom:
      ProgressView("Building the room model…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    case .roomDone:
      VStack(spacing: 10) {
        Text("“\(controller.roomName)” saved · \(controller.coveragePercent)% photo detail").font(.headline)
        Text("Walk to the next room without closing the app so all rooms line up.").font(.caption).multilineTextAlignment(.center)
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

/// "Photo detail": how much of the scanned mesh the photos have captured well
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
      Text("Photo detail").font(.system(size: 9)).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Photo detail \(percent) percent")
  }
}

/// The AR scan view (camera + colored LiDAR mesh + RoomPlan outlines)
struct ScanContainer: UIViewRepresentable {
  let view: ARSCNView
  func makeUIView(context: Context) -> ARSCNView { view }
  func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
