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
  let scan: ScanSummary
  @State private var exporting: String?
  @State private var share: ShareItem?
  @State private var quickLook: URL?
  @State private var error: String?
  @State private var copied = false

  private var m: Manifest? { scan.manifest }

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
      Section("Rooms") {
        ForEach(m?.rooms ?? []) { room in
          VStack(alignment: .leading) {
            Text(room.name.isEmpty ? "Room \(room.index + 1)" : room.name)
            Text("\(room.walls) walls · \(room.doors) doors · \(room.windows) windows · \(room.objects) objects")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        if let err = m?.structureError { Text("Floor plan merge failed: \(err)").font(.caption).foregroundStyle(.orange) }
      }
      Section("Captured") {
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
    .alert("Export failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
      Button("OK") {}
    } message: { Text(error ?? "") }
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
