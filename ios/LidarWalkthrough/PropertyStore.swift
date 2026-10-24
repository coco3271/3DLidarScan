import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScanSummary: Identifiable, Hashable {
  let url: URL
  let manifest: Manifest?
  var id: URL { url }
  var name: String { manifest?.property?.name ?? manifest?.houseName ?? url.lastPathComponent }
  var date: Date { manifest?.createdAt ?? .distantPast }

  static func == (a: ScanSummary, b: ScanSummary) -> Bool { a.url == b.url }
  func hash(into h: inout Hasher) { h.combine(url) }
}

/// Scans live in Documents/Scans/<name date>/ (visible in the Files app under
/// On My iPhone › 3D LiDAR Scan, so you can grab them without the share sheet too).
@MainActor
final class PropertyStore: ObservableObject {
  @Published private(set) var scans: [ScanSummary] = []

  let root: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = docs.appendingPathComponent("Scans", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  init() { reload() }

  func reload() {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    scans = dirs.filter { $0.hasDirectoryPath }.map { url in
      let manifest = (try? Data(contentsOf: url.appendingPathComponent("manifest.json")))
        .flatMap { try? BundleJSON.decoder.decode(Manifest.self, from: $0) }
      return ScanSummary(url: url, manifest: manifest)
    }
    .filter { $0.manifest != nil }
    .sorted { $0.date > $1.date }
  }

  func newFolder(name: String) -> URL {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH.mm.ss"
    let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return root.appendingPathComponent("\(safe.isEmpty ? "Property" : String(safe.prefix(60))) \(f.string(from: Date()))", isDirectory: true)
  }

  func delete(_ scan: ScanSummary) {
    try? FileManager.default.removeItem(at: scan.url)
    reload()
  }
}

/// Everything the zip needs besides the raw capture: the AI kit (instructions + scripts +
/// viewer) and a ready-to-open walkthrough.html.
enum ScanExporter {
  static var aiKit: URL? { Bundle.main.url(forResource: "ai-kit", withExtension: nil) }

  static var prompt: String {
    aiKit.flatMap { try? String(contentsOf: $0.appendingPathComponent("PROMPT.txt"), encoding: .utf8) }
      ?? "Rebuild an interactive 3D walkthrough of this property from the attached LiDAR scan zip. Read START_HERE.md first."
  }

  /// Zip the scan (plus _ai/, START_HERE.md, walkthrough.html) for sharing. Runs off the main thread.
  static func zip(_ folder: URL, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
    try await Task.detached(priority: .userInitiated) {
      let fm = FileManager.default
      if !fm.fileExists(atPath: folder.appendingPathComponent("walkthrough.html").path) {
        progress("Building walkthrough.html…")
        try WalkthroughBuilder.build(folder)
      }
      progress("Adding AI kit…")
      if let kit = aiKit {
        let dest = folder.appendingPathComponent("_ai", isDirectory: true)
        try? fm.removeItem(at: dest)
        try fm.copyItem(at: kit, to: dest)
        let start = folder.appendingPathComponent("START_HERE.md")
        try? fm.removeItem(at: start)
        try? fm.copyItem(at: kit.appendingPathComponent("START_HERE.md"), to: start)
      }
      progress("Compressing…")
      return try zipFolder(folder)
    }.value
  }

  static func zipFolder(_ folder: URL) throws -> URL {
    let fm = FileManager.default
    let shares = fm.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
    // zips can be GBs: drop ones from earlier exports (older than an hour; a share in progress is newer)
    for old in (try? fm.contentsOfDirectory(at: shares, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
      if let date = try? old.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
         date < Date().addingTimeInterval(-3600) { try? fm.removeItem(at: old) }
    }
    let dir = shares.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent("\(folder.lastPathComponent).zip")
    var result: Result<URL, Error> = .failure(CocoaError(.fileReadUnknown))
    var coordError: NSError?
    // NSFileCoordinator zips directories for .forUploading; the temp zip vanishes after the block
    NSFileCoordinator().coordinate(readingItemAt: folder, options: [.forUploading], error: &coordError) { zipURL in
      result = Result {
        do { try fm.moveItem(at: zipURL, to: dest) } catch { try fm.copyItem(at: zipURL, to: dest) }
        return dest
      }
    }
    if let coordError { throw coordError }
    return try result.get()
  }
}

/// Builds one offline walkthrough.html from a scan folder: the same template, viewer and
/// three.js bundle as ai-kit/make_walkthrough.py, with the scan data embedded as base64.
enum WalkthroughBuilder {
  static let maxPhotos = 60
  static let maxDepthFrames = 200
  static let photoEdge = 1600

