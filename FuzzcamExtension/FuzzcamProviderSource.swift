import CoreMedia
import CoreMediaIO
import Foundation
import IOKit.audio
import os

/// Publishes the "Fuzzcam" virtual camera to the system.
///
/// One device, two streams:
///
/// - **source** — what every other app on the Mac captures from.
/// - **sink** — what Fuzzcam.app writes processed frames into.
///
/// The extension does no image processing. It relays sink → source, and falls
/// back to a static card when the app is not feeding it. Keeping it this dumb is
/// deliberate: a camera extension that crashes takes the virtual camera down for
/// every app on the machine, so the less it does, the better.
final class FuzzcamProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: FuzzcamDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()

        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)

        // The name is read once, at launch. `CMIOExtensionDevice` fixes its
        // localized name at construction, so a rename in Settings only takes
        // effect after the extension restarts — documented in the UI.
        let configuration = SharedSettings.shared.load()
        deviceSource = FuzzcamDeviceSource(localizedName: configuration.virtualCameraName)

        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            os_log(.error, "Fuzzcam: failed to add device: %{public}@", error.localizedDescription)
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, .providerName]
    }

    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let providerProperties = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            providerProperties.manufacturer = "Fuzzcam"
        }
        if properties.contains(.providerName) {
            providerProperties.name = "Fuzzcam"
        }
        return providerProperties
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

// MARK: -

final class FuzzcamDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!

    private var sourceStreamSource: FuzzcamStreamSource!
    private var sinkStreamSource: FuzzcamStreamSource!

    private let log = OSLog(subsystem: "com.harshanacz.Fuzzcam.Extension", category: "Device")

    private var videoDescription: CMFormatDescription!

    /// Guards every mutable field below. Client callbacks arrive on the
    /// provider's queue and the idle timer fires on its own, so this is a real
    /// concurrency boundary rather than defensive decoration.
    private let lock = NSLock()

    private var sourceStreamingCounter = 0
    private var sinkStarted = false
    private var sinkClient: CMIOExtensionClient?
    private var lastClientFrameHostTime: UInt64 = 0

    private var idleTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(
        label: "com.harshanacz.Fuzzcam.Extension.timer",
        qos: .userInitiated
    )

    private var placeholderBuffer: CVPixelBuffer?
    private var placeholderSequence: UInt64 = 0

    /// How long the source stream waits for a frame from the app before it
    /// starts publishing the placeholder card instead.
    private static let idleThresholdNanoseconds: UInt64 = 1_000_000_000

    init(localizedName: String) {
        super.init()

        device = CMIOExtensionDevice(
            localizedName: localizedName,
            deviceID: FuzzcamIdentifiers.deviceUUID,
            legacyDeviceID: FuzzcamIdentifiers.deviceUUID.uuidString,
            source: self
        )

        let dimensions = CMVideoDimensions(
            width: Int32(VirtualCameraFormat.width),
            height: Int32(VirtualCameraFormat.height)
        )
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: dimensions.width,
            height: dimensions.height,
            extensions: nil,
            formatDescriptionOut: &videoDescription
        )

        // A range rather than a single rate: the user can choose 24, 30 or 60
        // in the app, and a camera that advertises a range is handled correctly
        // by every conferencing client (plenty of real webcams do the same).
        let format = CMIOExtensionStreamFormat(
            formatDescription: videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: 24),
            minFrameDuration: CMTime(value: 1, timescale: 60),
            validFrameDurations: [
                CMTime(value: 1, timescale: 24),
                CMTime(value: 1, timescale: 30),
                CMTime(value: 1, timescale: 60),
            ]
        )

        sourceStreamSource = FuzzcamStreamSource(
            localizedName: "Fuzzcam Video",
            streamID: FuzzcamIdentifiers.sourceStreamUUID,
            direction: .source,
            format: format,
            device: device
        )
        sinkStreamSource = FuzzcamStreamSource(
            localizedName: "Fuzzcam Sink",
            streamID: FuzzcamIdentifiers.sinkStreamUUID,
            direction: .sink,
            format: format,
            device: device
        )

        do {
            try device.addStream(sourceStreamSource.stream)
            try device.addStream(sinkStreamSource.stream)
        } catch {
            os_log(.error, log: log, "failed to add streams: %{public}@", error.localizedDescription)
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionDeviceProperties {
        let deviceProperties = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            deviceProperties.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            deviceProperties.model = "Fuzzcam Virtual Camera"
        }
        return deviceProperties
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: - Source stream (what other apps capture)

    func startSourceStreaming() {
        lock.lock()
        sourceStreamingCounter += 1
        let alreadyRunning = idleTimer != nil
        lock.unlock()

        guard !alreadyRunning else { return }
        startIdleTimer()
    }

    func stopSourceStreaming() {
        lock.lock()
        if sourceStreamingCounter > 0 { sourceStreamingCounter -= 1 }
        let shouldStop = sourceStreamingCounter == 0
        let timer = shouldStop ? idleTimer : nil
        if shouldStop { idleTimer = nil }
        lock.unlock()

        timer?.cancel()
    }

    /// Publishes the placeholder whenever the app has gone quiet.
    ///
    /// This timer does nothing at all while frames are flowing — it compares
    /// timestamps and returns. It exists only so a client never sits on a dead
    /// stream.
    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            self?.publishPlaceholderIfIdle()
        }
        lock.lock()
        idleTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func publishPlaceholderIfIdle() {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let nowNanos = UInt64(max(0, now.seconds) * Double(NSEC_PER_SEC))

        lock.lock()
        let streaming = sourceStreamingCounter > 0
        let lastFrame = lastClientFrameHostTime
        lock.unlock()

        guard streaming else { return }
        guard nowNanos &- lastFrame > Self.idleThresholdNanoseconds else { return }

        guard let buffer = placeholder() else { return }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: now,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: buffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: videoDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }

        sourceStreamSource.stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: nowNanos
        )
    }

    private func placeholder() -> CVPixelBuffer? {
        lock.lock()
        if let cached = placeholderBuffer {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let buffer = PlaceholderFrame.make(
            width: VirtualCameraFormat.width,
            height: VirtualCameraFormat.height,
            title: "Fuzzcam",
            message: "Open the Fuzzcam app to start your camera"
        )

        lock.lock()
        placeholderBuffer = buffer
        lock.unlock()
        return buffer
    }

    // MARK: - Sink stream (what Fuzzcam.app writes into)

    func startSinkStreaming(client: CMIOExtensionClient) {
        lock.lock()
        guard !sinkStarted else {
            lock.unlock()
            return
        }
        sinkStarted = true
        sinkClient = client
        lock.unlock()

        consumeNextBuffer(from: client)
    }

    func stopSinkStreaming() {
        lock.lock()
        sinkStarted = false
        sinkClient = nil
        lock.unlock()
    }

    /// Pulls one buffer from the client and immediately asks for the next.
    ///
    /// Recursion through the completion handler is the documented pattern: the
    /// call is asynchronous, so this is a chain of callbacks rather than a stack
    /// that grows.
    private func consumeNextBuffer(from client: CMIOExtensionClient) {
        lock.lock()
        let running = sinkStarted
        lock.unlock()
        guard running else { return }

        sinkStreamSource.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, discontinuity, _, error in
            guard let self else { return }

            if let sampleBuffer {
                let hostTime = UInt64(
                    max(0, CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
                        * Double(NSEC_PER_SEC)
                )

                self.lock.lock()
                self.lastClientFrameHostTime = UInt64(
                    max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds) * Double(NSEC_PER_SEC)
                )
                let shouldForward = self.sourceStreamingCounter > 0
                self.lock.unlock()

                if shouldForward {
                    self.sourceStreamSource.stream.send(
                        sampleBuffer,
                        discontinuity: discontinuity,
                        hostTimeInNanoseconds: hostTime
                    )
                }

                let output = CMIOExtensionScheduledOutput(
                    sequenceNumber: sequenceNumber,
                    hostTimeInNanoseconds: hostTime
                )
                self.sinkStreamSource.stream.notifyScheduledOutputChanged(output)
            }

            if let error, (error as NSError).code != 0 {
                os_log(.debug, log: self.log, "sink consume ended: %{public}@", error.localizedDescription)
            }

            self.consumeNextBuffer(from: client)
        }
    }
}

