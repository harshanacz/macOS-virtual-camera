import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os

/// What the UI needs to know about the virtual camera.
struct VirtualCameraStatus: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case inactive
        case searching
        case active
        case unavailable(String)
    }

    var state: State = .inactive
    var framesDelivered: Int = 0
    var framesDropped: Int = 0

    var isActive: Bool { state == .active }

    var displayText: String {
        switch state {
        case .inactive:            return "Inactive"
        case .searching:           return "Connecting…"
        case .active:              return "Active"
        case .unavailable(let why): return why
        }
    }
}

/// Pushes processed frames into the camera extension's sink stream.
///
/// This is the app half of the app↔extension contract. It talks to the Core
/// Media I/O HAL directly, because that is the documented way for a companion
/// app to drive a `CMIOExtensionStream` whose direction is `.sink`:
///
///   1. enumerate `kCMIOHardwarePropertyDevices`
///   2. match on `kCMIODevicePropertyDeviceUID` — the extension publishes a
///      fixed UUID, so no discovery handshake is needed
///   3. find the stream whose `kCMIOStreamPropertyDirection` is 0 (output)
///   4. `CMIOStreamCopyBufferQueue` to get its `CMSimpleQueue`
///   5. `CMIODeviceStartStream`, then enqueue a `CMSampleBuffer` per frame
///
/// Frames cross the process boundary as IOSurface references, so nothing is
/// copied pixel-by-pixel on the way out.
final class VirtualCameraSink: @unchecked Sendable {

    var onStatusChange: (@Sendable (VirtualCameraStatus) -> Void)?

    private let log = Logger(subsystem: "com.harshanacz.Fuzzcam", category: "VirtualCameraSink")
    private let queue = DispatchQueue(label: "com.harshanacz.Fuzzcam.sink")

    private let lock = NSLock()
    private var status = VirtualCameraStatus()
    private var deviceID: CMIODeviceID = 0
    private var streamID: CMIOStreamID = 0
    private var bufferQueue: CMSimpleQueue?
    private var isRunning = false
    private var wantsToRun = false
    private var formatDescription: CMFormatDescription?
    private var retryTimer: DispatchSourceTimer?

    /// Never let more than this many buffers sit in the extension's queue. The
    /// queue is the only place frames could accumulate, and a backed-up queue
    /// means added latency in someone's meeting, so we drop instead.
    private static let maximumQueueDepth = 3

    // MARK: - Control

    func activate() {
        queue.async { [self] in
            wantsToRun = true
            connect()
        }
    }

    func deactivate() {
        queue.async { [self] in
            wantsToRun = false
            cancelRetry()
            teardown()
            update { $0.state = .inactive }
        }
    }

    /// Called when the system-extension installer's view of the world changes,
    /// so a freshly approved extension is picked up without relaunching.
    func extensionStatusChanged(_ status: SystemExtensionInstaller.Status) {
        queue.async { [self] in
            guard wantsToRun, !isRunning else { return }
            connect()
        }
    }

    // MARK: - Frame delivery

    /// Called on the processing queue for every processed frame.
    func send(_ frame: VideoFrame) {
        lock.lock()
        let running = isRunning
        let simpleQueue = bufferQueue
        let format = formatDescription
        lock.unlock()

        guard running, let simpleQueue, let format else { return }

        // Bounded by construction: if the extension has not drained the queue,
        // this frame is dropped rather than queued behind stale ones.
        guard CMSimpleQueueGetCount(simpleQueue) < Self.maximumQueueDepth else {
            update { $0.framesDropped += 1 }
            return
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: frame.pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            update { $0.framesDropped += 1 }
            return
        }

        // The queue takes ownership of the retained reference; the extension
        // releases it once it has consumed the buffer.
        let result = CMSimpleQueueEnqueue(
            simpleQueue,
            element: Unmanaged.passRetained(sampleBuffer).toOpaque()
        )
        if result != noErr {
            Unmanaged.passUnretained(sampleBuffer).release()
            update { $0.framesDropped += 1 }
            return
        }

        update { $0.framesDelivered += 1 }
    }

    // MARK: - Connection

    private func connect() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isRunning else { return }

        update { $0.state = .searching }

        guard let device = findDevice() else {
            update { $0.state = .unavailable("Fuzzcam’s camera extension is not installed yet.") }
            scheduleRetry()
            return
        }

        guard let stream = findSinkStream(on: device) else {
            update { $0.state = .unavailable("The camera extension is installed but not responding.") }
            scheduleRetry()
            return
        }

        var simpleQueue: Unmanaged<CMSimpleQueue>?
        let copyStatus = CMIOStreamCopyBufferQueue(stream, nil, nil, &simpleQueue)
        guard copyStatus == noErr, let simpleQueue else {
            update { $0.state = .unavailable("Could not open the camera extension's frame queue.") }
            scheduleRetry()
            return
        }

