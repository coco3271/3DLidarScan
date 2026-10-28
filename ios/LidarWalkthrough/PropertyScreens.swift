import AVKit
import QuickLook
import SwiftUI
import WebKit

struct PropertyListScreen: View {
  @EnvironmentObject private var store: PropertyStore
  @State private var askName = false
  @State private var newName = ""
  @State private var capture: CaptureController?

  var body: some View {
    NavigationStack {
      List {
        if !CaptureController.isSupported {
          Section {
            Label("Scanning needs an iPhone or iPad with a LiDAR scanner (Pro models, iOS 17+). You can still open and export scans here.",
                  systemImage: "exclamationmark.triangle")
          }
        }
        Section {
          ForEach(store.scans) { scan in
            NavigationLink(value: scan) {
              VStack(alignment: .leading, spacing: 3) {
                Text(scan.name).font(.headline)
                Text(summary(scan)).font(.caption).foregroundStyle(.secondary)
              }
            }
          }
          .onDelete { offsets in offsets.map { store.scans[$0] }.forEach(store.delete) }
        }
      }
      .overlay {
        if store.scans.isEmpty {
          ContentUnavailableView("No scans yet", systemImage: "cube.transparent",
                                 description: Text("Tap + to scan a property room by room."))
        }
      }
      .navigationTitle("Property Scans")
      .navigationDestination(for: ScanSummary.self) { PropertyDetailScreen(scan: $0) }
      .toolbar {
        Button { newName = ""; askName = true } label: { Label("New scan", systemImage: "plus") }
          .disabled(!CaptureController.isSupported)
      }
      .alert("New property scan", isPresented: $askName) {
        TextField("Address or name", text: $newName)
        Button("Continue") {
          let name = newName.trimmingCharacters(in: .whitespaces).isEmpty ? "Property" : newName
          capture = CaptureController(folder: store.newFolder(name: name), propertyName: name)
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("GPS and the street address are added automatically.")
      }
      .fullScreenCover(item: $capture, onDismiss: { store.reload() }) { CaptureScreen(controller: $0) }
      .refreshable { store.reload() }
    }
  }

  static func minutes(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    return s < 60 ? "\(s) s" : String(format: "%d:%02d", s / 60, s % 60)
  }

  private func summary(_ scan: ScanSummary) -> String {
    guard let m = scan.manifest else { return "" }
    return [
      m.createdAt.formatted(date: .abbreviated, time: .shortened),
      "\(m.rooms.count) room\(m.rooms.count == 1 ? "" : "s")",
      m.videos.flatMap { v in
        v.isEmpty ? nil : "\(Self.minutes(v.reduce(0) { $0 + $1.duration })) video"
      } ?? "\(m.photoCount) photos",
      m.property?.address,
    ].compactMap { $0 }.joined(separator: " · ")
  }
}

extension CaptureController: Identifiable {}

struct PropertyDetailScreen: View {
  @EnvironmentObject private var store: PropertyStore
  let scan: ScanSummary
  @State private var exporting: String?
  @State private var share: ShareItem?
  @State private var quickLook: URL?
  @State private var error: String?
  @State private var copied = false
  @State private var playing: ShareItem?
  @State private var capture: CaptureController?
  @StateObject private var world: WorldJob
  @State private var showServer = false
  @AppStorage("worldServerURL") private var serverURL = ""
  @AppStorage("worldServerToken") private var serverToken = ""
  @AppStorage("worldQuality") private var quality = "standard"
  @AppStorage("worldAIRepair") private var aiRepair = true

  init(scan: ScanSummary) {
    self.scan = scan
    _world = StateObject(wrappedValue: WorldJob(scan: scan.url))
  }

  /// the scan as it is now (Continue scanning changes it)
  private var current: ScanSummary { store.scans.first { $0.url == scan.url } ?? scan }
  private var m: Manifest? { current.manifest }
  private var server: WorldJob.Server? { WorldJob.Server(url: serverURL, token: serverToken) }