// MARK: -

final class FuzzcamStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!

    private let format: CMIOExtensionStreamFormat
    private let direction: CMIOExtensionStream.Direction
    private weak var device: CMIOExtensionDevice?

    /// Captured in `authorizedToStartStream` so `startStream` knows which client
    /// to pull buffers from.
    private var pendingClient: CMIOExtensionClient?

    init(
        localizedName: String,
        streamID: UUID,
        direction: CMIOExtensionStream.Direction,
        format: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice
    ) {
        self.format = format
        self.direction = direction
        self.device = device
        super.init()

        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: direction,
            clockType: .hostTime,
            source: self
        )
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        var properties: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if direction == .sink {
            properties.formUnion([
                .streamSinkBufferQueueSize,
                .streamSinkBuffersRequiredForStartup,
                .streamSinkEndOfData,
            ])
        }
        return properties
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let streamProperties = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            streamProperties.activeFormatIndex = 0
        }
        if properties.contains(.streamFrameDuration) {
            streamProperties.frameDuration = CMTime(
                value: 1, timescale: CMTimeScale(VirtualCameraFormat.frameRate)
            )
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            // Small on purpose. A deep queue would let the app run ahead and
            // add latency to every meeting; three frames is enough to absorb a
            // scheduling hiccup and nothing more.
            streamProperties.sinkBufferQueueSize = 3
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            streamProperties.sinkBuffersRequiredForStartup = 1
        }
        if properties.contains(.streamSinkEndOfData) {
            streamProperties.sinkEndOfData = 0
        }
        return streamProperties
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let index = streamProperties.activeFormatIndex {
            activeFormatIndex = index
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        pendingClient = client
        return true
    }

    func startStream() throws {
        guard let deviceSource = device?.source as? FuzzcamDeviceSource else { return }
        switch direction {
        case .source:
            deviceSource.startSourceStreaming()
        case .sink:
            guard let pendingClient else { return }
            deviceSource.startSinkStreaming(client: pendingClient)
        @unknown default:
            break
        }
    }

    func stopStream() throws {
        guard let deviceSource = device?.source as? FuzzcamDeviceSource else { return }
        switch direction {
        case .source:
            deviceSource.stopSourceStreaming()
        case .sink:
            deviceSource.stopSinkStreaming()
        @unknown default:
            break
        }
    }
}
