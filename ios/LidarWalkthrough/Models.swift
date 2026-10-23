import CoreLocation
import Foundation
import simd
import UIKit

// The export is a `house-capture/5` session bundle, the format of wesbos/3d-model-anything
// (https://github.com/wesbos/3d-model-anything), so its scan-to-threejs agent skill and
// scripts read our scans unchanged. Field names and the format id must not be renamed.
// Everything we add (GPS, address, capture time) lives in extra optional keys that
// their scripts and decoders ignore.
//
//     manifest.json          what's in the bundle
//     structure.json|usdz    all rooms merged by RoomPlan's StructureBuilder
//     rooms/room-N.json      each CapturedRoom as RoomPlan encodes it (+ .usdz, -data.json)
//     mesh/room-N.ply        LiDAR mesh at the end of room N (world space, classified faces)
//     photos/photos.json     pose + intrinsics + GPS for every photo
//     photos/NNNN.jpg        sensor-orientation JPEG, EXIF orientation 6 + EXIF GPS
//     depth/frames.json      LiDAR depth frames: pose + intrinsics
//     depth/NNNNN.f16z|conf|jpg  256×192 Float16 meters (raw DEFLATE), confidence, 640×480 RGB
//
// One coordinate system for everything: the ARKit world of the capture session
// (meters, +Y up against gravity, right-handed).

struct Manifest: Codable {
  static let currentFormat = "house-capture/5"
  var format = Manifest.currentFormat
  var createdAt: Date
  var endedAt: Date?
  var device: String
  var systemVersion: String
  var coordinateSystem = "ARKit world space of this capture session: meters, +Y up (gravity), right-handed. Rooms, structure, mesh and photo poses all share it."
  var house: String
  var houseName: String?
  var session: String
  var zone = "main"
  var rooms: [RoomRecord] = []
  var structure: String?
  var structureError: String?
  var mesh: MeshRecord?
  var sceneReconstruction: String?
  var photos = "photos/photos.json"
  var photoCount = 0
  var depthFrames: String? = "depth/frames.json"
  var depthFrameCount: Int? = 0
  // additions (ignored by house-capture readers)
  var property: PropertyInfo?
  var app: AppInfo?
}

struct PropertyInfo: Codable {
  var name: String
  var address: String?
  var latitude: Double?
  var longitude: Double?
  var altitude: Double?
  var horizontalAccuracy: Double?
  var notes: String?
}

struct AppInfo: Codable {
  var name = "3D LiDAR Scan"
  var version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
}

struct RoomRecord: Codable, Identifiable {
  var index: Int
  var name: String
  var file: String
  var usdz: String
  var capturedAt: Date
  var walls: Int
  var doors: Int
  var windows: Int
  var openings: Int
  var objects: Int
  var mesh: MeshRecord?
  /// RoomPlan's raw CapturedRoomData ("rooms/room-N-data.json")
  var data: String?
  var id: Int { index }
}

struct MeshRecord: Codable {
  var file: String
  var anchors: Int
  var vertices: Int
  var faces: Int
}

/// One reference photo. Pixels are the raw camera image in sensor orientation (landscape);
/// `intrinsics` match those pixels. EXIF orientation 6 makes viewers show it upright.
struct PhotoRecord: Codable {
  var file: String
  var room: Int
  var timestamp: TimeInterval
  var width: Int
  var height: Int
  /// camera-to-world, column-major 4x4; camera looks down -Z, +Y up (sensor orientation)
  var transform: [Float]
  /// column-major 3x3: fx, 0, 0, 0, fy, 0, cx, cy, 1
  var intrinsics: [Float]
  var tracking: String
  /// taken with the shutter button (vs. automatically while walking)
  var manual: Bool
  var exposure: Double?
  var blurPixels: Float?
  var pass: String?
  /// a full-resolution still rather than a video frame
  var highRes: Bool?
  var camera: CameraState?
  // additions
  var capturedAt: Date?
  var location: GeoSample?
}

struct CameraState: Codable {
  var exposureOffset: Float?
  var ambientIntensity: Float?
  var colorTemperature: Float?
}

/// Where the phone was when a photo was taken (GPS is coarse indoors: check the accuracy)
struct GeoSample: Codable {
  var latitude: Double
  var longitude: Double
  var altitude: Double?
  var horizontalAccuracy: Double
  var verticalAccuracy: Double?
  /// compass heading in degrees from true north (magnetic if true north is unavailable)
  var heading: Double?
  var headingAccuracy: Double?
  var floor: Int?
  var timestamp: Date

  init(_ location: CLLocation, heading: CLHeading?) {
    latitude = location.coordinate.latitude
    longitude = location.coordinate.longitude
    altitude = location.verticalAccuracy >= 0 ? location.altitude : nil
    horizontalAccuracy = location.horizontalAccuracy
    verticalAccuracy = location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil
    if let heading, heading.headingAccuracy >= 0 {
      self.heading = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
      headingAccuracy = heading.headingAccuracy
    }
    floor = location.floor?.level
    timestamp = location.timestamp
  }
}

struct DepthRecord: Codable {
  /// Float16 meters, row-major, raw DEFLATE (zlib.decompress(data, -15) in Python)
  var file: String
  var confidence: String
  /// 640×480 JPEG of the camera image at this frame (sensor orientation, no EXIF rotation)
  var rgb: String?
  var rgbIntrinsics: [Float]?
  var room: Int
  var timestamp: TimeInterval
  var width: Int
  var height: Int
  var transform: [Float]
  /// column-major 3x3, scaled to the depth map's resolution
  var intrinsics: [Float]
}

enum BundleJSON {
  static var encoder: JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
  }

  static var decoder: JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
  }
}

extension simd_float4x4 {
  var columnMajor: [Float] {
    [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
  }
}

extension simd_float3x3 {
  var columnMajor: [Float] {
    [columns.0, columns.1, columns.2].flatMap { [$0.x, $0.y, $0.z] }
  }
}

extension UIDevice {
  /// e.g. "iPhone16,1"
  static var modelIdentifier: String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { buf in
      String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }
  }
}