  var body: some View {
    List {
      Section("Property") {
        LabeledContent("Name", value: scan.name)
        if let address = m?.property?.address { LabeledContent("Address", value: address) }
        if let p = m?.property, let lat = p.latitude, let lon = p.longitude {
          Link(destination: URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)&q=\(scan.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) {
            LabeledContent("GPS", value: String(format: "%.5f, %.5f ±%.0f m", lat, lon, p.horizontalAccuracy ?? 0))
          }
        }
        if let m { LabeledContent("Scanned", value: m.createdAt.formatted(date: .abbreviated, time: .shortened)) }
      }
      Section {
        ForEach(m?.rooms ?? []) { room in
          VStack(alignment: .leading, spacing: 4) {
            Text(room.name.isEmpty ? "Room \(room.index + 1)" : room.name)
            Text("\(room.walls) walls · \(room.doors) doors · \(room.windows) windows · \(room.objects) objects")
              .font(.caption).foregroundStyle(.secondary)
            let videos = (m?.videos ?? []).filter { $0.room == room.index }
            if !videos.isEmpty {
              HStack {
                ForEach(Array(videos.enumerated()), id: \.offset) { i, v in
                  Button { playing = ShareItem(url: current.url.appendingPathComponent(v.file)) } label: {
                    Label(videos.count > 1 ? "Part \(i + 1) · \(PropertyListScreen.minutes(v.duration))" : PropertyListScreen.minutes(v.duration),
                          systemImage: "play.rectangle.fill")
                  }
                  .buttonStyle(.bordered).controlSize(.small)
                }
              }
            }
          }
        }
        if let err = m?.structureError { Text("Floor plan merge failed: \(err)").font(.caption).foregroundStyle(.orange) }
        Button {
          if let c = CaptureController(continuing: current.url) { capture = c } else {
            error = "This scan can't be continued: it was saved without ARKit's world map (scans from before this version), so new rooms wouldn't line up."
          }
        } label: { Label("Continue scanning (add or rescan rooms)", systemImage: "plus.viewfinder") }
        .disabled(m?.worldMap == nil || !CaptureController.isSupported)
      } header: { Text("Rooms") } footer: {
        Text("Continue scanning recognizes the place from the saved scan, so new rooms line up with these. Start it where you left off.")
      }
      worldSection
      Section("Captured") {
        if let videos = m?.videos, !videos.isEmpty {
          LabeledContent("Video", value: "\(PropertyListScreen.minutes(videos.reduce(0) { $0 + $1.duration })) · \(videos.reduce(0) { $0 + $1.frameCount }.formatted()) frames")
        }
        LabeledContent("Photos", value: "\(m?.photoCount ?? 0)")
        LabeledContent("LiDAR depth frames", value: "\(m?.depthFrameCount ?? 0)")
        if let mesh = m?.mesh { LabeledContent("LiDAR mesh", value: "\(mesh.faces.formatted()) triangles") }
      }
      Section {
        NavigationLink { WalkthroughScreen(folder: scan.url, title: scan.name) } label: {
          Label("Walk through in 3D", systemImage: "figure.walk")
        }
        NavigationLink { PhotoMapScreen(folder: scan.url) } label: {
          Label("Photo map (where each photo was taken)", systemImage: "map")
        }
        Button { quickLook = appleModel } label: { Label("Apple RoomPlan model", systemImage: "cube") }
          .disabled(appleModel == nil)
      }
      Section {
        Button { Task { await export() } } label: {
          HStack {
            Label("Export ZIP for Claude / ChatGPT", systemImage: "square.and.arrow.up")
            if let exporting { Spacer(); ProgressView(); Text(exporting).font(.caption) }
          }
        }
        .disabled(exporting != nil)
        Button {
          UIPasteboard.general.string = ScanExporter.prompt
          copied = true
        } label: { Label(copied ? "Prompt copied" : "Copy AI prompt", systemImage: copied ? "checkmark" : "doc.on.doc") }
      } footer: {
        Text("Attach the ZIP to a chat, paste the prompt, and the AI rebuilds the walkthrough. The ZIP also contains a ready-made walkthrough.html you can open in any browser.")
      }
    }
    .navigationTitle(scan.name)
    .navigationBarTitleDisplayMode(.inline)
    .quickLookPreview($quickLook)
    .sheet(item: $share) { ActivityView(items: [$0.url]) }
    .sheet(item: $playing) { item in
      VideoPlayer(player: AVPlayer(url: item.url)).ignoresSafeArea()
    }
    .sheet(isPresented: $showServer) { ServerSettings(url: $serverURL, token: $serverToken) }
    .fullScreenCover(item: $capture, onDismiss: { store.reload() }) { CaptureScreen(controller: $0) }
    .onAppear { if let server { world.resumeIfNeeded(server: server) } }
    .alert("Export failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK") {}
    } message: { Text(error ?? "") }
  }

  // MARK: Process World

