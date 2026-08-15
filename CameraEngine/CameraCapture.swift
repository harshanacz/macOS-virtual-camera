import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

/// Renders an OSType as its four-character code, for log lines that would
/// otherwise print an opaque 32-bit integer.
func fourCCString(_ value: OSType) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? String(value)
}

/// One frame from the physical camera.
///
/// `@unchecked Sendable` because `CVPixelBuffer` is a CoreFoundation type with
/// no Swift ownership annotations; the buffer is only ever read after it leaves
/// the capture queue, and never mutated by us.
struct VideoFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime

    var width: Int { CVPixelBufferGetWidth(pixelBuffer) }
    var height: Int { CVPixelBufferGetHeight(pixelBuffer) }
}

/// Owns the `AVCaptureSession` and delivers frames on a background queue.
///
/// Everything here runs off the main actor: the session queue serialises
/// configuration, and sample buffers arrive on a dedicated output queue. The
/// only thing that crosses back to the main actor is state, via `onStateChange`.
final class CameraCapture: NSObject, @unchecked Sendable {

    enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(cameraName: String, dimensions: CMVideoDimensions)
        case failed(CaptureError)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.stopped, .stopped), (.starting, .starting):
                return true
            case let (.running(a, b), .running(c, d)):
                return a == c && b.width == d.width && b.height == d.height
            case let (.failed(a), .failed(b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// Called on the video output queue for every delivered frame. Set before
    /// `start`; treated as immutable afterwards.
    var onFrame: (@Sendable (VideoFrame) -> Void)?

    /// Called on the main queue whenever `state` changes.
    var onStateChange: (@Sendable (State) -> Void)?

    private let log = Logger(subsystem: "com.harshanacz.Fuzzcam", category: "CameraCapture")

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.harshanacz.Fuzzcam.session")
    private let outputQueue = DispatchQueue(
        label: "com.harshanacz.Fuzzcam.video",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let output = AVCaptureVideoDataOutput()

    private var input: AVCaptureDeviceInput?
    private var requestedUniqueID: String?
    private var requestedFrameRate: Int = VirtualCameraFormat.frameRate
    private var notificationTokens: [NSObjectProtocol] = []
    private var retryWorkItem: DispatchWorkItem?

    private let stateLock = NSLock()
    private var _state: State = .stopped

    /// Touched only on `outputQueue`, which is serial.
    private var didLogFirstFrame = false

    private(set) var state: State {
        get { stateLock.withLock { _state } }
        set {
            let changed: Bool = stateLock.withLock {
                guard _state != newValue else { return false }
                _state = newValue
                return true
            }
            guard changed else { return }
            let handler = onStateChange
            DispatchQueue.main.async { handler?(newValue) }
        }
    }

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        // BGRA keeps one pixel format across preview, processing and the virtual
        // camera output. It is always present in
        // `availableVideoCVPixelFormatTypes` on macOS, so this cannot fail at
        // runtime the way a native biplanar format can on an odd USB camera.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)
        registerNotifications()
    }

    deinit {
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: - Lifecycle

    /// Starts (or switches to) the given camera. Safe to call repeatedly.
    func start(uniqueID: String?, targetFrameRate: Int = VirtualCameraFormat.frameRate) {
        sessionQueue.async { [self] in
            requestedUniqueID = uniqueID
            requestedFrameRate = targetFrameRate
            cancelRetry()
            didLogFirstFrame = false
            configureAndRun()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            cancelRetry()
            if session.isRunning { session.stopRunning() }
            teardownInput()
            state = .stopped
        }
    }

    // MARK: - Session configuration (sessionQueue only)

    private func configureAndRun() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied:
            state = .failed(.permissionDenied)
            return
        case .restricted:
            state = .failed(.permissionRestricted)
            return
        case .notDetermined, .authorized:
            break
        @unknown default:
            break
        }

        guard let device = resolveDevice() else {
            state = .failed(.noCameraAvailable)
            scheduleRetry()
            return
        }

        state = .starting

        session.beginConfiguration()
        teardownInput()

        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(newInput) else {
                session.commitConfiguration()
                state = .failed(.cannotOpenCamera(name: device.localizedName,
                                                  underlying: "session rejected the input"))
                return
            }
            session.addInput(newInput)
            input = newInput
        } catch {
            session.commitConfiguration()
            state = .failed(.cannotOpenCamera(name: device.localizedName,
                                              underlying: error.localizedDescription))
            return
        }

        if session.canAddOutput(output) {
            if !session.outputs.contains(output) { session.addOutput(output) }
        } else {
            session.commitConfiguration()
            state = .failed(.unsupportedFormat(name: device.localizedName))
            return
        }

        selectFormat(on: device)
        session.commitConfiguration()

        if !session.isRunning { session.startRunning() }

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        state = .running(cameraName: device.localizedName, dimensions: dims)
        log.info("capture running: \(device.localizedName, privacy: .public) \(dims.width)×\(dims.height)")
    }

    /// Never resolves to a virtual camera. Capturing Fuzzcam's own output would
    /// be an unbounded feedback loop; see `AVCaptureDevice.isVirtualCamera`.
    private func resolveDevice() -> AVCaptureDevice? {
        if let requestedUniqueID,
           let device = AVCaptureDevice(uniqueID: requestedUniqueID),
           !device.isVirtualCamera {
            return device
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.first { !$0.isVirtualCamera }
    }

    /// Picks a capture format big enough to be worth degrading but no bigger.
    ///
    /// Output is always 1280×720, so capturing 4K would burn bandwidth and power
    /// to produce pixels we immediately throw away. Capped at 1920×1080.
    private func selectFormat(on device: AVCaptureDevice) {
        let targetFPS = Double(requestedFrameRate)

        let candidates = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width <= 1920, dims.height <= 1080 else { return false }
            return format.videoSupportedFrameRateRanges.contains { range in
                range.maxFrameRate + 0.01 >= targetFPS
            }
        }

        let chosen = candidates.max { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
        }

        guard let chosen else {
            log.notice("no format ≤1080p at \(targetFPS, format: .fixed(precision: 0))fps; keeping the camera's default")
            return
        }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeFormat = chosen
            // Only clamp the frame duration when the format genuinely supports
            // it — setting an out-of-range duration throws and would abort the
            // whole start sequence over a cosmetic detail.
            let duration = CMTime(value: 1, timescale: CMTimeScale(requestedFrameRate))
            if chosen.videoSupportedFrameRateRanges.contains(where: {
                CMTimeCompare(duration, $0.minFrameDuration) >= 0 &&
                CMTimeCompare(duration, $0.maxFrameDuration) <= 0
            }) {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
        } catch {
            log.notice("could not lock \(device.localizedName, privacy: .public) for configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func teardownInput() {
        if let input {
            session.removeInput(input)
            self.input = nil
        }
    }

    // MARK: - Resilience

    private func registerNotifications() {
        let center = NotificationCenter.default

        notificationTokens.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let self, let device = note.object as? AVCaptureDevice else { return }
            sessionQueue.async {
                guard device.uniqueID == self.input?.device.uniqueID else { return }
                self.state = .failed(.cameraDisconnected(name: device.localizedName))
                self.session.stopRunning()
                self.teardownInput()
                self.scheduleRetry()
            }
        })

        notificationTokens.append(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            sessionQueue.async {
                guard case .failed(let error) = self.state, error.isTransient else { return }
                self.configureAndRun()
            }
        })

        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
                .localizedDescription ?? "unknown error"
            sessionQueue.async {
                self.state = .failed(.sessionRuntimeError(detail))
                self.scheduleRetry()
            }
        })

        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil
        ) { [weak self] _ in
            self?.sessionQueue.async {
                self?.state = .failed(.sessionInterrupted(
                    reason: "Another app may have taken over the camera. Fuzzcam will resume when it is free."
                ))
            }
        })

        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil
        ) { [weak self] _ in
            self?.sessionQueue.async { self?.configureAndRun() }
        })
    }

    /// Retries in the background after a transient failure. Fixed 2s interval:
    /// a webcam being replugged is a human-timescale event, and a tighter loop
    /// would just spin.
    private func scheduleRetry() {
        dispatchPrecondition(condition: .onQueue(sessionQueue))
        cancelRetry()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard case .failed(let error) = state, error.isTransient else { return }
            configureAndRun()
        }
        retryWorkItem = work
        sessionQueue.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    private func cancelRetry() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
    }
}

// MARK: - Frame delivery

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // A malformed sample buffer is dropped, never trapped on. One bad frame
        // from a flaky USB camera must not take the pipeline down.
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if !didLogFirstFrame {
            didLogFirstFrame = true
            let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
            log.info("""
                first frame delivered: \(CVPixelBufferGetWidth(pixelBuffer))×\
                \(CVPixelBufferGetHeight(pixelBuffer)) fourcc=\(fourCCString(format), privacy: .public)
                """)
        }

        onFrame?(VideoFrame(pixelBuffer: pixelBuffer, presentationTime: time))
    }
}