  enum BuildError: LocalizedError {
    case missingKit, noManifest
    var errorDescription: String? {
      switch self {
      case .missingKit: return "The app is missing its walkthrough viewer files."
      case .noManifest: return "This scan has no manifest.json."
      }
    }
  }

  @discardableResult
  static func build(_ folder: URL, kit: URL? = ScanExporter.aiKit) throws -> URL {
    guard let kit else { throw BuildError.missingKit }
    let read = { (path: String) -> Data? in try? Data(contentsOf: folder.appendingPathComponent(path)) }
    guard let manifestData = read("manifest.json") else { throw BuildError.noManifest }
    let manifest = try BundleJSON.decoder.decode(Manifest.self, from: manifestData)
    var files: [String: Data] = ["manifest.json": manifestData]
    func add(_ path: String?) {
      guard let path, files[path] == nil, let data = read(path) else { return }
      files[path] = data
    }
    add(manifest.structure)
    for room in manifest.rooms { add(room.file) }
    add(manifest.mesh?.file ?? manifest.rooms.last(where: { $0.mesh != nil })?.mesh?.file)

    let photos = (read(manifest.photos)).flatMap { try? BundleJSON.decoder.decode([PhotoRecord].self, from: $0) } ?? []
    let manual = photos.filter(\.manual)
    let tour = evenly((manual.count >= 2 ? manual : photos).sorted { $0.timestamp < $1.timestamp }, maxPhotos)
    var kept: [PhotoRecord] = []
    for photo in tour {
      guard let data = read(photo.file) else { continue }
      files[photo.file] = shrink(data, edge: photoEdge) ?? data
      kept.append(photo)
    }
    files[manifest.photos] = try BundleJSON.encoder.encode(kept)

    let depthPath = manifest.depthFrames ?? "depth/frames.json"
    let allFrames = read(depthPath).flatMap { try? BundleJSON.decoder.decode([DepthRecord].self, from: $0) } ?? []
    let fm = FileManager.default
    let frames = evenly(allFrames.filter { f in
      f.rgb.map { fm.fileExists(atPath: folder.appendingPathComponent($0).path) } ?? false
    }, maxDepthFrames)
    for f in frames { add(f.file); add(f.confidence); add(f.rgb) }
    files[depthPath] = try BundleJSON.encoder.encode(frames)

    let payload: [String: Any] = [
      "files": files.mapValues { $0.base64EncodedString() },
      "three": try Data(contentsOf: kit.appendingPathComponent("walkthrough/three.bundle.min.js")).base64EncodedString(),
      "viewer": try Data(contentsOf: kit.appendingPathComponent("walkthrough/viewer.js")).base64EncodedString(),
    ]
    // JSONSerialization escapes "/" so "</script>" can't appear in the embedded data
    let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    let template = try String(contentsOf: kit.appendingPathComponent("walkthrough/template.html"), encoding: .utf8)
    let title = (manifest.property?.name ?? manifest.houseName ?? "Property walkthrough")
      .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    let html = template.replacingOccurrences(of: "__TITLE__", with: title).replacingOccurrences(of: "__DATA__", with: json)
    let out = folder.appendingPathComponent("walkthrough.html")
    try html.write(to: out, atomically: true, encoding: .utf8)
    return out
  }

  static func evenly<T>(_ items: [T], _ limit: Int) -> [T] {
    guard limit > 0, items.count > limit else { return items }
    let step = Double(items.count) / Double(limit)
    return (0..<limit).map { items[Int(Double($0) * step)] }
  }

  /// Downscale a JPEG keeping its raw sensor orientation and metadata (EXIF orientation, GPS)
  static func shrink(_ data: Data, edge: Int) -> Data? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
          let w = props[kCGImagePropertyPixelWidth as String] as? Int, let h = props[kCGImagePropertyPixelHeight as String] as? Int,
          max(w, h) > edge else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: false, // intrinsics are for the unrotated pixels
      kCGImageSourceThumbnailMaxPixelSize: edge,
    ]
    guard let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    var meta = props
    meta[kCGImageDestinationLossyCompressionQuality as String] = 0.85
    meta.removeValue(forKey: kCGImagePropertyPixelWidth as String)
    meta.removeValue(forKey: kCGImagePropertyPixelHeight as String)
    CGImageDestinationAddImage(dest, thumb, meta as CFDictionary)
    return CGImageDestinationFinalize(dest) ? out as Data : nil
  }
}
