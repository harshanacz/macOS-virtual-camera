import CoreGraphics
import CoreText
import CoreVideo
import Foundation

/// The frame the virtual camera shows when Fuzzcam.app is not feeding it.
///
/// This architecture puts all processing in the app, so when the app is not
/// running there is nothing to publish. Sending nothing at all makes
/// conferencing apps hang on a black rectangle or time out; sending a card that
/// says what is wrong turns a mystery into an instruction.
///
/// Rendered exactly once and then re-sent with fresh timestamps — the extension
/// must stay cheap, so there is no per-frame drawing here.
enum PlaceholderFrame {

    static func make(
        width: Int,
        height: Int,
        title: String,
        message: String
    ) -> CVPixelBuffer? {

        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }

        context.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        draw(title, in: context, canvasWidth: width, baselineY: CGFloat(height) / 2 + 8,
             fontSize: 46, gray: 0.92)
        draw(message, in: context, canvasWidth: width, baselineY: CGFloat(height) / 2 - 44,
             fontSize: 22, gray: 0.55)

        return pixelBuffer
    }

    private static func draw(
        _ text: String,
        in context: CGContext,
        canvasWidth: Int,
        baselineY: CGFloat,
        fontSize: CGFloat,
        gray: CGFloat
    ) {
        // Core Text attribute keys rather than `NSAttributedString.Key`: those
        // live in AppKit, which a system extension has no business linking.
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: gray, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            text as CFString,
            attributes as CFDictionary
        )
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(canvasWidth) - bounds.width) / 2, y: baselineY)
        CTLineDraw(line, context)
    }
}
