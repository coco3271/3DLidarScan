import SwiftUI
import simd

/// Top-down floor plan: RoomPlan walls/doors/windows, the path you walked, and every photo as
/// a position + direction cone. World x → right, world z → down (seen from above).
struct PlanCanvas: View {
  var walls: [PlanSegment] = []
  var openings: [PlanSegment] = []
  var trail: [SIMD2<Float>] = []
  var spots: [MapSpot] = []
  var here: MapSpot?
  var selected: Int?
  var minSpan: Float = 4
  var onTap: ((Int) -> Void)?

  var body: some View {
    GeometryReader { geo in
      let fit = PlanFit(points: allPoints, size: geo.size, minSpan: minSpan)
      Canvas { ctx, _ in
        var path = Path()
        for (i, p) in trail.enumerated() {
          if i == 0 { path.move(to: fit.map(p)) } else { path.addLine(to: fit.map(p)) }
        }
        ctx.stroke(path, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
        for w in walls {
          var p = Path(); p.move(to: fit.map(w.a)); p.addLine(to: fit.map(w.b))
          ctx.stroke(p, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
        for o in openings {
          var p = Path(); p.move(to: fit.map(o.a)); p.addLine(to: fit.map(o.b))
          ctx.stroke(p, with: .color(o.kind == "window" ? .cyan : .orange), style: StrokeStyle(lineWidth: 5))
        }
        for (i, s) in spots.enumerated() {
          let color: Color = i == selected ? .pink : (s.manual ? .yellow : .yellow.opacity(0.35))
          drawCone(ctx, s, fit: fit, length: s.manual ? 22 : 12, color: color)
        }
        if let here { drawCone(ctx, here, fit: fit, length: 26, color: .green) }
      }
      .contentShape(Rectangle())
      .onTapGesture { location in
        guard let onTap else { return }
        let hit = spots.enumerated()
          .map { ($0.offset, hypot(fit.map($0.element.point).x - location.x, fit.map($0.element.point).y - location.y)) }
          .filter { $0.1 < 30 }
          .min { $0.1 < $1.1 }
        if let hit { onTap(hit.0) }
      }
    }
  }

  private var allPoints: [SIMD2<Float>] {
    walls.flatMap { [$0.a, $0.b] } + trail + spots.map(\.point) + (here.map { [$0.point] } ?? [])
  }

  private func drawCone(_ ctx: GraphicsContext, _ s: MapSpot, fit: PlanFit, length: CGFloat, color: Color) {
    let c = fit.map(s.point)
    // forward on the plan: (-sin yaw, -cos yaw) in (x, z) = screen (x, y)
    func dir(_ a: Float) -> CGPoint { CGPoint(x: CGFloat(-sin(a)), y: CGFloat(-cos(a))) }
    let half: Float = 0.45
    let l = dir(s.yaw + half), r = dir(s.yaw - half)
    var cone = Path()
    cone.move(to: c)
    cone.addLine(to: CGPoint(x: c.x + l.x * length, y: c.y + l.y * length))
    cone.addLine(to: CGPoint(x: c.x + r.x * length, y: c.y + r.y * length))
    cone.closeSubpath()
    ctx.fill(cone, with: .color(color.opacity(0.75)))
    ctx.stroke(cone, with: .color(.black.opacity(0.6)), lineWidth: 1)
    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(color))
    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)), with: .color(.black), lineWidth: 1)
  }
}

struct PlanSegment {
  var a: SIMD2<Float>
  var b: SIMD2<Float>
  var kind = "wall"
}

/// Uniform scale + offset that fits the points into the view, north/-Z up
struct PlanFit {
  let scale: CGFloat
  let offset: CGPoint
  let center: SIMD2<Float>

  init(points: [SIMD2<Float>], size: CGSize, minSpan: Float, padding: CGFloat = 28) {
    var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
    for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
    if points.isEmpty { lo = .zero; hi = .zero }
    center = (lo + hi) / 2
    let span = simd_max(hi - lo, SIMD2(repeating: minSpan))
    scale = min((size.width - padding * 2) / CGFloat(span.x), (size.height - padding * 2) / CGFloat(span.y))
    offset = CGPoint(x: size.width / 2, y: size.height / 2)
  }

  func map(_ p: SIMD2<Float>) -> CGPoint {
    CGPoint(x: offset.x + CGFloat(p.x - center.x) * scale, y: offset.y + CGFloat(p.y - center.y) * scale)
  }
}

/// Reads a saved scan's floor plan (structure.json, or every room-N.json) and photo poses
struct ScanPlan {
  var walls: [PlanSegment] = []
  var openings: [PlanSegment] = []
  var photos: [PhotoRecord] = []
  var spots: [MapSpot] = []

