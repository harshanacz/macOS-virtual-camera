import CoreGraphics
import Foundation

/// How much like a cheap webcam the output should look.
///
/// A preset is not just a resolution. Each one carries its own *intrinsic*
/// degradation — smeared micro-texture, soft chroma, crunchy edges, washed
/// shadows — that is applied regardless of where the user has left the manual
/// sliders. That matters: dropping resolution alone produces a clean, small
/// image, which reads as "downscaled", not as "bad webcam". The artefacts are
/// what sell it.
///
/// The manual sharpness control still works on top, but it cannot restore what
/// the preset threw away: Very Low resamples through 320×180, and no amount of
/// sharpening puts 1080p detail back.
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

    /// One-line description of the intent, shown in the UI.
    public var summary: String {
        switch self {
        case .original: return "Full camera quality"
        case .high:     return "Slightly reduced detail"
        case .medium:   return "Typical webcam quality"
        case .low:      return "Low-quality webcam"
        case .veryLow:  return "Very low-quality webcam"
        }
    }

    /// Nominal 16:9 intermediate resolution. The real dimensions come from
    /// ``intermediateSize(forSource:)``, which follows the source's aspect ratio.
    public var nominalSize: CGSize? {
        switch self {
        case .veryLow:  return CGSize(width: 320, height: 180)
        case .low:      return CGSize(width: 480, height: 270)
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
    /// Matched on **height** and rounded to even numbers, so a 4:3 camera gives
    /// 360×270 for Low rather than a stretched 480×270. Aspect ratio is always
    /// preserved; the image is never distorted.
    ///
    /// `nil` means no downscale — either the preset asks for none, or the source
    /// is already at or below the target, in which case upsampling first would
    /// add no detail and cost a pass.
    public func intermediateSize(forSource source: CGSize) -> CGSize? {
        guard let nominal = nominalSize else { return nil }
        guard source.width > 0, source.height > 0 else { return nil }
        guard source.height > nominal.height else { return nil }

        let scale = nominal.height / source.height
        let width = (source.width * scale).rounded()

        return CGSize(
            width: max(2, width.roundedDownToEven),
            height: max(2, nominal.height.roundedDownToEven)
        )
    }

    // MARK: - Intrinsic degradation
    //
    // Applied whatever the sliders say. Values were tuned by rendering real
    // camera frames at each preset and comparing them side by side, not by
    // picking round numbers.

    /// Smearing of fine texture while edges survive — the signature of a cheap
    /// sensor with aggressive noise reduction. This is what turns skin waxy and
    /// hair into a mass, and it is the single most convincing cue.
    public var detailSmear: Double {
        switch self {
        case .original: return 0.00
        case .high:     return 0.18
        case .medium:   return 0.38
        case .low:      return 0.62
        case .veryLow:  return 0.82
        }
    }

    /// How much colour resolution is thrown away relative to luma, imitating
    /// heavy chroma subsampling and a weak demosaic.
    public var chromaSoftness: Double {
        switch self {
        case .original: return 0.00
        case .high:     return 0.20
        case .medium:   return 0.40
        case .low:      return 0.65
        case .veryLow:  return 0.85
        }
    }

    /// Edge halos. Cheap webcams over-sharpen to compensate for a soft lens, so
    /// a little crunch after the smearing reads as "cheap" rather than "blurred".
    public var edgeCrunch: Double {
        switch self {
        case .original: return 0.00
        case .high:     return 0.15
        case .medium:   return 0.32
        case .low:      return 0.48
        case .veryLow:  return 0.58
        }
    }

    /// Washed-out shadows and slightly flat, desaturated colour — small sensors
    /// with no dynamic range to spare.
    public var tonalFlatness: Double {
        switch self {
        case .original: return 0.00
        case .high:     return 0.08
        case .medium:   return 0.18
        case .low:      return 0.30
        case .veryLow:  return 0.42
        }
    }

    /// Baseline compression damage. The user's compression slider adds to this;
    /// it can never take the preset below its own floor.
    public var intrinsicCompression: Double {
        switch self {
        case .original: return 0.00
        case .high:     return 0.06
        case .medium:   return 0.16
        case .low:      return 0.30
        case .veryLow:  return 0.44
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