        let startStatus = CMIODeviceStartStream(device, stream)
        guard startStatus == noErr else {
            simpleQueue.release()
            update { $0.state = .unavailable("Could not start the virtual camera stream.") }
            scheduleRetry()
            return
        }

        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: Int32(VirtualCameraFormat.width),
            height: Int32(VirtualCameraFormat.height),
            extensions: nil,
            formatDescriptionOut: &description
        )

        lock.lock()
        deviceID = device
        streamID = stream
        bufferQueue = simpleQueue.takeRetainedValue()
        formatDescription = description
        isRunning = true
        lock.unlock()

        cancelRetry()
        update { $0.state = .active }
        log.info("virtual camera sink connected (device \(device), stream \(stream))")
    }

    private func teardown() {
        dispatchPrecondition(condition: .onQueue(queue))

        lock.lock()
        let device = deviceID
        let stream = streamID
        let wasRunning = isRunning
        isRunning = false
        bufferQueue = nil
        formatDescription = nil
        deviceID = 0
        streamID = 0
        lock.unlock()

        if wasRunning {
            CMIODeviceStopStream(device, stream)
        }
    }

    private func scheduleRetry() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard retryTimer == nil, wantsToRun else { return }

        // The extension appears when the user approves it in System Settings —
        // a human-timescale event, so polling every few seconds is plenty.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in
            guard let self, wantsToRun, !isRunning else { return }
            connect()
        }
        retryTimer = timer
        timer.resume()
    }

    private func cancelRetry() {
        retryTimer?.cancel()
        retryTimer = nil
    }

    /// Current counters and state. Polled by the UI rather than pushed, so the
    /// per-frame counters below cost one locked increment and nothing else.
    func snapshot() -> VirtualCameraStatus {
        lock.withLock { status }
    }

    /// Mutates the status and notifies **only when the state actually changes**.
    ///
    /// The frame counters change 30 times a second; waking the main thread that
    /// often to redraw a label nobody is looking at would be indefensible. State
    /// transitions are rare, so those are worth a hop.
    private func update(_ mutate: (inout VirtualCameraStatus) -> Void) {
        lock.lock()
        let before = status.state
        mutate(&status)
        let snapshot = status
        let stateChanged = before != snapshot.state
        lock.unlock()

        guard stateChanged, let handler = onStatusChange else { return }
        DispatchQueue.main.async { handler(snapshot) }
    }

    // MARK: - CMIO HAL lookup

    private func findDevice() -> CMIODeviceID? {
        let targetUID = FuzzcamIdentifiers.deviceUUID.uuidString

        for device in CMIOProperty.objectIDs(
            in: CMIOObjectID(kCMIOObjectSystemObject),
            selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)
        ) {
            guard let uid = CMIOProperty.string(
                on: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)
            ) else { continue }

            // The HAL may expose the UID with or without the extension's own
            // decoration, so compare case-insensitively on containment.
            if uid.caseInsensitiveCompare(targetUID) == .orderedSame
                || uid.localizedCaseInsensitiveContains(targetUID) {
                return device
            }
        }
        return nil
    }

    private func findSinkStream(on device: CMIODeviceID) -> CMIOStreamID? {
        let streams = CMIOProperty.objectIDs(in: device, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams))

        for stream in streams {
            // kCMIOStreamPropertyDirection: 0 = output (we write into it),
            // 1 = input (other apps read from it).
            guard let direction = CMIOProperty.uint32(
                on: stream, selector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection)
            ) else { continue }
            if direction == 0 { return stream }
        }
        return nil
    }
}

// MARK: - Thin wrapper over the CMIO property API

/// `CMIOObjectGetPropertyData` is a four-call dance every single time. These
/// helpers collapse it to one line and keep the unsafe pointer work in one
/// place instead of scattered through the lookup logic.
private enum CMIOProperty {

    static func objectIDs(in object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var dataSize: UInt32 = 0
        var dataUsed: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)

        let status = ids.withUnsafeMutableBytes { raw -> OSStatus in
            CMIOObjectGetPropertyData(object, &address, 0, nil, dataSize, &dataUsed, raw.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids
    }

    static func string(on object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        let dataSize = UInt32(MemoryLayout<CFString?>.size)
        var dataUsed: UInt32 = 0
        var value: CFString?

        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            CMIOObjectGetPropertyData(object, &address, 0, nil, dataSize, &dataUsed, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }

    static func uint32(on object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> UInt32? {
        var address = CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )

        var value: UInt32 = 0
        var dataUsed: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)

        let status = withUnsafeMutablePointer(to: &value) { pointer -> OSStatus in
            CMIOObjectGetPropertyData(object, &address, 0, nil, size, &dataUsed, pointer)
        }
        guard status == noErr else { return nil }
        return value
    }
}
