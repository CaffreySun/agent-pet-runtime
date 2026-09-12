import Foundation

/// The only thing the validator needs from an image.
///
/// Keeping this abstract means the rules can be tested against synthetic
/// bitmaps with no image files, no CoreGraphics, and no 11 MB allocations.
public protocol AtlasBitmap: Sendable {
    var width: Int { get }
    var height: Int { get }
    /// False for a fully opaque format such as JPEG.
    var hasAlphaChannel: Bool { get }

    /// Number of pixels in `rect` whose alpha exceeds `alphaThreshold`.
    ///
    /// Callers use this two ways: `> 0` proves a cell has content, `== 0`
    /// proves it is entirely clear.
    func opaquePixelCount(in rect: CellRect, alphaThreshold: UInt8) -> Int
}

public extension AtlasBitmap {
    func isCellEmpty(_ rect: CellRect, alphaThreshold: UInt8) -> Bool {
        opaquePixelCount(in: rect, alphaThreshold: alphaThreshold) == 0
    }
}

/// An in-memory bitmap, used by tests and by anything that has already decoded
/// an image into RGBA.
public struct RGBAAtlasBitmap: AtlasBitmap, Sendable {
    public let width: Int
    public let height: Int
    /// Row-major RGBA, 4 bytes per pixel.
    public private(set) var pixels: [UInt8]
    public let hasAlphaChannel: Bool

    public init(width: Int, height: Int, pixels: [UInt8], hasAlpha: Bool = true) {
        precondition(pixels.count == width * height * 4, "pixel buffer must be RGBA")
        self.width = width
        self.height = height
        self.pixels = pixels
        self.hasAlphaChannel = hasAlpha
    }

    /// A bitmap of the given size with every pixel fully transparent.
    public static func empty(width: Int, height: Int, hasAlpha: Bool = true) -> RGBAAtlasBitmap {
        RGBAAtlasBitmap(
            width: width,
            height: height,
            pixels: [UInt8](repeating: 0, count: width * height * 4),
            hasAlpha: hasAlpha
        )
    }

    public func opaquePixelCount(in rect: CellRect, alphaThreshold: UInt8) -> Int {
        let x0 = max(0, rect.x), y0 = max(0, rect.y)
        let x1 = min(width, rect.x + rect.width), y1 = min(height, rect.y + rect.height)
        guard x0 < x1, y0 < y1 else { return 0 }

        var count = 0
        for y in y0..<y1 {
            var index = (y * width + x0) * 4 + 3
            for _ in x0..<x1 {
                if pixels[index] > alphaThreshold { count += 1 }
                index += 4
            }
        }
        return count
    }

    /// Fills a rect with an opaque colour. Tests use this to simulate a cell
    /// that has content, or a leftover that should have been cleared.
    public mutating func fill(_ rect: CellRect, rgba: (UInt8, UInt8, UInt8, UInt8) = (255, 0, 0, 255)) {
        let x0 = max(0, rect.x), y0 = max(0, rect.y)
        let x1 = min(width, rect.x + rect.width), y1 = min(height, rect.y + rect.height)
        guard x0 < x1, y0 < y1 else { return }
        for y in y0..<y1 {
            for x in x0..<x1 {
                let i = (y * width + x) * 4
                pixels[i] = rgba.0
                pixels[i + 1] = rgba.1
                pixels[i + 2] = rgba.2
                pixels[i + 3] = rgba.3
            }
        }
    }
}
