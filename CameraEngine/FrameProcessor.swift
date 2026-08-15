import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import QuartzCore
import os

/// Turns a sharp camera frame into a convincingly cheap one.
///
/// **The single source of truth for degradation.** The Processed preview, the
/// development output window and the production camera extension all consume the
/// exact `VideoFrame` this produces. There is deliberately no second
/// implementation anywhere.
///
/// The whole chain is one Core Image graph, evaluated once on the GPU and
/// rendered straight into a pooled IOSurface buffer. No intermediate `CGImage`,
/// no `NSImage`, no CPU pixel loop.
///
/// ## Why it looks like this
///
/// Simply downscaling produces a clean small picture, which reads as
/// "downscaled", not "bad camera". What actually makes cheap webcams look cheap
/// is a specific set of failures, and the chain reproduces them in the order a
/// real camera commits them:
///
///   1. **Resample** to the preset's resolution — the irreversible step. A small
///      sensor genuinely cannot resolve fine detail.
///   2. **Smear micro-texture** while leaving edges intact, the way aggressive
///      in-camera noise reduction does. Skin turns waxy, hair becomes a mass.
///      This is the most convincing single cue.
///   3. **Soften chroma only**, keeping luma sharp — heavy chroma subsampling
///      and a weak demosaic. Colour bleeds across edges while shapes stay put.
///   4. **Flatten tone**: lift the shadows, pull contrast and saturation in.
///   5. **Over-sharpen**, because cheap cameras compensate for a soft lens and
///      leave crunchy halos. This is what stops the result reading as "blurred".
///   6. **Add grain**, then
///   7. **Compress**, so the codec has grain and halos to mangle.
///   8. **Upscale** to the output format, letterboxed, never stretched.
///
/// Everything from 2 to 7 runs at the *intermediate* resolution, where there are
/// a fraction of the pixels, which is what keeps this affordable.
///
/// A plain Gaussian blur is not in the default path at any preset. It exists
/// only if the user explicitly asks for it.
final class FrameProcessor: @unchecked Sendable {

    struct Settings: Equatable, Sendable {
        var preset: QualityPreset = .low
        /// 0 = softer than the preset intends, 0.5 = exactly as intended,
        /// 1 = sharpened. Cannot restore detail the resample discarded.
        var sharpness: Double = 0.5
        /// Added on top of the preset's own compression floor.
        var compression: Double = 0.0
        /// 0 = none, 1 = heavy grain.
        var noise: Double = 0.0
        var blurEnabled: Bool = false
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
    private var _lastProcessingSize: CGSize = .zero

    var settings: Settings {
        get { lock.withLock { _settings } }
        set { lock.withLock { _settings = newValue } }
    }

    /// The resolution actually used last frame. Depends on the source aspect
    /// ratio, so it is not knowable from the preset alone.
    var lastProcessingSize: CGSize { lock.withLock { _lastProcessingSize } }

