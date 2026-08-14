import AVFoundation
import Foundation
import Observation
import SwiftUI

/// The single source of truth the UI observes.
///
/// Owns the video pipeline and the shared configuration, and translates engine
/// state into something a menu item can display. Nothing in here touches pixels;
/// per-frame work happens on the pipeline's own queues and only the finished
/// preview image crosses back to the main actor.
@MainActor
@Observable
final class AppModel {

    /// Which feed the preview window is showing.
    enum PreviewMode: String, CaseIterable, Identifiable, Sendable {
        case original = "Original"
        case processed = "Processed"
        var id: String { rawValue }
    }

    // MARK: - Observable state

    private(set) var permission: CameraPermission.Status = CameraPermission.status
    private(set) var captureState: CameraCapture.State = .stopped
    private(set) var previewImage: CGImage?
    private(set) var metrics = ProcessingSnapshot()

    private(set) var virtualCamera = VirtualCameraStatus()

    var previewMode: PreviewMode = .processed {
        didSet {
            guard previewMode != oldValue else { return }
            previewImage = nil
            applyPreviewRouting()
        }
    }

    var configuration: FuzzcamConfiguration {
        didSet {
            guard configuration != oldValue else { return }
            settings.save(configuration)
            applyConfigurationChange(from: oldValue)
        }
    }

    let discovery = CameraDiscovery()

    /// True when the App Group container resolved. Surfaced in Settings so a
    /// provisioning mistake shows up as a message instead of as silently
    /// unshared configuration.
    let isSharedStoreAvailable: Bool

    // MARK: - Engine

    private let settings = SharedSettings.shared
    private let pipeline = VideoPipeline()
    private let originalRenderer = PreviewRenderer()
    private let processedRenderer = PreviewRenderer()
    private let virtualCameraSink = VirtualCameraSink()
    private let extensionInstaller = SystemExtensionInstaller()

    #if DEBUG
    /// DEVELOPMENT ONLY — a window OBS can capture until the camera extension
    /// can be notarized. See `docs/DEV-CAMERA.md`.
    private let devCameraOutput = DevCameraOutput()
    #endif

    private var isPreviewOpen = false
    private var metricsTimer: Timer?

    // MARK: - Derived, for the UI

    var cameras: [CameraDevice] { discovery.cameras }

    var selectedCamera: CameraDevice? {
        if let id = configuration.selectedCameraUniqueID,
           let match = discovery.cameras.first(where: { $0.id == id }) {
            return match
        }
        return discovery.cameras.first
    }

    var selectedCameraName: String {
        if case .running(let name, _) = captureState { return name }
        return selectedCamera?.name ?? "No camera"
    }

    var statusLine: String {
        switch captureState {
        case .stopped:  return "Stopped"
        case .starting: return "Starting…"
        case .running(let name, let dims):
            return "\(name) — \(dims.width)×\(dims.height)"
        case .failed(let error):
            return error.message
        }
    }

    var currentError: CaptureError? {
        if case .failed(let error) = captureState { return error }
        return nil
    }

    var isCapturing: Bool {
        if case .running = captureState { return true }
        return false
    }

    /// Human-readable description of what the pipeline is doing, e.g.
    /// "640 × 360 processing". Reads the measured size rather than the preset,
    /// because the real size depends on the camera's aspect ratio.
    var processingDescription: String {
        let size = metrics.processingSize
        guard size.width > 0 else { return configuration.preset.subtitle }
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    // MARK: - Init

    init() {
        let settings = SharedSettings.shared
        self.isSharedStoreAvailable = settings.isSharedStoreAvailable
        self.configuration = settings.load()

        pipeline.settings = FrameProcessor.Settings(configuration)

        pipeline.onStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.captureState = state }
        }

        pipeline.onOriginalFrame = { [weak self] frame in
            self?.originalRenderer.submit(frame)
        }

        pipeline.onProcessedFrame = { [weak self] frame in
            guard let self else { return }
            processedRenderer.submit(frame)
            virtualCameraSink.send(frame)
            #if DEBUG
            devCameraOutput.submit(frame)
            #endif
        }

        let receiveImage: @Sendable (CGImage) -> Void = { [weak self] image in
            MainActor.assumeIsolated { self?.previewImage = image }
        }
        originalRenderer.onImage = receiveImage
        processedRenderer.onImage = receiveImage

        virtualCameraSink.onStatusChange = { [weak self] status in
            MainActor.assumeIsolated { self?.virtualCamera = status }
        }

        discovery.onChange = { [weak self] cameras in
            MainActor.assumeIsolated { self?.camerasChanged(cameras) }
        }

