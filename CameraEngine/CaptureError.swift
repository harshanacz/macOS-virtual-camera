import Foundation

/// Every failure the capture layer can produce, phrased for a human.
///
/// The recovery text is deliberately actionable — "open this specific pane" —
/// because a camera error the user cannot act on is just a dead preview.
enum CaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case permissionRestricted
    case noCameraAvailable
    case cameraDisconnected(name: String)
    case cannotOpenCamera(name: String, underlying: String)
    case unsupportedFormat(name: String)
    case sessionRuntimeError(String)
    case sessionInterrupted(reason: String)

    var message: String {
        switch self {
        case .permissionDenied:
            return "Camera permission is disabled."
        case .permissionRestricted:
            return "Camera access is restricted on this Mac."
        case .noCameraAvailable:
            return "No camera was found."
        case .cameraDisconnected(let name):
            return "\(name) was disconnected."
        case .cannotOpenCamera(let name, _):
            return "Could not open \(name)."
        case .unsupportedFormat(let name):
            return "\(name) does not offer a video format Fuzzcam can use."
        case .sessionRuntimeError:
            return "The capture session stopped unexpectedly."
        case .sessionInterrupted:
            return "Capture was interrupted."
        }
    }

    var recoverySuggestion: String {
        switch self {
        case .permissionDenied:
            return "Open System Settings → Privacy & Security → Camera and allow Fuzzcam."
        case .permissionRestricted:
            return "A configuration profile or parental control is blocking camera access. Contact whoever manages this Mac."
        case .noCameraAvailable:
            return "Connect a webcam, or check that the built-in camera is not disabled."
        case .cameraDisconnected:
            return "Fuzzcam will reconnect automatically when the camera is available again."
        case .cannotOpenCamera(_, let underlying):
            return "Another app may already be using it. (\(underlying))"
        case .unsupportedFormat:
            return "Try a different camera."
        case .sessionRuntimeError(let detail):
            return "Fuzzcam will try to restart it. (\(detail))"
        case .sessionInterrupted(let reason):
            return reason
        }
    }

    /// True when the fix is in System Settings rather than in the app.
    var needsPrivacySettings: Bool {
        self == .permissionDenied || self == .permissionRestricted
    }

    /// Whether the capture layer should keep retrying on its own.
    var isTransient: Bool {
        switch self {
        case .cameraDisconnected, .sessionRuntimeError, .sessionInterrupted, .noCameraAvailable:
            return true
        case .permissionDenied, .permissionRestricted, .cannotOpenCamera, .unsupportedFormat:
            return false
        }
    }
}