  @ViewBuilder private var worldSection: some View {
    Section {
      switch world.state {
      case .idle, .failed:
        if case .failed(let message) = world.state {
          Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout)
        }
        Picker("Quality", selection: $quality) {
          Text("Preview (fast)").tag("preview")
          Text("Standard").tag("standard")
          Text("High").tag("high")
        }
        Toggle("Fill gaps with generative AI", isOn: $aiRepair)
        Button {
          if let server { world.start(server: server, quality: quality, aiRepair: aiRepair) } else { showServer = true }
        } label: { Label("Process World", systemImage: "sparkles") }
        .disabled((m?.videos ?? []).isEmpty && (m?.photoCount ?? 0) == 0)
      case .packing(let step):
        progressRow(step, nil)
      case .uploading(let p):
        progressRow("Uploading…", p)
      case .processing(let step, let p, let position):
        progressRow(position > 0 ? "Waiting in line (\(position) ahead)" : step, p)
        Button("Stop following (the server keeps going)", role: .cancel) { world.cancelFollowing() }
          .font(.caption)
      case .downloading:
        progressRow("Downloading the World…", nil)
      case .done:
        NavigationLink { WorldViewerScreen(file: world.playcanvas, folder: world.dir, title: current.name) } label: {
          Label("View World", systemImage: "view.3d")
        }
        .disabled(!FileManager.default.fileExists(atPath: world.playcanvas.path))
        NavigationLink { WorldViewerScreen(file: world.splatViewer, folder: world.dir, title: current.name) } label: {
          Label("Dollhouse & photo compare", systemImage: "square.split.bottomrightquarter")
        }
        .disabled(!FileManager.default.fileExists(atPath: world.splatViewer.path))
        Button { share = ShareItem(url: FileManager.default.fileExists(atPath: world.playcanvas.path) ? world.playcanvas : world.splatViewer) } label: {
          Label("Share World", systemImage: "square.and.arrow.up")
        }
        Button { if let server { world.start(server: server, quality: quality, aiRepair: aiRepair) } else { showServer = true } } label: {
          Label("Process again", systemImage: "arrow.clockwise")
        }
      }
      Button { showServer = true } label: {
        LabeledContent("Processing server", value: server?.base.host ?? "Not set up")
      }
    } header: { Text("Photoreal World") } footer: {
      Text("Turns the room videos into a photoreal 3D World (Gaussian splats) on your processing server, a computer with an NVIDIA GPU running ai-kit/splat/server.py. Standard quality takes about 20–40 minutes per house. You can leave this screen; progress picks up when you come back.")
    }
  }

  private func progressRow(_ text: String, _ value: Double?) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(text).font(.callout)
      if let value { ProgressView(value: value) } else { ProgressView() }
    }
  }

  private var appleModel: URL? {
    let fm = FileManager.default
    let candidates = ["structure.usdz"] + (m?.rooms.map(\.usdz) ?? [])
    return candidates.map { scan.url.appendingPathComponent($0) }.first { !$0.lastPathComponent.isEmpty && fm.fileExists(atPath: $0.path) }
  }

  private func export() async {
    exporting = "Preparing…"
    defer { exporting = nil }
    do {
      // a late progress message must not bring the spinner back after the export finished
      let url = try await ScanExporter.zip(scan.url) { step in Task { @MainActor in if exporting != nil { exporting = step } } }
      share = ShareItem(url: url)
    } catch {
      self.error = error.localizedDescription
    }
  }
}

struct ShareItem: Identifiable {
  let id = UUID()
  let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
  let items: [Any]
  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }
  func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The same walkthrough the AI kit produces, built on the phone and shown in a web view
struct WalkthroughScreen: View {
  let folder: URL
  let title: String
  @State private var html: URL?
  @State private var error: String?

  var body: some View {
    Group {
      if let html {
        WebView(file: html, readAccess: folder).ignoresSafeArea(edges: .bottom)
      } else if let error {
        ContentUnavailableView("Can't build the walkthrough", systemImage: "exclamationmark.triangle", description: Text(error))
      } else {
        ProgressView("Building walkthrough…")
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.inline)
    .task {
      let folder = folder
      do {
        html = try await Task.detached(priority: .userInitiated) {
          let existing = folder.appendingPathComponent("walkthrough.html")
          if FileManager.default.fileExists(atPath: existing.path) { return existing }
          return try WalkthroughBuilder.build(folder)
        }.value
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}

struct WebView: UIViewRepresentable {
  let file: URL
  let readAccess: URL

  func makeUIView(context: Context) -> WKWebView {
    let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    view.isOpaque = false
    view.backgroundColor = .black
    view.scrollView.isScrollEnabled = false
    view.loadFileURL(file, allowingReadAccessTo: readAccess)
    return view
  }

  func updateUIView(_ view: WKWebView, context: Context) {}
}

/// A World (or any offline HTML viewer) in a web view
struct WorldViewerScreen: View {
  let file: URL
  let folder: URL
  let title: String

  var body: some View {
    WebView(file: file, readAccess: folder)
      .ignoresSafeArea(edges: .bottom)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
  }
}

/// Where the processing server is
struct ServerSettings: View {
  @Binding var url: String
  @Binding var token: String
  @Environment(\.dismiss) private var dismiss
  @State private var status: String?
  @State private var testing = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("https://your-server.example.com", text: $url)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
          SecureField("Token", text: $token)
        } footer: {
          Text("On a computer with an NVIDIA GPU: python3 ai-kit/splat/server.py --host 0.0.0.0 --token <a long secret>, reachable over HTTPS (for example with a Cloudflare or Tailscale tunnel). See BUILD_SPLAT.md.")
        }
        Section {
          Button {
            Task {
              testing = true
              defer { testing = false }
              guard let server = WorldJob.Server(url: url, token: token) else { status = "That isn't a valid http(s) address"; return }
              do { status = try await server.health() } catch { status = error.localizedDescription }
            }
          } label: { HStack { Text("Test connection"); if testing { Spacer(); ProgressView() } } }
          if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
        }
      }
      .navigationTitle("Processing server")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Done") { dismiss() } }
    }
  }
}
