import CoreMedia
import Foundation
import os

/// Wires capture to processing to consumers.
///
/// Capture, processing and delivery each run on their own queue. The only
/// coupling between them is a single "busy" flag: if a frame arrives while the
/// previous one is still in the filter chain, the new frame is dropped and
/// counted. That is what keeps the pipeline bounded — there is no queue to grow,
/// so a slow GPU degrades the frame rate instead of the machine's memory.
///
/// Consumers are set once at construction time and treated as immutable.
final class VideoPipeline: @unchecked Sendable {

    let capture = CameraCapture()
    let processor = FrameProcessor()

    /// Untouched camera frame, on the processing queue. Used by the preview.
    var onOriginalFrame: (@Sendable (VideoFrame) -> Void)?

    /// Degraded frame, on the processing queue. Used by the preview and by the
    /// virtual camera sink.
    var onProcessedFrame: (@Sendable (VideoFrame) -> Void)?

    var onStateChange: (@Sendable (CameraCapture.State) -> Void)? {
        get { capture.onStateChange }
        set { capture.onStateChange = newValue }
    }

    private let log = Logger(subsystem: "com.harshanacz.Fuzzcam", category: "VideoPipeline")

    private let processingQueue = DispatchQueue(
        label: "com.harshanacz.Fuzzcam.processing",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    private let busyLock = NSLock()
    private var isProcessing = false

    /// Set while nobody needs the original frames, so we skip the extra hop.
    private let flagLock = NSLock()
    private var _wantsOriginalFrames = false

    var wantsOriginalFrames: Bool {
        get { flagLock.withLock { _wantsOriginalFrames } }
        set { flagLock.withLock { _wantsOriginalFrames = newValue } }
    }

    /// Periodic metrics logging for development. Enabled with `FUZZCAM_METRICS=1`;
    /// costs nothing otherwise.
    private var metricsTimer: DispatchSourceTimer?

    init() {
        capture.onFrame = { [weak self] frame in
            self?.receive(frame)
        }

        if ProcessInfo.processInfo.environment["FUZZCAM_METRICS"] == "1" {
            let timer = DispatchSource.makeTimerSource(queue: processingQueue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                let m = processor.metrics.current()
                log.info("metrics fps=\(m.framesPerSecond, format: .fixed(precision: 1)) latency=\(m.latencyMilliseconds, format: .fixed(precision: 2))ms in=\(Int(m.inputSize.width))x\(Int(m.inputSize.height)) proc=\(Int(m.processingSize.width))x\(Int(m.processingSize.height)) out=\(Int(m.outputSize.width))x\(Int(m.outputSize.height)) processed=\(m.processedFrames) dropped=\(m.droppedFrames)")
            }
            metricsTimer = timer
            timer.resume()
        }
    }

    var settings: FrameProcessor.Settings {
        get { processor.settings }
        set { processor.settings = newValue }
    }

    func start(uniqueID: String?, frameRate: OutputFrameRate) {
        capture.start(uniqueID: uniqueID, targetFrameRate: frameRate.rawValue)
    }

    func stop() {
        capture.stop()
    }

    func metricsSnapshot() -> ProcessingSnapshot {
        processor.metrics.current()
    }

    func resetMetrics() {
        processor.metrics.reset()
    }

    // MARK: - Hot path

    /// Called on the capture output queue. Must return fast: anything slow here
    /// stalls `AVCaptureVideoDataOutput`.
    private func receive(_ frame: VideoFrame) {
        let shouldProcess: Bool = busyLock.withLock {
            guard !isProcessing else { return false }
            isProcessing = true
            return true
        }

        guard shouldProcess else {
            processor.metrics.recordDropped()
            return
        }

        processingQueue.async { [self] in
            defer { busyLock.withLock { isProcessing = false } }

            #if DEBUG
            FrameDumper.dumpIfRequested(frame)
            #endif

            if wantsOriginalFrames {
                onOriginalFrame?(frame)
            }

            guard let processed = processor.process(frame) else { return }
            onProcessedFrame?(processed)
        }
    }
}