        // A menu-bar app has no window to hang a `.task` on, and both capture
        // and the virtual camera must be live whether or not the UI is open.
        Task { await start() }
    }

    // MARK: - Lifecycle

    private var hasStarted = false

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        extensionInstaller.onStatusChange = { [weak self] status in
            MainActor.assumeIsolated { self?.virtualCameraSink.extensionStatusChanged(status) }
        }
        extensionInstaller.refreshStatus()

        // Submitting an activation request on every launch is the documented
        // pattern: it is a no-op when the extension is already installed and
        // current, and it is what picks up a rebuilt extension during
        // development. macOS still gates the first install behind explicit user
        // approval in System Settings.
        if configuration.virtualCameraEnabled {
            extensionInstaller.install()
        }

        permission = await CameraPermission.request()
        guard permission == .authorized else {
            captureState = .failed(permission == .restricted ? .permissionRestricted : .permissionDenied)
            return
        }

        pipeline.start(uniqueID: configuration.selectedCameraUniqueID, frameRate: configuration.frameRate)
        if configuration.virtualCameraEnabled {
            virtualCameraSink.activate()
        }

        #if DEBUG
        if DevCameraOutput.isAutoStartRequested {
            devCameraOutput.start()
        }
        #endif
    }

    func stop() {
        pipeline.stop()
        virtualCameraSink.deactivate()
        setPreviewActive(false)
    }

    /// Called by the preview window appearing and disappearing. Rendering costs
    /// nothing when nobody is looking.
    func setPreviewActive(_ active: Bool) {
        isPreviewOpen = active
        applyPreviewRouting()

        metricsTimer?.invalidate()
        metricsTimer = nil

        if active {
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.metrics = self.pipeline.metricsSnapshot()
                    // Frame counters are polled rather than pushed, so they do
                    // not wake the main thread 30 times a second.
                    self.virtualCamera = self.virtualCameraSink.snapshot()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            metricsTimer = timer
        } else {
            previewImage = nil
        }
    }

    func selectCamera(_ camera: CameraDevice) {
        configuration.selectedCameraUniqueID = camera.id
    }

    func selectPreset(_ preset: QualityPreset) {
        var updated = configuration
        updated.preset = preset
        updated.sharpness = preset.suggestedSharpness
        configuration = updated
    }

    func retry() {
        pipeline.start(uniqueID: configuration.selectedCameraUniqueID, frameRate: configuration.frameRate)
    }

    func installExtension() {
        extensionInstaller.install()
    }

    #if DEBUG
    var isDevCameraOutputRunning: Bool { devCameraOutput.isRunning }

    func toggleDevCameraOutput() {
        devCameraOutput.toggle()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    #endif

    var extensionStatus: SystemExtensionInstaller.Status { extensionInstaller.status }

    func completeOnboarding() {
        configuration.hasCompletedOnboarding = true
    }

    // MARK: - Private

    private func applyPreviewRouting() {
        let wantsOriginal = isPreviewOpen && previewMode == .original
        let wantsProcessed = isPreviewOpen && previewMode == .processed
        originalRenderer.isEnabled = wantsOriginal
        processedRenderer.isEnabled = wantsProcessed
        pipeline.wantsOriginalFrames = wantsOriginal
    }

    private func applyConfigurationChange(from old: FuzzcamConfiguration) {
        pipeline.settings = FrameProcessor.Settings(configuration)

        if old.selectedCameraUniqueID != configuration.selectedCameraUniqueID
            || old.frameRate != configuration.frameRate {
            pipeline.start(uniqueID: configuration.selectedCameraUniqueID, frameRate: configuration.frameRate)
        }

        if old.virtualCameraEnabled != configuration.virtualCameraEnabled {
            if configuration.virtualCameraEnabled {
                virtualCameraSink.activate()
            } else {
                virtualCameraSink.deactivate()
            }
        }
    }

    private func camerasChanged(_ cameras: [CameraDevice]) {
        guard configuration.automaticallyReconnect else { return }
        guard let selected = configuration.selectedCameraUniqueID else { return }

        // If the selected camera vanished, fall back to whatever is left rather
        // than sitting on a dead selection. The saved ID is kept untouched so the
        // original camera is reclaimed when it comes back.
        let stillPresent = cameras.contains { $0.id == selected }
        if !stillPresent, !cameras.isEmpty {
            pipeline.start(uniqueID: nil, frameRate: configuration.frameRate)
        } else if stillPresent, case .failed(let error) = captureState, error.isTransient {
            pipeline.start(uniqueID: selected, frameRate: configuration.frameRate)
        }
    }
}
