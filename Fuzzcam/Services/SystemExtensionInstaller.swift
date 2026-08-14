import Foundation
import SystemExtensions
import os

/// Installs and updates the Fuzzcam camera system extension.
///
/// `OSSystemExtensionManager` is the only supported way to install a camera
/// extension. macOS holds the request until the user approves it in
/// System Settings, which is a deliberate privacy control and not something to
/// route around — the app's job is to explain clearly what is being asked.
@MainActor
@Observable
final class SystemExtensionInstaller: NSObject {

    enum Status: Equatable, Sendable {
        case unknown
        case notInstalled
        case installing
        case needsUserApproval
        case installed
        case needsReboot
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .installed, .failed, .notInstalled: return true
            default: return false
            }
        }
    }

    private(set) var status: Status = .unknown

    /// Called on the main actor when `status` changes.
    var onStatusChange: (@Sendable (Status) -> Void)?

    private let log = Logger(subsystem: "com.harshanacz.Fuzzcam", category: "SystemExtension")

    /// Asks macOS to activate the extension embedded in this app bundle.
    ///
    /// Safe to call repeatedly: an already-installed extension of the same
    /// version resolves immediately as "completed".
    func install() {
        setStatus(.installing)

        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: FuzzcamIdentifiers.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        log.info("submitted activation request for \(FuzzcamIdentifiers.extensionBundleID, privacy: .public)")
    }

    func uninstall() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: FuzzcamIdentifiers.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    /// Asks the system what it currently knows about our extension.
    ///
    /// `propertiesRequest` reports enabled / awaiting-approval / uninstalling
    /// without changing anything, so this is safe to call on every launch.
    /// Whether frames actually flow is a separate question that only
    /// ``VirtualCameraSink`` can answer, by looking for the device in the HAL.
    func refreshStatus() {
        let request = OSSystemExtensionRequest.propertiesRequest(
            forExtensionWithIdentifier: FuzzcamIdentifiers.extensionBundleID,
            queue: .main
        )
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func setStatus(_ new: Status) {
        guard status != new else { return }
        status = new
        onStatusChange?(new)
    }
}

extension SystemExtensionInstaller: OSSystemExtensionRequestDelegate {

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension replacement: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        // Always take the version bundled with the running app. During
        // development the build number often stays put while the code changes,
        // so refusing to replace would silently run a stale extension.
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.setStatus(.needsUserApproval)
            self.log.notice("extension is waiting for user approval in System Settings")
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        Task { @MainActor in
            switch result {
            case .completed:
                self.setStatus(.installed)
                self.log.info("camera extension activated")
            case .willCompleteAfterReboot:
                self.setStatus(.needsReboot)
            @unknown default:
                self.setStatus(.installed)
            }
        }
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        foundProperties properties: [OSSystemExtensionProperties]
    ) {
        Task { @MainActor in
            guard let match = properties.first else {
                self.setStatus(.notInstalled)
                return
            }
            if match.isAwaitingUserApproval {
                self.setStatus(.needsUserApproval)
            } else if match.isUninstalling {
                self.setStatus(.notInstalled)
            } else if match.isEnabled {
                self.setStatus(.installed)
            } else {
                self.setStatus(.needsUserApproval)
            }
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let message = Self.describe(error)
        let notInstalled = (error as? OSSystemExtensionError)?.code == .extensionNotFound
        Task { @MainActor in
            // A properties request for an extension that was never installed
            // fails with `extensionNotFound`. That is a normal starting state,
            // not something to shout about.
            self.setStatus(notInstalled ? .notInstalled : .failed(message))
            self.log.error("extension request failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Turns `OSSystemExtensionError` codes into something a person can act on.
    nonisolated private static func describe(_ error: Error) -> String {
        guard let osError = error as? OSSystemExtensionError else {
            return error.localizedDescription
        }
        switch osError.code {
        case .missingEntitlement:
            return "Fuzzcam is missing the System Extension entitlement. Rebuild with a development team that has it enabled."
        case .unsupportedParentBundleLocation:
            return "Move Fuzzcam to your Applications folder and try again — macOS only installs camera extensions from there."
        case .extensionNotFound:
            // macOS also reports this code when sysextd refuses the bundle on
            // policy grounds — an app that Gatekeeper rejects looks the same as
            // one with no extension inside it. Cover both, since the policy case
            // is by far the more common one during development.
            return "macOS would not load Fuzzcam's camera extension. Make sure Fuzzcam is in your Applications folder and was installed from a notarized build."
        case .authorizationRequired:
            return "Approve Fuzzcam in System Settings → General → Login Items & Extensions."
        case .requestSuperseded:
            return "A newer install request replaced this one."
        case .validationFailed:
            return "The camera extension failed validation. Check its bundle identifier and code signature."
        default:
            return error.localizedDescription
        }
    }
}