    init(outputSize: CGSize = VirtualCameraFormat.size) {
        self.outputSize = outputSize

        // No colour management: input and output are both BGRA in the same
        // space, so a working colour space would add two conversions per frame
        // for an identity transform.
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
        ]

        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: options)
        } else {
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
        let preset = settings.preset

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

        // 1. Resample — the irreversible step.
        if let target = preset.intermediateSize(forSource: sourceExtent.size) {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: target.height / sourceExtent.height,
                kCIInputAspectRatioKey: 1.0,
            ])
        }

        let processingExtent = image.extent
        lock.withLock { _lastProcessingSize = processingExtent.size }

        // The sharpness slider biases the preset rather than replacing it.
        // Below the midpoint it smears further; above, it sharpens. Even at 1.0
        // the preset's own smear floor stays, so Very Low can never be talked
        // back into looking like the source.
        let sharpnessBias = (0.5 - settings.sharpness) * 2   // +1 softest … -1 sharpest
        let smear = (preset.detailSmear + sharpnessBias * 0.35).clamped(to: 0...1)
        let extraSharpen = max(0, -sharpnessBias)

        image = applyDetailSmear(smear, to: image)
        image = applyChromaSoftness(preset.chromaSoftness, to: image)
        image = applyTonalFlatness(preset.tonalFlatness, to: image)
        image = applyEdgeCrunch(preset.edgeCrunch + extraSharpen * 0.5, to: image)
        image = applyNoise(settings.noise, to: image, frameIndex: index)

        let compression = min(1, preset.intrinsicCompression + settings.compression * 0.7)
        image = applyCompression(compression, to: image)

        // 8. Fit to the output format without ever changing the aspect ratio.
        image = fitToOutput(image)

        if settings.blurEnabled, settings.blurRadius > 0.01 {
            let bounds = image.extent
            image = image
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: settings.blurRadius])
                .cropped(to: bounds)
        }

        // Composite over black so letterbox bars are opaque — a conferencing app
        // handed alpha=0 shows garbage.
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let background = CIImage(color: .black).cropped(to: outputRect)
        let composed = image.composited(over: background).cropped(to: outputRect)

        context.render(composed, to: destination, bounds: outputRect, colorSpace: nil)

        metrics.recordProcessed(
            input: sourceExtent.size,
            processing: processingExtent.size,
            output: outputSize,
            latency: CACurrentMediaTime() - started
        )

        return VideoFrame(pixelBuffer: destination, presentationTime: frame.presentationTime)
    }

    // MARK: - Stages

    /// Smears fine texture while leaving edges standing.
    ///
    /// `CINoiseReduction` is an edge-preserving smoother, so pushing it well past
    /// any sensible denoising setting gives exactly the over-processed look of a
    /// cheap sensor's noise reduction: pores, stubble and individual hairs
    /// dissolve, but the outline of a face stays crisp. A Gaussian blur would
    /// destroy both, which is the difference between "cheap webcam" and
    /// "blur filter".
    private func applyDetailSmear(_ amount: Double, to image: CIImage) -> CIImage {
        guard amount > 0.01 else { return image }
        let bounds = image.extent
        return image
            .applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": 0.008 + amount * 0.055,
                "inputSharpness": 0.9 - amount * 0.75,
            ])
            .cropped(to: bounds)
    }

    /// Keeps luma sharp and blurs only colour, the way 4:2:0 subsampling and a
    /// weak demosaic do. Colour bleeds across edges while shapes stay put.
    ///
    /// `CILuminosityBlendMode` takes luminosity from the foreground and hue plus
    /// saturation from the background, so one blur and one blend separate the
    /// channels without ever converting colour spaces by hand.
    private func applyChromaSoftness(_ amount: Double, to image: CIImage) -> CIImage {
        guard amount > 0.01 else { return image }
        let bounds = image.extent
        let blurred = image
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6 + amount * 2.6])
            .cropped(to: bounds)
        return image
            .applyingFilter("CILuminosityBlendMode", parameters: [
                kCIInputBackgroundImageKey: blurred
            ])
            .cropped(to: bounds)
    }

    /// Lifted shadows, flatter contrast, slightly drained colour — a small
    /// sensor with no dynamic range in reserve.
    private func applyTonalFlatness(_ amount: Double, to image: CIImage) -> CIImage {
        guard amount > 0.01 else { return image }
        return image.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1.0 - amount * 0.16,
            kCIInputBrightnessKey: amount * 0.045,
            kCIInputSaturationKey: 1.0 - amount * 0.14,
        ])
    }

    /// Halos around edges. Counter-intuitive but essential: cheap cameras
    /// over-sharpen to hide a soft lens, and without this the result reads as
    /// blurred rather than cheap.
    private func applyEdgeCrunch(_ amount: Double, to image: CIImage) -> CIImage {
        guard amount > 0.01 else { return image }
        let bounds = image.extent
        return image
            .applyingFilter("CIUnsharpMask", parameters: [
                kCIInputRadiusKey: 1.1,
                kCIInputIntensityKey: min(1.2, amount * 0.95),
            ])
            .cropped(to: bounds)
    }

    /// Animated luminance grain.
    ///
    /// `CIRandomGenerator` is deterministic, so a fixed crop would give the same
    /// pattern every frame and read as a dirty lens. Translating the field per
    /// frame animates it for free.
    private func applyNoise(_ noise: Double, to image: CIImage, frameIndex: UInt64) -> CIImage {
        guard noise > 0.01 else { return image }

        let bounds = image.extent
        let grain = CIFilter(name: "CIRandomGenerator")?.outputImage?
            .transformed(by: CGAffineTransform(
                translationX: CGFloat(frameIndex &* 71 % 1024),
                y: CGFloat(frameIndex &* 137 % 1024)
            ))
            .cropped(to: bounds)
        guard let grain else { return image }

        // Desaturate to luminance grain centred on mid-grey, so the overlay
        // darkens and lightens equally instead of just lifting the image.
        let monochrome = grain.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputGVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputBVector": CIVector(x: 0.33, y: 0.33, z: 0.33, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])

        let grained = monochrome
            .applyingFilter("CIOverlayBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            .cropped(to: bounds)

        return image
            .applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: grained,
                kCIInputTimeKey: noise * 0.5,
            ])
            .cropped(to: bounds)
    }

    /// Approximates lossy-codec damage without running an actual encode.
    ///
    /// A real JPEG round trip per frame would cost more than the rest of the
    /// pipeline combined. Quantising to 8×8 blocks and cutting the palette
    /// reproduces what people recognise as compression damage, in two GPU passes.
    ///
    /// The blend tops out well below full strength on purpose. Real low-bitrate
    /// video is blocky in flat regions and merely soft elsewhere; replacing the
    /// whole frame with its blocky version looks like a broken effect, not a bad
    /// connection.
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

        // Banding: fewer available levels as the bitrate drops.
        let banded = blocky.applyingFilter("CIColorPosterize", parameters: [
            "inputLevels": 48.0 - 34.0 * compression
        ])

        return image
            .applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: banded,
                kCIInputTimeKey: compression * 0.45,
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
