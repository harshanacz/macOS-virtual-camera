#if DEBUG
import AppKit
import CoreImage
import CoreVideo
import IOSurface
import Metal
import os

/// **DEVELOPMENT ONLY.** Compiled out of Release entirely.
///
/// A stop-gap for using Fuzzcam before the camera extension can be notarized.
/// macOS will not load an unnotarized camera system extension, so no device
/// named "Fuzzcam" can exist yet. This puts the processed frames into a plain
/// window instead, sized to exactly 1280×720 *backing pixels*, so an
/// already-notarized virtual camera (OBS) can capture it and hand it to Zoom.
///
///     camera → FrameProcessor → this window → OBS window capture
///            → OBS Virtual Camera → Zoom
///
/// The frames here are the identical `VideoFrame` objects the Processed preview
/// receives — the same buffers out of the same `FrameProcessor`. The untouched
/// camera image is never shown, so what OBS captures can only ever be the
/// degraded output.
///
/// This is a bridge, not an architecture. It does not touch the camera
/// extension, the processing pipeline, or production signing, and it disappears
/// the moment a notarized build exists. See `docs/DEV-CAMERA.md`.
final class DevCameraOutput: @unchecked Sendable {

    /// OBS lists windows by title; this is what to pick in its source list.
    static let windowTitle = "Fuzzcam Dev Output"

    private let log = Logger(subsystem: "com.harshanacz.Fuzzcam", category: "DevCameraOutput")

    private var window: NSWindow?
    private var surfaceView: FrameSurfaceView?
    private var backingObserver: NSObjectProtocol?

    private let lock = NSLock()
    private var _isRunning = false
    private var pendingFrame: VideoFrame?
    private var isDeliveryScheduled = false

    var isRunning: Bool { lock.withLock { _isRunning } }

    /// Set `FUZZCAM_DEV_OUTPUT=1` in the Xcode scheme to open this automatically
    /// on launch, so running from Xcode is all it takes.
    static var isAutoStartRequested: Bool {
        ProcessInfo.processInfo.environment["FUZZCAM_DEV_OUTPUT"] == "1"
    }

    // MARK: - Control

