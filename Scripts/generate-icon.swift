#!/usr/bin/env swift

// Builds the app icon and the menu bar icon from one source image.
//
// The app icon is `Resources/AppIcon-source.png` masked into Apple's macOS icon
// grid: the artwork sits in an 824x824 rounded square centred in a 1024x1024
// canvas, with a 185.4pt corner radius. The source is a full-bleed tile with
// its own (smaller) rounded corners; masking it here is what removes the dark
// corners it was generated with and what keeps it the same visual weight as
// every other app in the Dock.
//
// The menu bar icon cannot be the picture: at 18pt it would be mud, and menu
// bar icons must be template images — one ink colour, alpha only, so AppKit
// can invert them for dark menu bars and highlights. It is drawn instead, from
// geometry measured off the source (see `MenuBarGlyph`), and written as
// `Resources/StatusIcon.png` / `@2x.png` for the app bundle to load.
//
// Usage: swift Scripts/generate-icon.swift <output.iconset>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Apple's macOS icon grid

let canvas = 1024.0
let contentSize = 824.0
let cornerRadius = 185.4
let contentInset = (canvas - contentSize) / 2   // 100pt on every side

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),      ("icon_16x16@2x", 32),
    ("icon_32x32", 32),      ("icon_32x32@2x", 64),
    ("icon_128x128", 128),   ("icon_128x128@2x", 256),
    ("icon_256x256", 256),   ("icon_256x256@2x", 512),
    ("icon_512x512", 512),   ("icon_512x512@2x", 1024),
]

/// The rounded square Apple's grid specifies.
func squirclePath(insetBy inset: Double = 0) -> CGPath {
    CGPath(
        roundedRect: CGRect(
            x: contentInset + inset, y: contentInset + inset,
            width: contentSize - inset * 2, height: contentSize - inset * 2
        ),
        cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
    )
}

func makeContext(pixels: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create a \(pixels)px context") }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    // Work in the 1024pt design space at every size, so one set of numbers
    // describes the icon and downscaling does the rest.
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    return context
}

// MARK: - The app icon

/// Loads the source tile. It is committed so the icon can be rebuilt exactly.
func loadSource() -> CGImage {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/AppIcon-source.png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("could not read \(url.path)")
    }
    return image
}

func drawAppIcon(in context: CGContext, source: CGImage) {
    context.saveGState()
    context.addPath(squirclePath(insetBy: 2.5))   // clips the source's dark corners and their fringe
    context.clip()
    context.draw(source, in: CGRect(
        x: contentInset, y: contentInset, width: contentSize, height: contentSize
    ))
    context.restoreGState()
}

// MARK: - The menu bar glyph

/// The mascot, reduced to what survives at 18pt: the head and its two eyes,
/// with the ring as an arc behind it. Every number was measured off the source
/// (pixel 1254x1254) — the head's bounding box, the two eye ellipses, and the
/// ring's arc bounding box — then laid out in a square box around them.
enum MenuBarGlyph {

    static let box = 940.0                       // source pixels covered by the glyph
    static let centre = CGPoint(x: 634, y: 727)  // the ring's centre
    static let head = CGRect(x: 402, y: 366, width: 552, height: 438)
    static let eyes = [
        CGRect(x: 555, y: 567, width: 132, height: 124),
        CGRect(x: 779, y: 532, width: 124, height: 106),
    ]
    static let ringRadii = CGSize(width: 436, height: 272)
    static let ringTiltDegrees = -10.0
    static let ringThickness = 38.0

    /// Maps source coordinates into the glyph's square, origins bottom-left.
    private static func place(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(
            x: (x - centre.x) / box + 0.5,
            y: 0.5 - (y - centre.y) / box        // source y grows downward
        )
    }

