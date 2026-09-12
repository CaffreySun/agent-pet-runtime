import CoreGraphics
import Foundation

/// A pet's atlas pre-sliced into the frames the renderer will draw.
///
/// `CGImage.cropping(to:)` does not copy pixels — the slices share the decoded
/// buffer — so holding all of them costs one atlas, not seventy-two. Slicing
/// once at load time keeps the draw loop free of arithmetic on a frame budget.
public struct SpriteFrames: Sendable {
    /// Track name to its frames, in playback order.
    public let frames: [String: [CGImage]]
    public let profile: CompatibilityProfile
    public let cellSize: CGSize

    public init(bitmap: RGBAAtlasBitmap, profile: CompatibilityProfile) throws {
        guard let fullImage = Self.makeCGImage(from: bitmap) else {
            throw SpriteFramesError.cannotCreateImage
        }

        self.profile = profile
        self.cellSize = CGSize(width: profile.cellWidth, height: profile.cellHeight)

        let atlas = SpriteAtlas(profile: profile)
        var sliced: [String: [CGImage]] = [:]

        for track in profile.tracks where track.frameCount > 0 {
            var images: [CGImage] = []
            for rect in atlas.rects(for: track) {
                // CGImage cropping is in image coordinates, which already have
                // their origin at the top left, so no vertical flip is needed.
                let cgRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                if let frame = fullImage.cropping(to: cgRect) {
                    images.append(frame)
                }
            }
            sliced[track.name] = images
        }

        self.frames = sliced
    }

    public func frame(track: String, column: Int) -> CGImage? {
        guard let images = frames[track], !images.isEmpty else { return nil }
        return images[min(max(0, column), images.count - 1)]
    }

    public func image(for frame: AnimationFrame) -> CGImage? {
        self.frame(track: frame.trackName, column: frame.column)
    }

    public var isEmpty: Bool { frames.values.allSatisfy(\.isEmpty) }

    static func makeCGImage(from bitmap: RGBAAtlasBitmap) -> CGImage? {
        let bytesPerRow = bitmap.width * 4
        guard let provider = CGDataProvider(data: Data(bitmap.pixels) as CFData) else { return nil }

        return CGImage(
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            // The decoder drew into premultipliedLast, so these bytes are
            // already premultiplied; declaring anything else shifts every
            // partly transparent edge pixel.
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

public enum SpriteFramesError: Error, Equatable, Sendable {
    case cannotCreateImage
}
