import CoreImage
import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Turns pixel buffers into `CGImage`s for the SwiftUI preview.
///
/// The preview is a convenience, never a dependency: it is only fed while a
/// preview window is actually open, and dropping it has no effect on the frames
/// going to the virtual camera. Rendering is throttled independently of capture
/// so a 30 fps camera does not force 30 SwiftUI invalidations per second when
/// the window is small or occluded.
final class PreviewRenderer: @unchecked Sendable {

    /// Delivered on the main queue.
    var onImage: (@Sendable (CGImage) -> Void)?

    private let context: CIContext
    private let renderQueue = DispatchQueue(label: "com.harshanacz.Fuzzcam.preview", qos: .utility)
    private let lock = NSLock()
    private var _isEnabled = false
    private var lastRenderTime: CFTimeInterval = 0
    private var inFlight = false

    /// Preview refresh rate. Lower than capture on purpose — the preview exists
    /// to show a quality difference, which 20 fps conveys perfectly well.
    private let minimumInterval: CFTimeInterval = 1.0 / 20.0

    /// Longest edge of the rendered preview image. Rendering a full 720p CGImage
    /// for a small window is pure waste.
    private let maximumEdge: CGFloat = 640

    var isEnabled: Bool {
        get { lock.withLock { _isEnabled } }
        set { lock.withLock { _isEnabled = newValue } }
    }

    init() {
        // Metal-backed when available so the resize happens on the GPU. Falling
        // back to the default CIContext keeps the preview alive on a machine
        // where Metal is unavailable rather than failing outright.
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            context = CIContext(options: [.cacheIntermediates: false])
        }
    }

    /// Called on the capture queue. Returns immediately if the preview is off,
    /// throttled, or still busy with the previous frame.
    func submit(_ frame: VideoFrame) {
        guard isEnabled else { return }

        let now = CACurrentMediaTime()
        let shouldRender: Bool = lock.withLock {
            guard !inFlight, now - lastRenderTime >= minimumInterval else { return false }
            inFlight = true
            lastRenderTime = now
            return true
        }
        guard shouldRender else { return }

        renderQueue.async { [self] in
            defer { lock.withLock { inFlight = false } }

            var image = CIImage(cvPixelBuffer: frame.pixelBuffer)
            let extent = image.extent
            guard extent.width > 0, extent.height > 0 else { return }

            let scale = min(1.0, maximumEdge / max(extent.width, extent.height))
            if scale < 1.0 {
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }

            guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
            let handler = onImage
            DispatchQueue.main.async { handler?(cgImage) }
        }
    }
}
