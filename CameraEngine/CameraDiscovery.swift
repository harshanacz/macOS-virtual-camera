import AVFoundation
import Combine
import Foundation

/// A physical camera, reduced to what the UI needs.
struct CameraDevice: Identifiable, Hashable, Sendable {
    let id: String          // AVCaptureDevice.uniqueID — stable across launches
    let name: String
    let isExternal: Bool

    init(_ device: AVCaptureDevice) {
        self.id = device.uniqueID
        self.name = device.localizedName
        self.isExternal = device.deviceType != .builtInWideAngleCamera
    }
}

/// Watches the set of attached cameras and republishes it on the main actor.
///
/// Hot-plug is handled through `AVCaptureDevice.wasConnectedNotification` /
/// `wasDisconnectedNotification`; the discovery session is re-read on each event
/// rather than trying to mutate a cached list, which keeps ordering stable and
/// avoids the classic "device appears twice after sleep" bug.
@MainActor
@Observable
final class CameraDiscovery {

    private(set) var cameras: [CameraDevice] = []

    /// Fires after `cameras` changes, so the capture layer can react to a camera
    /// vanishing or coming back.
    var onChange: (([CameraDevice]) -> Void)?

    /// Observer tokens live in a non-isolated box so they can be unregistered
    /// when this object goes away — a `deinit` on a main-actor type cannot touch
    /// isolated storage.
    private let observers = ObserverTokens()

    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .external,
        .continuityCamera,
        .deskViewCamera,
    ]

    init() {
        refresh()

        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification,
                     AVCaptureDevice.wasDisconnectedNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            observers.tokens.append(token)
        }
    }

    func refresh() {
        let session = AVCaptureDiscoverySession(
            deviceTypes: Self.deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        let found = session.devices.map(CameraDevice.init)
        guard found != cameras else { return }
        cameras = found
        onChange?(found)
    }

    /// Resolves a saved `uniqueID` to a live device, falling back to the system
    /// default so a camera that was unplugged since last launch does not leave
    /// the app with nothing to capture.
    func resolve(uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID, let device = AVCaptureDevice(uniqueID: uniqueID) {
            return device
        }
        return AVCaptureDiscoverySession(
            deviceTypes: Self.deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices.first
    }
}

private typealias AVCaptureDiscoverySession = AVCaptureDevice.DiscoverySession

/// Holds notification tokens and unregisters them on deallocation.
private final class ObserverTokens: @unchecked Sendable {
    var tokens: [NSObjectProtocol] = []
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