    private static func ellipse(_ rect: CGRect, tiltedBy degrees: Double = 0) -> CGPath {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let path = CGPath(ellipseIn: rect, transform: nil)
        guard degrees != 0 else { return path }
        var tilt = CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: CGFloat(degrees * .pi / 180))
            .translatedBy(x: -centre.x, y: -centre.y)
        return path.copy(using: &tilt) ?? path
    }

    /// The ring, in glyph coordinates: an ellipse whose centre is the glyph's
    /// centre by construction, tilted the way the source's ring is.
    static func ringPath() -> CGPath {
        let rx = CGFloat(ringRadii.width / box)
        let ry = CGFloat(ringRadii.height / box)
        return ellipse(
            CGRect(x: 0.5 - rx, y: 0.5 - ry, width: rx * 2, height: ry * 2),
            tiltedBy: ringTiltDegrees
        )
    }

    static func ringWidth() -> CGFloat { CGFloat(ringThickness / box) }

    /// The head, as an ellipse through the corners of its measured bounding
    /// box. The raw silhouette has a bite taken out of it where the ring
    /// crosses in front; the ellipse is the shape underneath.
    static func headPath() -> CGPath {
        let topLeft = place(head.minX, head.maxY)
        return CGPath(ellipseIn: CGRect(
            x: topLeft.x, y: topLeft.y,
            width: head.width / box, height: head.height / box
        ), transform: nil)
    }

    /// The eyes, as holes to be punched out of the head.
    static func eyePaths() -> [CGPath] {
        eyes.map { eye in
            let topLeft = place(eye.minX, eye.maxY)
            return CGPath(ellipseIn: CGRect(
                x: topLeft.x, y: topLeft.y,
                width: eye.width / box, height: eye.height / box
            ), transform: nil)
        }
    }

    /// Renders the glyph into a square context of `pixels`, black ink on
    /// transparent — a template image for the menu bar.
    static func render(pixels: Int) -> CGImage {
        guard let context = CGContext(
            data: nil, width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("could not create the glyph context") }
        context.setAllowsAntialiasing(true)
        context.scaleBy(x: CGFloat(pixels), y: CGFloat(pixels))

        let ink = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.setStrokeColor(ink)
        context.setFillColor(ink)

        // The ring goes down first and the head covers its top, so the arc
        // shows at the sides and below — the way it passes behind the head.
        context.setLineWidth(ringWidth())
        context.setLineCap(.round)
        context.addPath(ringPath())
        context.strokePath()

        // Head with the eyes punched through, in one even-odd fill.
        let face = CGMutablePath()
        face.addPath(headPath())
        for eye in eyePaths() { face.addPath(eye) }
        context.addPath(face)
        context.fillPath(using: .evenOdd)

        guard let image = context.makeImage() else { fatalError("could not render the glyph") }
        return image
    }
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("could not write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("could not finalise \(url.path)")
    }
}

// MARK: - Run

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: generate-icon.swift <output.iconset>\n".utf8))
    exit(64)
}

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let source = loadSource()
for variant in variants {
    let context = makeContext(pixels: variant.pixels)
    drawAppIcon(in: context, source: source)
    guard let image = context.makeImage() else { fatalError("could not render \(variant.name)") }
    write(image, to: output.appendingPathComponent("\(variant.name).png"))
    print("  \(variant.name).png  \(variant.pixels)x\(variant.pixels)")
}

// The menu bar icons, beside the source so the bundle can copy them.
for (name, pixels) in [("StatusIcon.png", 18), ("StatusIcon@2x.png", 36)] {
    let url = repo.appendingPathComponent("Resources/\(name)")
    write(MenuBarGlyph.render(pixels: pixels), to: url)
    print("  \(name)  \(pixels)x\(pixels)")
}

// The README logo, masked the same way the app icon is.
let logo = makeContext(pixels: 512)
drawAppIcon(in: logo, source: source)
if let image = logo.makeImage() {
    write(image, to: repo.appendingPathComponent("Resources/AppIcon-512.png"))
    print("  AppIcon-512.png  512x512")
}

print("wrote \(variants.count) icon images, the menu bar glyph, and the README logo")
