import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import os

/// Turns a sharp camera frame into a convincingly cheap one.
///
/// The whole chain is a single Core Image graph evaluated once on the GPU and
/// rendered straight into a pooled IOSurface buffer. There is no intermediate
/// `CGImage`, no `NSImage`, and no CPU pixel loop anywhere.
///
/// Order matters:
///
///   1. **Downsample** to the preset's intermediate size. This is the step that
///      does the real work — resampling 1080p to 360p physically discards the
///      high-frequency information that reads as "sharp". Nothing downstream can
///      put it back.
///   2. **Sharpness** trims or restores acutance *at the low resolution*, where
///      a sub-pixel radius is enough to change the character of the image.
///   3. **Compression** simulates 8×8 block artefacts and palette banding.
///   4. **Noise** adds animated grain.
///   5. **Upscale** to the virtual camera's fixed output size, letterboxed so a
///      4:3 camera is never stretched into 16:9.
///
/// Gaussian blur is *not* part of the default path. Step 2 at default settings
/// applies well under a pixel of softening at the intermediate resolution; the
/// visible effect is lost detail, not a blurred face. A real blur is available
/// only when the user explicitly turns it on.
final class FrameProcessor: @unchecked Sendable {

    struct Settings: Equatable, Sendable {
        var preset: QualityPreset = .low
        /// 0 = softest, 0.5 = untouched, 1 = sharpened.
        var sharpness: Double = 0.30
        /// 0 = clean, 1 = heavy blocking and banding.
        var compression: Double = 0.0
        /// 0 = none, 1 = heavy grain.
        var noise: Double = 0.0
        var blurEnabled: Bool = false
        /// Radius in output pixels, only used when `blurEnabled`.
        var blurRadius: Double = 0.0

        init() {}

        init(_ configuration: FuzzcamConfiguration) {
            preset = configuration.preset
            sharpness = configuration.sharpness
            compression = configuration.compression
            noise = configuration.noise
            blurEnabled = configuration.blurEnabled
            blurRadius = configuration.blurRadius
        }
    }

    let metrics = ProcessingMetrics()

    private let log = Logger(subsystem: "com.harshanacz.Fuzzcam", category: "FrameProcessor")
    private let context: CIContext
    private let outputSize: CGSize
    private var pool: PixelBufferPool?

    private let lock = NSLock()
    private var _settings = Settings()
    private var frameIndex: UInt64 = 0

    /// Cached so the preview can report the resolution actually being used,
    /// which depends on the source aspect ratio and so is not knowable from the
    /// preset alone.
    private var _lastProcessingSize: CGSize = .zero