  private struct Surface: Decodable {
    var transform: [Float]
    var dimensions: [Float]
  }

  private struct RoomFile: Decodable {
    var walls: [Surface]?
    var doors: [Surface]?
    var windows: [Surface]?
    var openings: [Surface]?
  }

  init(folder: URL) {
    let read = { (path: String) -> Data? in try? Data(contentsOf: folder.appendingPathComponent(path)) }
    guard let manifest = read("manifest.json").flatMap({ try? BundleJSON.decoder.decode(Manifest.self, from: $0) }) else { return }
    let files = manifest.structure.map { [$0] } ?? manifest.rooms.map(\.file)
    for file in files {
      guard let room = read(file).flatMap({ try? JSONDecoder().decode(RoomFile.self, from: $0) }) else { continue }
      walls += (room.walls ?? []).compactMap { Self.segment($0, kind: "wall") }
      openings += (room.doors ?? []).compactMap { Self.segment($0, kind: "door") }
      openings += (room.windows ?? []).compactMap { Self.segment($0, kind: "window") }
      openings += (room.openings ?? []).compactMap { Self.segment($0, kind: "opening") }
    }
    photos = read(manifest.photos).flatMap { try? BundleJSON.decoder.decode([PhotoRecord].self, from: $0) } ?? []
    spots = photos.map { MapSpot(simd_float4x4(columnMajor: $0.transform), manual: $0.manual) }
  }

  /// A RoomPlan surface seen from above: center ± half its width along its local x axis
  private static func segment(_ s: Surface, kind: String) -> PlanSegment? {
    guard s.transform.count == 16, let width = s.dimensions.first else { return nil }
    let t = s.transform
    let c = SIMD2(t[12], t[14]), x = SIMD2(t[0], t[2])
    guard simd_length(x) > 0.01 else { return nil }
    let h = simd_normalize(x) * width / 2
    return PlanSegment(a: c - h, b: c + h, kind: kind)
  }
}

/// "Where was the phone?": the floor plan with every photo's position and direction.
/// Tap a cone to see that photo and its exact pose.
struct PhotoMapScreen: View {
  let folder: URL
  @State private var plan: ScanPlan?
  @State private var selected: Int?
  @State private var showAuto = false

  var body: some View {
    VStack(spacing: 0) {
      if let plan {
        let indices = plan.photos.indices.filter { showAuto || plan.photos[$0].manual }
        PlanCanvas(walls: plan.walls, openings: plan.openings, spots: indices.map { plan.spots[$0] },
                   selected: selected.flatMap { indices.firstIndex(of: $0) }) { i in selected = indices[i] }
          .background(Color(white: 0.08))
        if let i = selected, plan.photos.indices.contains(i) {
          PhotoPoseCard(folder: folder, photo: plan.photos[i])
        } else {
          Text("Tap a cone to see the photo taken there.").font(.footnote).foregroundStyle(.secondary).padding()
        }
      } else {
        ProgressView()
      }
    }
    .navigationTitle("Photo map")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar { Toggle("Auto photos", isOn: $showAuto).toggleStyle(.button) }
    .task {
      let folder = folder
      plan = await Task.detached { ScanPlan(folder: folder) }.value
    }
  }
}

struct PhotoPoseCard: View {
  let folder: URL
  let photo: PhotoRecord

  var body: some View {
    let pose = photo.pose ?? CameraPose(simd_float4x4(columnMajor: photo.transform))
    HStack(alignment: .top, spacing: 12) {
      if let image = UIImage(contentsOfFile: folder.appendingPathComponent(photo.file).path) {
        Image(uiImage: image).resizable().scaledToFit().frame(width: 110, height: 150).clipShape(RoundedRectangle(cornerRadius: 8))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(photo.file).font(.headline.monospaced())
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
          GridRow { Text("X"); Text(String(format: "%.2f m", pose.position[0])) }
          GridRow { Text("Y"); Text(String(format: "%.2f m", pose.position[1])) }
          GridRow { Text("Z"); Text(String(format: "%.2f m", pose.position[2])) }
          GridRow { Text("Facing"); Text(String(format: "%.0f°  (pitch %.0f°)", pose.yaw, pose.pitch)) }
        }
        .font(.caption.monospaced())
        if let depth = photo.depthFrame { Text("LiDAR: \(depth)").font(.caption2.monospaced()).foregroundStyle(.secondary) }
        if let geo = photo.location {
          Text(String(format: "GPS %.6f, %.6f ±%.0f m", geo.latitude, geo.longitude, geo.horizontalAccuracy))
            .font(.caption2).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding()
  }
}
