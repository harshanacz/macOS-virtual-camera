import Foundation
import QuartzCore

/// Instrumentation for the processing pipeline.
///
/// Sampled by the developer overlay and the debug log. Deliberately cheap:
/// a handful of integer/double updates per frame behind one lock, no
/// allocation, and nothing published unless somebody asks.
struct ProcessingSnapshot: Equatable, Sendable {
    var inputSize: CGSize = .zero
    var processingSize: CGSize = .zero
    var outputSize: CGSize = .zero
    var framesPerSecond: Double = 0
    /// Milliseconds spent in the filter chain plus the render, averaged.
    var latencyMilliseconds: Double = 0
    var droppedFrames: Int = 0
    var processedFrames: Int = 0

    var isEmpty: Bool { processedFrames == 0 && droppedFrames == 0 }
}

final class ProcessingMetrics: @unchecked Sendable {

    private let lock = NSLock()
    private var snapshot = ProcessingSnapshot()

    private var windowStart = CACurrentMediaTime()
    private var windowFrames = 0
    private var latencyAccumulator: Double = 0

    /// Exponential smoothing keeps the displayed latency readable instead of
    /// flickering with every frame.
    private let latencySmoothing = 0.15

    func recordProcessed(
        input: CGSize,
        processing: CGSize,
        output: CGSize,
        latency: Double
    ) {
        lock.lock()
        defer { lock.unlock() }

        snapshot.inputSize = input
        snapshot.processingSize = processing
        snapshot.outputSize = output
        snapshot.processedFrames += 1

        let ms = latency * 1000
        snapshot.latencyMilliseconds = snapshot.latencyMilliseconds == 0
            ? ms
            : snapshot.latencyMilliseconds + (ms - snapshot.latencyMilliseconds) * latencySmoothing

        windowFrames += 1
        let now = CACurrentMediaTime()
        let elapsed = now - windowStart
        if elapsed >= 1.0 {
            snapshot.framesPerSecond = Double(windowFrames) / elapsed
            windowFrames = 0
            windowStart = now
        }
    }

    func recordDropped() {
        lock.lock()
        snapshot.droppedFrames += 1
        lock.unlock()
    }

    func current() -> ProcessingSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func reset() {
        lock.lock()
        snapshot = ProcessingSnapshot()
        windowStart = CACurrentMediaTime()
        windowFrames = 0
        latencyAccumulator = 0
        lock.unlock()
    }
}
