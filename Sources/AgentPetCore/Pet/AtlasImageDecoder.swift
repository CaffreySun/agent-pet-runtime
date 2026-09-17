import CoreGraphics
import Foundation
import ImageIO

public enum ImageDecodingError: Error, Equatable, Sendable {
    case cannotOpen(String)
    case notAnImage(String)
    case unreadable(String)
    case rasterisationFailed(String)

    /// The same facts, in a sentence — what `--diagnose` prints when a pet
    /// package's spritesheet is the reason it cannot be listed.
    public var message: String {
        switch self {
        case .cannotOpen(let file):           return "\(file) could not be opened"
        case .notAnImage(let file):           return "\(file) is not an image"
        case .unreadable(let file):           return "\(file) could not be decoded"
        case .rasterisationFailed(let file):  return "\(file) could not be drawn into a bitmap"
        }
    }
}

/// Cheap facts about an image file, obtainable without decoding its pixels.
public struct AtlasImageMetadata: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let hasAlpha: Bool
}

/// Reads sprite atlases off disk.
///
/// Dimensions are available from the file header, so a package can be rejected
/// for having the wrong geometry without ever allocating its 11 MB pixel
/// buffer. Only a package that passes that gate gets fully decoded.
public enum AtlasImageDecoder {

    public static func metadata(at url: URL) throws -> AtlasImageMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageDecodingError.cannotOpen(url.lastPathComponent)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw ImageDecodingError.notAnImage(url.lastPathComponent)
        }
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ImageDecodingError.notAnImage(url.lastPathComponent)
        }

        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false
        return AtlasImageMetadata(width: width, height: height, hasAlpha: hasAlpha)
    }

    /// Full decode into 8-bit RGBA, origin top-left.
    ///
    /// Drawing into our own context rather than reading the `CGImage` directly
    /// is deliberate: it normalises whatever colour space and channel order the
    /// file happens to use into the one layout the validator understands.
    public static func loadRGBA(at url: URL) throws -> RGBAAtlasBitmap {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageDecodingError.cannotOpen(url.lastPathComponent)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageDecodingError.unreadable(url.lastPathComponent)
        }

        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)

        let success: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard success else {
            throw ImageDecodingError.rasterisationFailed(url.lastPathComponent)
        }

        return RGBAAtlasBitmap(
            width: width,
            height: height,
            pixels: buffer,
            hasAlpha: hasAlpha(in: image)
        )
    }

    /// `CGImage.alphaInfo` reports `none` for formats with no alpha channel and
    /// `noneSkip*` for opaque formats, so only the genuinely transparent
    /// variants count.
    private static func hasAlpha(in image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .premultipliedFirst, .premultipliedLast, .first, .last, .alphaOnly:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            return false
        }
    }
}
