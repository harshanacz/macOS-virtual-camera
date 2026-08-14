import CoreVideo
import Foundation
import os

/// A recycling allocator for output pixel buffers.
///
/// Every processed frame needs a destination buffer. Allocating one per frame
/// would mean 30 IOSurface allocations per second and a steadily fragmenting
/// heap; `CVPixelBufferPool` hands the same small set of buffers back once the
/// consumer releases them.
///
/// Buffers are IOSurface-backed, which is what lets a frame cross into the
/// camera extension's process by reference instead of being copied.
final class PixelBufferPool: @unchecked Sendable {

    let width: Int
    let height: Int
    let pixelFormat: OSType

    private let pool: CVPixelBufferPool
    private let auxAttributes: CFDictionary

    /// Ceiling on live buffers. If the consumer somehow holds on to more than
    /// this, allocation fails and the caller drops the frame — bounded memory
    /// beats an unbounded queue that eventually takes the machine down.
    private static let allocationThreshold = 6

    init?(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat

        let bufferAttributes: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]

        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
            bufferAttributes as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let pool else { return nil }

        self.pool = pool
        self.auxAttributes = [
            kCVPixelBufferPoolAllocationThresholdKey as String: Self.allocationThreshold
        ] as CFDictionary
    }

    /// Returns a recycled buffer, or `nil` if the pool is exhausted.
    func makePixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, auxAttributes, &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    func matches(width: Int, height: Int) -> Bool {
        self.width == width && self.height == height
    }
}
