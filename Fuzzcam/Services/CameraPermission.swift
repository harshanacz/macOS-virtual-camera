import AVFoundation
import AppKit

/// Camera authorisation, using the standard AVFoundation TCC APIs.
///
/// Nothing here works around a privacy control — a denial is reported to the
/// user with the exact pane they need to open.
enum CameraPermission {

    enum Status: Equatable {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    static var status: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:    return .authorized
        case .denied:        return .denied
        case .restricted:    return .restricted
        case .notDetermined: return .notDetermined
        @unknown default:    return .denied
        }
    }

    /// Presents the system prompt if the user has not answered yet.
    /// Returns the resulting status.
    static func request() async -> Status {
        guard status == .notDetermined else { return status }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        return status
    }

    /// Opens System Settings directly on the Camera privacy pane.
    static func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
