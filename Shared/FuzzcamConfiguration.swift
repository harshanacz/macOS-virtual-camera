import Foundation

/// Everything the user can configure. Written by the app, read by the app and
/// (for the few fields it needs) by the camera extension.
public struct FuzzcamConfiguration: Codable, Equatable, Sendable {

    /// `uniqueID` of the physical `AVCaptureDevice` to capture from.
    /// `nil` means "whatever the system considers the default camera".
    public var selectedCameraUniqueID: String?

    /// Retry automatically when the selected camera disappears and returns.
    public var automaticallyReconnect: Bool

    public var preset: QualityPreset

    /// 0 = softer than the preset intends, 0.5 = exactly as intended,
    /// 1 = sharpened. The preset carries its own detail loss, so the neutral
    /// midpoint is the right default — the degradation does not depend on this.
    public var sharpness: Double

    /// 0 = no compression simulation, 1 = heavy blocking.
    public var compression: Double

    /// 0 = no grain, 1 = heavy grain.
    public var noise: Double

    /// Explicit, optional Gaussian blur. Off by default — "low quality" must not
    /// be implemented as "blurred face".
    public var blurEnabled: Bool
    public var blurRadius: Double

    public var frameRate: OutputFrameRate

    /// Display name of the virtual camera as other apps see it.
    public var virtualCameraName: String

    /// Whether the app should be pushing frames to the extension.
    public var virtualCameraEnabled: Bool

    /// Shows the metrics overlay in the preview window. Off by default; this is
    /// a developer affordance, not part of the product UI.
    public var showDeveloperMetrics: Bool

    /// Set once the user has finished the first-launch walkthrough.
    public var hasCompletedOnboarding: Bool

    public static let `default` = FuzzcamConfiguration(
        selectedCameraUniqueID: nil,
        automaticallyReconnect: true,
        preset: .low,
        sharpness: 0.50,
        compression: 0.0,
        noise: 0.0,
        blurEnabled: false,
        blurRadius: 0.0,
        frameRate: .fps30,
        virtualCameraName: "Fuzzcam",
        virtualCameraEnabled: true,
        showDeveloperMetrics: false,
        hasCompletedOnboarding: false
    )

    public init(
        selectedCameraUniqueID: String?,
        automaticallyReconnect: Bool,
        preset: QualityPreset,
        sharpness: Double,
        compression: Double,
        noise: Double,
        blurEnabled: Bool,
        blurRadius: Double,
        frameRate: OutputFrameRate,
        virtualCameraName: String,
        virtualCameraEnabled: Bool,
        showDeveloperMetrics: Bool,
        hasCompletedOnboarding: Bool
    ) {
        self.selectedCameraUniqueID = selectedCameraUniqueID
        self.automaticallyReconnect = automaticallyReconnect
        self.preset = preset
        self.sharpness = sharpness
        self.compression = compression
        self.noise = noise
        self.blurEnabled = blurEnabled
        self.blurRadius = blurRadius
        self.frameRate = frameRate
        self.virtualCameraName = virtualCameraName
        self.virtualCameraEnabled = virtualCameraEnabled
        self.showDeveloperMetrics = showDeveloperMetrics
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }

    /// Decoding tolerates a partial or older blob, so a schema change can never
    /// leave the extension without a usable configuration.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FuzzcamConfiguration.default
        selectedCameraUniqueID = try c.decodeIfPresent(String.self, forKey: .selectedCameraUniqueID)
        automaticallyReconnect = try c.decodeIfPresent(Bool.self, forKey: .automaticallyReconnect) ?? d.automaticallyReconnect
        preset = try c.decodeIfPresent(QualityPreset.self, forKey: .preset) ?? d.preset
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? d.sharpness
        compression = try c.decodeIfPresent(Double.self, forKey: .compression) ?? d.compression
        noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? d.noise
        blurEnabled = try c.decodeIfPresent(Bool.self, forKey: .blurEnabled) ?? d.blurEnabled
        blurRadius = try c.decodeIfPresent(Double.self, forKey: .blurRadius) ?? d.blurRadius
        frameRate = try c.decodeIfPresent(OutputFrameRate.self, forKey: .frameRate) ?? d.frameRate
        virtualCameraName = try c.decodeIfPresent(String.self, forKey: .virtualCameraName) ?? d.virtualCameraName
        virtualCameraEnabled = try c.decodeIfPresent(Bool.self, forKey: .virtualCameraEnabled) ?? d.virtualCameraEnabled
        showDeveloperMetrics = try c.decodeIfPresent(Bool.self, forKey: .showDeveloperMetrics) ?? d.showDeveloperMetrics
        hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? d.hasCompletedOnboarding
    }

    /// Values clamped into their documented ranges. Applied on load so a
    /// hand-edited or corrupted plist cannot feed nonsense into Core Image.
    public var sanitized: FuzzcamConfiguration {
        var copy = self
        copy.sharpness = sharpness.clamped(to: 0...1)
        copy.compression = compression.clamped(to: 0...1)
        copy.noise = noise.clamped(to: 0...1)
        copy.blurRadius = blurRadius.clamped(to: 0...24)
        if copy.virtualCameraName.trimmingCharacters(in: .whitespaces).isEmpty {
            copy.virtualCameraName = FuzzcamConfiguration.default.virtualCameraName
        }
        return copy
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Reads and writes ``FuzzcamConfiguration`` in the App Group container so the
/// app and the extension see the same values, and notifies across the process
/// boundary when it changes.
///
/// The app is the only writer. The extension only ever reads.
public final class SharedSettings: @unchecked Sendable {

    public static let shared = SharedSettings()

    private static let configKey = "configuration"

    private let defaults: UserDefaults?
    private let lock = NSLock()

    public init(suiteName: String = FuzzcamIdentifiers.appGroupID) {
        // A nil suite means the App Group is not provisioned. That must degrade
        // to in-memory defaults rather than crash — a misconfigured entitlement
        // should not take the camera down with it.
        self.defaults = UserDefaults(suiteName: suiteName)
    }

    /// True when the App Group container is actually reachable. The app surfaces
    /// this so a provisioning mistake is visible rather than silent.
    public var isSharedStoreAvailable: Bool { defaults != nil }

    public func load() -> FuzzcamConfiguration {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults?.data(forKey: Self.configKey) else {
            return .default
        }
        let decoded = try? JSONDecoder().decode(FuzzcamConfiguration.self, from: data)
        return (decoded ?? .default).sanitized
    }

    public func save(_ configuration: FuzzcamConfiguration) {
        lock.lock()
        if let data = try? JSONEncoder().encode(configuration.sanitized) {
            defaults?.set(data, forKey: Self.configKey)
        }
        lock.unlock()
        postChangeNotification()
    }

    // MARK: - Cross-process change notification

    private func postChangeNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(FuzzcamIdentifiers.configChangedNotification as CFString),
            nil, nil, true
        )
    }

    /// Invokes `handler` whenever the other process posts a configuration change.
    /// Used by the extension; harmless in the app.
    public func observeChanges(_ handler: @escaping @Sendable () -> Void) {
        let box = Unmanaged.passRetained(ObserverBox(handler)).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            box,
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<ObserverBox>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            FuzzcamIdentifiers.configChangedNotification as CFString,
            nil,
            .deliverImmediately
        )
    }
}

private final class ObserverBox {
    let handler: @Sendable () -> Void
    init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
}
