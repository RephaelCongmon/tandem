import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encoding, scaling and change detection for snapshots.
public enum ImageCodec {
    public static let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Scales `image` so its longest edge is at most `maxDimension` (0 = unchanged).
    public static func scaled(_ image: CGImage, maxDimension: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard maxDimension > 0, longest > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(longest)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// JPEG-encodes an image (optionally downscaled). Returns data plus final size.
    public static func jpeg(_ image: CGImage, quality: Double, maxDimension: Int = 0) -> (data: Data, width: Int, height: Int)? {
        let output = scaled(image, maxDimension: maxDimension)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(max(quality, 0.1), 1.0),
            kCGImageDestinationOptimizeColorForSharing: true
        ]
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, output.width, output.height)
    }

    public static func png(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Decodes encoded image data at full size.
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Fast downscaled decode for thumbnails (never decodes the full image).
    public static func thumbnail(_ data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Pixel size of encoded image data without decoding it.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    // MARK: Change detection

    /// A tiny grayscale signature of an image (32×32 luminance), for cheap
    /// "did the screen change?" checks before sending snapshots.
    public struct Fingerprint: Sendable, Hashable {
        public static let side = 32
        public let luma: [UInt8]

        /// Mean absolute luminance difference in 0…1, with a small noise floor
        /// so compression/cursor flicker doesn't count as change.
        public func difference(from other: Fingerprint) -> Double {
            guard luma.count == other.luma.count, !luma.isEmpty else { return 1 }
            var total = 0
            var changedCells = 0
            for index in 0..<luma.count {
                let delta = abs(Int(luma[index]) - Int(other.luma[index]))
                if delta > 6 {
                    total += delta
                    changedCells += 1
                }
            }
            let meanDelta = Double(total) / Double(luma.count * 255)
            let coverage = Double(changedCells) / Double(luma.count)
            // Weighted so small-but-real changes (a new line of text) register.
            return min(1, meanDelta * 4 + coverage * 0.5)
        }
    }

    public static func fingerprint(_ image: CGImage) -> Fingerprint? {
        let side = Fingerprint.side
        var pixels = [UInt8](repeating: 0, count: side * side)
        let gray = CGColorSpaceCreateDeviceGray()
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn ? Fingerprint(luma: pixels) : nil
    }

    // MARK: Pixel buffers

    private static let ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: srgb])

    /// Converts a capture pixel buffer (BGRA or 420v/420f) into a CGImage.
    public static func cgImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: srgb)
    }
}
