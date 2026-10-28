import Foundation
import SwiftUI

/// "Process World": send a scan to the processing server (ai-kit/splat/server.py on a machine
/// with an NVIDIA GPU), follow the job, and download the photoreal World (Gaussian splats) when
/// it's ready: playcanvas.html (PlayCanvas viewer), splat.html (dollhouse + photo compare) and
/// scene.sog. Results live in Documents/Worlds/<scan>/, next to (not inside) the scan, so they
/// aren't zipped up with it again. The job id is saved there too, so leaving the screen (or the
/// app) and coming back picks the job up again.
@MainActor
final class WorldJob: ObservableObject {
  enum State: Equatable {
    case idle
    case packing(String)
    case uploading(Double)
    case processing(step: String, progress: Double, position: Int)
    case downloading
    case done
    case failed(String)
  }

  struct Saved: Codable {
    var id: String
    var server: String
    var quality: String
    var started: Date
  }

  @Published private(set) var state: State = .idle
  let scan: URL
  let dir: URL
  private var polling: Task<Void, Never>?

  init(scan: URL) {
    self.scan = scan
    let docs = scan.deletingLastPathComponent().deletingLastPathComponent()
    dir = docs.appendingPathComponent("Worlds", isDirectory: true).appendingPathComponent(scan.lastPathComponent, isDirectory: true)
    if hasWorld { state = .done }
  }

  var playcanvas: URL { dir.appendingPathComponent("playcanvas.html") }
  var splatViewer: URL { dir.appendingPathComponent("splat.html") }
  var hasWorld: Bool {
    FileManager.default.fileExists(atPath: playcanvas.path) || FileManager.default.fileExists(atPath: splatViewer.path)
  }
  var busy: Bool {
    switch state {
    case .packing, .uploading, .processing, .downloading: return true
    default: return false
    }
  }

  private var savedURL: URL { dir.appendingPathComponent("job.json") }

  /// A job started earlier (the app was closed while it ran): follow it again
  func resumeIfNeeded(server: Server) {
    guard polling == nil, !busy, let data = try? Data(contentsOf: savedURL),
          let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.server == server.base.absoluteString else { return }
    polling = Task { await follow(saved.id, server: server); polling = nil }
  }

  func start(server: Server, quality: String, aiRepair: Bool) {
    guard !busy else { return }
    polling = Task {
      do {
        state = .packing("Preparing the scan…")
        let zip = try await ScanExporter.zip(scan) { step in Task { @MainActor in self.state = .packing(step) } }
        defer { try? FileManager.default.removeItem(at: zip) }
        state = .uploading(0)
        let id = try await server.upload(zip, quality: quality, fixer: aiRepair ? "difix" : "none") { p in
          Task { @MainActor in if case .uploading = self.state { self.state = .uploading(p) } }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(Saved(id: id, server: server.base.absoluteString, quality: quality, started: Date())).write(to: savedURL)
        await follow(id, server: server)
      } catch {
        state = .failed(error.localizedDescription)
      }
      polling = nil
    }
  }

  func cancelFollowing() {
    polling?.cancel()
    polling = nil
    if busy { state = hasWorld ? .done : .idle }
  }

  private func follow(_ id: String, server: Server) async {
    do {
      while !Task.isCancelled {
        let job = try await server.status(id)
        switch job.state {
        case "done":
          state = .downloading
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          for name in job.files ?? [] where ["playcanvas.html", "splat.html", "scene.sog", "metrics.json"].contains(name) {
            try await server.download(id, file: name, to: dir.appendingPathComponent(name))
          }
          try? FileManager.default.removeItem(at: savedURL)
          state = .done
          return
        case "failed":
          try? FileManager.default.removeItem(at: savedURL)
          state = .failed(job.error ?? "Processing failed")
          return
        default:
          state = .processing(step: job.step ?? "Waiting", progress: job.progress ?? 0, position: job.position ?? 0)
        }
        try await Task.sleep(nanoseconds: 4_000_000_000)
      }
    } catch is CancellationError {
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  /// The processing server's HTTP API
  struct Server {
    let base: URL
    let token: String

    struct Job: Decodable {
      var id: String?
      var state: String
      var step: String?
      var progress: Double?
      var position: Int?
      var error: String?
      var files: [String]?
    }

    struct ServerError: LocalizedError {
      let message: String
      var errorDescription: String? { message }
    }

    init?(url: String, token: String) {
      let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
      guard let u = URL(string: trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed),
            let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil else { return nil }
      base = u
      self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
      var r = URLRequest(url: URL(string: base.absoluteString + path)!)
      r.httpMethod = method
      if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
      return r
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
      guard let http = response as? HTTPURLResponse else { throw ServerError(message: "No response from the server") }
      guard (200..<300).contains(http.statusCode) else {
        let msg = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
        throw ServerError(message: http.statusCode == 401 ? "The server rejected the token" : msg ?? "Server error \(http.statusCode)")
      }
    }

    func health() async throws -> String {
      let (data, response) = try await URLSession.shared.data(for: request("/health"))
      try check(data, response)
      let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      return (obj?["gpu"] as? String).map { "Connected · \($0)" } ?? "Connected · no NVIDIA GPU found on the server"
    }

    func upload(_ zip: URL, quality: String, fixer: String, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
      var r = request("/jobs?quality=\(quality)&fixer=\(fixer)", method: "POST")
      r.setValue("application/zip", forHTTPHeaderField: "Content-Type")
      r.timeoutInterval = 3600
      let (data, response) = try await URLSession.shared.upload(for: r, fromFile: zip, delegate: UploadProgress(progress))
      try check(data, response)
      guard let id = try JSONDecoder().decode(Job.self, from: data).id else { throw ServerError(message: "The server didn't start a job") }
      return id
    }

    func status(_ id: String) async throws -> Job {
      let (data, response) = try await URLSession.shared.data(for: request("/jobs/\(id)"))
      try check(data, response)
      return try JSONDecoder().decode(Job.self, from: data)
    }

    func download(_ id: String, file: String, to dest: URL) async throws {
      let (tmp, response) = try await URLSession.shared.download(for: request("/jobs/\(id)/files/\(file)"))
      try check(Data(), response)
      try? FileManager.default.removeItem(at: dest)
      try FileManager.default.moveItem(at: tmp, to: dest)
    }
  }
}

/// Reports upload progress (0…1)
final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let report: @Sendable (Double) -> Void
  init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

  func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                  totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
    guard totalBytesExpectedToSend > 0 else { return }
    report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
  }
}
