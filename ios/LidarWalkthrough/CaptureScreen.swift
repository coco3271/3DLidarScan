import RoomPlan
import SwiftUI

struct CaptureScreen: View {
  @ObservedObject var controller: CaptureController
  @Environment(\.dismiss) private var dismiss
  @State private var askRoomName = false
  @State private var confirmExit = false

  var body: some View {
    ZStack {
      RoomCaptureContainer(view: controller.roomCaptureView).ignoresSafeArea()
      if controller.flash {
        Color.white.opacity(0.6).ignoresSafeArea().allowsHitTesting(false)
      }
      VStack(spacing: 12) {
        topBar
        if let warning = controller.warning {
          Text(warning).font(.footnote).padding(10).background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
        }
        Spacer()
        bottom
      }
      .padding()
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
      Text("Walk slowly along the walls, pointing at the floor/ceiling edges. Tap the shutter for a high-quality photo wherever you want a stop in the tour.")
    }
    .confirmationDialog("Stop scanning?", isPresented: $confirmExit, titleVisibility: .visible) {
      Button("Save finished rooms and exit") { Task { await controller.abandon() } }
      Button("Keep scanning", role: .cancel) {}
    } message: {
      Text("Rooms you already finished are kept. The room in progress is discarded.")
    }
  }

  private var topBar: some View {
    HStack(alignment: .top) {
      Button { confirmExit = true } label: {
        Image(systemName: "xmark").font(.headline).padding(12).background(.ultraThinMaterial, in: Circle())
      }
      .disabled(controller.phase == .finishing)
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text(controller.roomName).font(.headline)
        Text("\(controller.photoCount) photos · \(controller.manualPhotoCount) high-res · \(controller.depthFrameCount) depth")
          .font(.caption).monospacedDigit()
        Text(controller.location.accuracyText).font(.caption2).foregroundStyle(.secondary)
      }
      .padding(10)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
  }

  @ViewBuilder private var bottom: some View {
    switch controller.phase {
    case .ready:
      Button("Start scanning") { askRoomName = true }.buttonStyle(.borderedProminent).controlSize(.large)
    case .scanning:
      HStack {
        Button("Done with room") { controller.finishRoom() }
          .buttonStyle(.borderedProminent).tint(.green)
        Spacer()
        Button { controller.takePhoto() } label: {
          ZStack {
            Circle().fill(.white).frame(width: 66, height: 66)
            Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
            Image(systemName: "camera.fill").font(.title2).foregroundStyle(.black)
          }
        }
        .accessibilityLabel("Take high-quality photo")
        Spacer()
        Text("Shutter = tour stop").font(.caption2).frame(width: 90).multilineTextAlignment(.center)
      }
      .padding(12)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    case .processingRoom:
      ProgressView("Building the room model…").padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    case .roomDone:
      VStack(spacing: 10) {
        Text("“\(controller.roomName)” saved").font(.headline)
        Text("Walk to the next room without stopping the app so all rooms line up.").font(.caption).multilineTextAlignment(.center)
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

/// Apple's RoomPlan capture view (live camera + the room model drawing itself as you scan)
struct RoomCaptureContainer: UIViewRepresentable {
  let view: RoomCaptureView
  func makeUIView(context: Context) -> RoomCaptureView { view }
  func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
