#if DEBUG
import CoreImage
import CoreVideo
import Foundation
import os

/// Debug-only harness that proves the degradation pipeline actually degrades.
///
/// Set `FUZZCAM_DUMP_DIR` to a directory and launch the app. On the first
/// camera frame it writes the untouched frame plus one processed frame per
/// quality preset, then stops. Comparing high-frequency energy across those
/// PNGs is an objective measure of detail loss — far better evidence than
/// squinting at a preview.
///
/// Compiled out of Release entirely, and inert unless the variable is set.
enum FrameDumper {

    private static let log = Logger(subsystem: "com.harshanacz.Fuzzcam", category: "FrameDumper")
    private static let lock = NSLock()
    private static var hasRun = false
    private static var framesSeen = 0

    /// Frames to discard before dumping. A camera's first frames are black or
    /// badly exposed while auto-exposure and auto-white-balance converge, and
    /// measuring detail on an unexposed frame is meaningless.
    private static let warmUpFrames = 60

    static var isEnabled: Bool { directory != nil }

    /// Dumps land inside the App Group container, because the app is sandboxed
    /// and cannot write to an arbitrary path. Set `FUZZCAM_DUMP=1` to enable;
    /// the log line at the end prints the exact directory.
    private static var directory: URL? {
        guard ProcessInfo.processInfo.environment["FUZZCAM_DUMP"] == "1" else { return nil }
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: FuzzcamIdentifiers.appGroupID
        ) else { return nil }
        return container.appendingPathComponent("dump", isDirectory: true)
    }

    /// Called on the processing queue with a live camera frame.
    static func dumpIfRequested(_ frame: VideoFrame) {
        guard let directory else { return }

        let shouldRun: Bool = lock.withLock {
            guard !hasRun else { return false }
            framesSeen += 1
            guard framesSeen >= warmUpFrames else { return false }
            hasRun = true
            return true
        }
        guard shouldRun else { return }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let context = CIContext(options: [.cacheIntermediates: false])
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }

        let sourceImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
        write(
            sourceImage,
            to: directory.appendingPathComponent("original.png"),
            context: context,
            colorSpace: colorSpace
        )

        // The source scaled to the output size, then cropped identically to the
        // presets — so "original" and "very low" can be compared pixel for pixel.
        let sourceExtent = sourceImage.extent
        let fit = CGFloat(VirtualCameraFormat.height) / sourceExtent.height
        let fitted = sourceImage.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
        let sourceCrop = CGRect(
            x: fitted.extent.midX - 280, y: fitted.extent.midY - 200,
            width: 560, height: 400
        )
        write(
            fitted.cropped(to: sourceCrop).transformed(
                by: CGAffineTransform(translationX: -sourceCrop.minX, y: -sourceCrop.minY)
            ),
            to: directory.appendingPathComponent("crop-source.png"),
            context: context,
            colorSpace: colorSpace
        )

        for preset in QualityPreset.allCases {
            let processor = FrameProcessor()
            var settings = FrameProcessor.Settings()
            settings.preset = preset
            // Neutral sharpness: judge the preset's own intrinsic degradation,
            // not the slider on top of it.
            settings.sharpness = 0.5
            processor.settings = settings

            guard let processed = processor.process(frame) else {
                log.error("dump: \(preset.rawValue, privacy: .public) produced no frame")
                continue
            }

            let output = CIImage(cvPixelBuffer: processed.pixelBuffer)
            write(
                output,
                to: directory.appendingPathComponent("preset-\(preset.rawValue).png"),
                context: context,
                colorSpace: colorSpace
            )

            // Centre crop at 1:1 so fine detail can actually be judged.
            let crop = CGRect(
                x: (CGFloat(VirtualCameraFormat.width) - 560) / 2,
                y: (CGFloat(VirtualCameraFormat.height) - 400) / 2,
                width: 560, height: 400
            )
            write(
                output.cropped(to: crop).transformed(
                    by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                ),
                to: directory.appendingPathComponent("crop-\(preset.rawValue).png"),
                context: context,
                colorSpace: colorSpace
            )

            let size = processor.lastProcessingSize
            log.info("dump: \(preset.rawValue, privacy: .public) processed at \(Int(size.width))×\(Int(size.height))")
        }

        // One extra frame exercising the optional controls, so their effect can
        // be measured too rather than assumed.
        let extras: [(String, (inout FrameProcessor.Settings) -> Void)] = [
            ("compression", { $0.preset = .low; $0.compression = 0.85 }),
            ("noise", { $0.preset = .low; $0.noise = 0.8 }),
            ("sharp", { $0.preset = .low; $0.sharpness = 1.0 }),
            ("soft", { $0.preset = .low; $0.sharpness = 0.0 }),
        ]

        for (name, configure) in extras {
            let processor = FrameProcessor()
            var settings = FrameProcessor.Settings()
            configure(&settings)
            processor.settings = settings
            guard let processed = processor.process(frame) else { continue }
            write(
                CIImage(cvPixelBuffer: processed.pixelBuffer),
                to: directory.appendingPathComponent("extra-\(name).png"),
                context: context,
                colorSpace: colorSpace
            )
        }

        log.info("dump complete in \(directory.path, privacy: .public)")
    }

    private static func write(
        _ image: CIImage,
        to url: URL,
        context: CIContext,
        colorSpace: CGColorSpace
    ) {
        do {
            try context.writePNGRepresentation(
                of: image,
                to: url,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        } catch {
            log.error("dump write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