    var settings: Settings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }

    var lastProcessingSize: CGSize { lock.withLock { _lastProcessingSize } }

    init(outputSize: CGSize = VirtualCameraFormat.size) {
        self.outputSize = outputSize

        // No colour management: input and output are both BGRA in the same
        // space, so a working colour space would add two conversions per frame
        // for an identity transform. `cacheIntermediates: false` keeps the
        // per-frame graph from accumulating tiles we will never reuse.
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
        ]

        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
            // Software fallback keeps the pipeline alive on a machine with no
            // usable Metal device rather than failing outright.
            context = CIContext(options: options)
        }

        pool = PixelBufferPool(width: Int(outputSize.width), height: Int(outputSize.height))
        if pool == nil {
            log.error("could not create the output buffer pool at \(Int(outputSize.width))×\(Int(outputSize.height))")
        }
    }

    /// Processes one frame. Returns `nil` if the frame was unusable or the pool
    /// was exhausted — the caller drops it and carries on.
    ///
    /// Called on the processing queue, never on the main thread.
    func process(_ frame: VideoFrame) -> VideoFrame? {
        let started = CACurrentMediaTime()
        let settings = self.settings

        let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
        let sourceExtent = source.extent
        guard sourceExtent.width >= 2, sourceExtent.height >= 2 else {
            metrics.recordDropped()
            return nil
        }

        guard let pool, let destination = pool.makePixelBuffer() else {
            metrics.recordDropped()
            return nil
        }

        let index = lock.withLock { () -> UInt64 in
            frameIndex &+= 1
            return frameIndex
        }

        var image = source

        // 1. Downsample — the load-bearing step.
        if let target = settings.preset.intermediateSize(forSource: sourceExtent.size) {
            let scale = target.height / sourceExtent.height
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1.0,
            ])
        }

        let processingExtent = image.extent
        lock.withLock { _lastProcessingSize = processingExtent.size }

        image = applySharpness(settings.sharpness, to: image)
        image = applyCompression(settings.compression, to: image)
        image = applyNoise(settings.noise, to: image, frameIndex: index)

        // 5. Fit to the output format without ever changing the aspect ratio.
        image = fitToOutput(image)

        if settings.blurEnabled, settings.blurRadius > 0.01 {
            let bounds = image.extent
            image = image
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.blurRadius])
                .cropped(to: bounds)
        }

        // Composite over black so letterbox bars are opaque rather than
        // transparent — a conferencing app receiving alpha=0 shows garbage.
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let background = CIImage(color: .black).cropped(to: outputRect)
        let composed = image.composited(over: background).cropped(to: outputRect)

        context.render(
            composed,
            to: destination,
            bounds: outputRect,
            colorSpace: nil
        )

        metrics.recordProcessed(
            input: sourceExtent.size,
            processing: processingExtent.size,
            output: outputSize,
            latency: CACurrentMediaTime() - started
        )

        return VideoFrame(pixelBuffer: destination, presentationTime: frame.presentationTime)
    }

    // MARK: - Stages

    /// Below 0.5 this softens, above 0.5 it sharpens, and 0.5 is a no-op.
    ///
    /// The radius ceiling is deliberately just over one pixel *at the
    /// intermediate resolution*. At the 0.30 default that works out to well
    /// under half a pixel — enough to take the digital edge off, nowhere near
    /// enough to read as blur.
    private func applySharpness(_ sharpness: Double, to image: CIImage) -> CIImage {
        let bounds = image.extent

        if sharpness < 0.5 {
            let radius = (0.5 - sharpness) / 0.5 * 1.1
            guard radius > 0.05 else { return image }
            return image
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: bounds)
        }

        if sharpness > 0.5 {
            let intensity = (sharpness - 0.5) / 0.5 * 0.9
            return image
                .applyingFilter("CIUnsharpMask", parameters: [
                    kCIInputRadiusKey: 1.2,
                    kCIInputIntensityKey: intensity,
                ])
                .cropped(to: bounds)
        }

        return image
    }

    /// Approximates lossy-codec damage without running an actual encode.
    ///
    /// A real JPEG round trip per frame would cost more than the rest of the
    /// pipeline combined. Quantising to 8×8 blocks and cutting the palette
    /// reproduces what people actually recognise as compression artefacts, on
    /// the GPU, in two passes.
    private func applyCompression(_ compression: Double, to image: CIImage) -> CIImage {
        guard compression > 0.01 else { return image }

        let bounds = image.extent
        let block: CGFloat = 8

        let blocky = image
            .transformed(by: CGAffineTransform(scaleX: 1 / block, y: 1 / block))
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: block, y: block))
            .samplingNearest()
            .cropped(to: bounds)

        let levels = 32.0 - 20.0 * compression
        let banded = blocky.applyingFilter("CIColorPosterize", parameters: [
            "inputLevels": levels
        ])

        // Blend rather than replace: even a heavily compressed webcam still
        // resolves most of the frame cleanly.
        return image
            .applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: banded,
                kCIInputTimeKey: compression * 0.6,
            ])
            .cropped(to: bounds)
    }

    /// Animated luminance grain.
    ///
    /// `CIRandomGenerator` is deterministic, so a fixed crop would produce the
    /// same pattern every frame and read as a dirty lens rather than sensor
    /// noise. Translating the field by a per-frame offset animates it for free.
    private func applyNoise(_ noise: Double, to image: CIImage, frameIndex: UInt64) -> CIImage {
        guard noise > 0.01 else { return image }

        let bounds = image.extent
        let offsetX = CGFloat(frameIndex &* 71 % 1024)
        let offsetY = CGFloat(frameIndex &* 137 % 1024)
        let amplitude = noise * 0.5

        let grain = CIFilter(name: "CIRandomGenerator")?.outputImage?
            .transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
            .cropped(to: bounds)

        guard let grain else { return image }

        // Desaturate to luminance grain and centre it on mid-grey so the
        // overlay blend darkens and lightens equally instead of just lifting
        // the image.
        let monochrome = grain.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])

        let grained = monochrome
            .applyingFilter("CIOverlayBlendMode", parameters: [
                kCIInputBackgroundImageKey: image
            ])
            .cropped(to: bounds)

        return image
            .applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: grained,
                kCIInputTimeKey: amplitude,
            ])
            .cropped(to: bounds)
    }

    /// Scales to fill as much of the output as the aspect ratio allows and
    /// centres the result. Never stretches.
    private func fitToOutput(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let scale = min(outputSize.width / extent.width, outputSize.height / extent.height)
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .samplingLinear()

        let scaledExtent = scaled.extent
        let dx = ((outputSize.width - scaledExtent.width) / 2 - scaledExtent.minX).rounded()
        let dy = ((outputSize.height - scaledExtent.height) / 2 - scaledExtent.minY).rounded()

        return scaled.transformed(by: CGAffineTransform(translationX: dx, y: dy))
    }
}
