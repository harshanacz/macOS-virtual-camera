import CoreGraphics
import Foundation

/// How aggressively the camera image is degraded.
///
/// The preset selects the *intermediate* resolution the frame is resampled down
/// to. That resampling is what actually destroys fine detail — the frame is then
/// scaled back up to the virtual camera's fixed output size, carrying the lost
/// detail with it. The advertised output format never changes, because
/// conferencing apps expect a stable, standard camera format.
public enum QualityPreset: String, Codable, CaseIterable, Sendable {
    case veryLow
    case low
    case medium
    case high
    case original

    public var displayName: String {
        switch self {
        case .veryLow:  return "Very Low"
        case .low:      return "Low"
        case .medium:   return "Medium"
        case .high:     return "High"
        case .original: return "Original"
        }
    }

    /// Nominal 16:9 intermediate resolution. Actual dimensions are derived from
    /// the source aspect ratio by ``intermediateSize(forSource:)``.
    public var nominalSize: CGSize? {
        switch self {
        case .veryLow:  return CGSize(width: 480, height: 270)
        case .low:      return CGSize(width: 640, height: 360)
        case .medium:   return CGSize(width: 854, height: 480)
        case .high:     return CGSize(width: 1280, height: 720)
        case .original: return nil
        }
    }

    public var subtitle: String {
        guard let size = nominalSize else { return "Camera native" }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    /// The resolution a frame of `source` dimensions is resampled down to.
    ///
    /// Matched on **height** and rounded to even numbers, so a 4:3 camera
    /// produces 480×360 for the "Low" preset rather than a stretched 640×360.
    /// Aspect ratio is always preserved; the image is never distorted.
    ///
    /// Returns `nil` when the preset asks for no downscale, or when the source
    /// is already at or below the target — upsampling first would add no detail
    /// and cost a filter pass.
    public func intermediateSize(forSource source: CGSize) -> CGSize? {
        guard let nominal = nominalSize else { return nil }
        guard source.width > 0, source.height > 0 else { return nil }
        guard source.height > nominal.height else { return nil }

        let scale = nominal.height / source.height
        let width = (source.width * scale).rounded()
        let height = nominal.height

        return CGSize(width: max(2, width.roundedDownToEven), height: max(2, height.roundedDownToEven))
    }

    /// Starting point for the sharpness control when the user picks a preset.
    /// Still individually overridable in Settings.
    public var suggestedSharpness: Double {
        switch self {
        case .veryLow:  return 0.20
        case .low:      return 0.30
        case .medium:   return 0.35
        case .high:     return 0.45
        case .original: return 0.50
        }
    }
}

private extension CGFloat {
    /// Even dimensions keep every downstream resampler and video encoder happy.
    var roundedDownToEven: CGFloat {
        let n = Int(self)
        return CGFloat(n - (n % 2))
    }
}

/// Frame rates the user may choose for the virtual camera.
public enum OutputFrameRate: Int, Codable, CaseIterable, Sendable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    public var displayName: String { "\(rawValue) FPS" }
}

/// The format the virtual camera advertises to the rest of the system.
///
/// Deliberately fixed and boring: a single 1280×720 BGRA format is accepted by
/// every conferencing app we care about. Degradation is expressed in the
/// *content* of the frame, not in the advertised format.
public enum VirtualCameraFormat {
    public static let width = 1280
    public static let height = 720
    public static let frameRate = 30
    public static var size: CGSize { CGSize(width: width, height: height) }
}