    @MainActor
    func start() {
        guard !isRunning else { return }

        // Provisional size; corrected to exact backing pixels once the window
        // exists and reports the scale factor of the display it is actually on.
        let size = NSSize(
            width: CGFloat(VirtualCameraFormat.width) / 2,
            height: CGFloat(VirtualCameraFormat.height) / 2
        )

        let view = FrameSurfaceView(frame: NSRect(origin: .zero, size: size), scale: 2)

        // Titled by default: it is easy to find and move, and OBS lists it by
        // name. The cost is a title bar inside the capture unless "Show Window
        // Title Bar" is unchecked in the OBS source. If that proves fiddly, set
        // FUZZCAM_DEV_OUTPUT_BORDERLESS=1 for a window that is nothing but the
        // 1280×720 image — drag it by its body.
        let borderless =
            ProcessInfo.processInfo.environment["FUZZCAM_DEV_OUTPUT_BORDERLESS"] == "1"
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: borderless ? [.borderless] : [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isMovableByWindowBackground = borderless
        window.title = Self.windowTitle
        window.contentView = view
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.setContentSize(size)
        window.center()

        // `orderFrontRegardless` shows it without stealing focus from whatever
        // the user is doing — this window is scenery for OBS, not a UI.
        window.orderFrontRegardless()

        self.window = window
        self.surfaceView = view
        lock.withLock { _isRunning = true }

        applyExactPixelSize()

        // A window dragged to a display with a different scale factor would
        // otherwise silently start capturing at the wrong pixel size.
        backingObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeBackingPropertiesNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyExactPixelSize() }
        }
    }

    /// Sizes the window so its backing store is exactly 1280×720 pixels on
    /// whichever display it currently occupies.
    ///
    /// This matters: if OBS captures 2560×1440 and rescales to a 720p canvas,
    /// the resampling softens edges and quietly undoes part of the degradation
    /// the whole app exists to produce. 1:1 keeps the output honest.
    @MainActor
    private func applyExactPixelSize() {
        guard let window, let surfaceView else { return }
        let scale = window.backingScaleFactor
        guard scale > 0 else { return }

        let size = NSSize(
            width: CGFloat(VirtualCameraFormat.width) / scale,
            height: CGFloat(VirtualCameraFormat.height) / scale
        )
        window.setContentSize(size)
        surfaceView.frame = NSRect(origin: .zero, size: size)
        surfaceView.updateScale(scale)

        log.info("dev output sized \(Int(size.width))×\(Int(size.height))pt @\(scale, format: .fixed(precision: 1))x = \(VirtualCameraFormat.width)×\(VirtualCameraFormat.height)px")
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        if let backingObserver {
            NotificationCenter.default.removeObserver(backingObserver)
            self.backingObserver = nil
        }
        window?.orderOut(nil)
        window = nil
        surfaceView = nil
        lock.withLock {
            _isRunning = false
            pendingFrame = nil
        }
        log.info("dev camera output stopped")
    }

    @MainActor
    func toggle() {
        isRunning ? stop() : start()
    }

    // MARK: - Frame delivery

    /// Called on the processing queue with the same frame the Processed preview
    /// gets. Coalescing rather than queueing: if the main thread has not drawn
    /// the previous frame yet, the newer one replaces it. A late frame is worth
    /// nothing, and an unbounded backlog would be worse than a dropped frame.
    func submit(_ frame: VideoFrame) {
        let shouldSchedule: Bool = lock.withLock {
            guard _isRunning else { return false }
            pendingFrame = frame
            guard !isDeliveryScheduled else { return false }
            isDeliveryScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        DispatchQueue.main.async { [self] in
            let frame: VideoFrame? = lock.withLock {
                isDeliveryScheduled = false
                defer { pendingFrame = nil }
                return pendingFrame
            }
            guard let frame else { return }
            MainActor.assumeIsolated { surfaceView?.display(frame) }
        }
    }
}

/// Displays a processed frame by handing its `IOSurface` straight to Core
/// Animation — no `CGImage`, no pixel copy, no colour conversion.
private final class FrameSurfaceView: NSView {

    /// The frame currently on screen is retained so the `CVPixelBufferPool`
    /// cannot recycle the buffer out from under Core Animation while it is
    /// still being displayed.
    private var displayedFrame: VideoFrame?

    /// Escape hatch. Handing an `IOSurface` to Core Animation is the fast,
    /// zero-copy path and is what this uses by default. If it ever renders
    /// black on some display configuration, set
    /// `FUZZCAM_DEV_OUTPUT_CGIMAGE=1` to fall back to rendering a `CGImage`
    /// per frame — slower, but the same path the preview already uses, so it
    /// is known to work.
    private let forceCGImagePath =
        ProcessInfo.processInfo.environment["FUZZCAM_DEV_OUTPUT_CGIMAGE"] == "1"

    private lazy var ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    init(frame: NSRect, scale: CGFloat) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        // Contents are already exactly the layer's pixel size, so this maps 1:1.
        layer?.contentsScale = scale
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }

    func updateScale(_ scale: CGFloat) {
        layer?.contentsScale = scale
    }

    func display(_ frame: VideoFrame) {
        let contents: Any?

        if forceCGImagePath {
            contents = ciContext.createCGImage(
                CIImage(cvPixelBuffer: frame.pixelBuffer),
                from: CGRect(x: 0, y: 0,
                             width: CGFloat(VirtualCameraFormat.width),
                             height: CGFloat(VirtualCameraFormat.height))
            )
        } else {
            contents = CVPixelBufferGetIOSurface(frame.pixelBuffer)?.takeUnretainedValue()
        }

        guard let contents else { return }

        // No implicit animation: this is video, every frame is a hard cut.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = contents
        CATransaction.commit()

        // Retain the frame only after the layer points at it, so the buffer is
        // never released while Core Animation is still reading it.
        displayedFrame = frame
    }
}
#endif
