#!/usr/bin/env swift

// Draws the app icon and writes a full macOS `.iconset`.
//
// Follows Apple's macOS icon grid rather than filling the canvas: the artwork
// sits in an 824x824 rounded square centred in a 1024x1024 canvas, with a
// 185.4pt corner radius. Icons that fill their canvas edge to edge look
// oversized next to every other app in the Dock because they skip that inset.
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

// Every size macOS asks for, at both scales. The @1x and @2x entries are
// separate files because the Dock picks between them by display scale, not by
// resampling one image.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),      ("icon_16x16@2x", 32),
    ("icon_32x32", 32),      ("icon_32x32@2x", 64),
    ("icon_128x128", 128),   ("icon_128x128@2x", 256),
    ("icon_256x256", 256),   ("icon_256x256@2x", 512),
    ("icon_512x512", 512),   ("icon_512x512@2x", 1024),
]

// MARK: - Drawing

func makeContext(pixels: Int) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("could not create a \(pixels)px context")
    }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    // Work in the 1024pt design space at every size, so one set of numbers
    // describes the icon and downscaling does the rest.
    context.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    return context
}

/// The rounded square Apple's grid specifies.
func squirclePath() -> CGPath {
    CGPath(
        roundedRect: CGRect(x: contentInset, y: contentInset,
                            width: contentSize, height: contentSize),
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
}

func drawIcon(in context: CGContext) {
    let shape = squirclePath()

    // Background: a lively orange, which is a cat's colour and nothing else's.
    // The icon used to be a white paw on blue — Baidu's mark at a glance. Warm
    // ground plus dark prints is the menu bar emoji's own arrangement.
    context.saveGState()
    context.addPath(shape)
    context.clip()

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 1.00, green: 0.72, blue: 0.26, alpha: 1),
            CGColor(red: 0.95, green: 0.33, blue: 0.10, alpha: 1),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: contentInset, y: contentInset + contentSize),
        end: CGPoint(x: contentInset + contentSize, y: contentInset),
        options: []
    )

    // A soft highlight, so the surface reads as a physical tile.
    let highlight = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 1, green: 0.97, blue: 0.86, alpha: 0.55),
            CGColor(red: 1, green: 0.97, blue: 0.86, alpha: 0),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        highlight,
        startCenter: CGPoint(x: canvas * 0.34, y: canvas * 0.78), startRadius: 0,
        endCenter: CGPoint(x: canvas * 0.34, y: canvas * 0.78), endRadius: contentSize * 0.75,
        options: []
    )
    context.restoreGState()

    // Two paw prints walking across the tile, back foot first — the menu bar
    // emoji's arrangement, drawn rather than borrowed: the glyph itself is
    // Apple's artwork and has no business being baked into a shipped bundle.
    let ink = CGColor(red: 0.25, green: 0.14, blue: 0.06, alpha: 1)
    context.setFillColor(ink)

    let centre = CGPoint(x: canvas / 2, y: canvas / 2)
    drawPaw(in: context, centre: CGPoint(x: centre.x - contentSize * 0.185,
                                         y: centre.y + contentSize * 0.185),
            size: contentSize * 0.340, rotationDegrees: -18)
    drawPaw(in: context, centre: CGPoint(x: centre.x + contentSize * 0.185,
                                         y: centre.y - contentSize * 0.190),
            size: contentSize * 0.385, rotationDegrees: 12)
}

/// One cat paw: a heart-topped pad with four toes in an arc above it.
///
/// `size` is the pad's width; the toes extend beyond it. Drawn around the
/// context's current transform so a rotation can tilt the whole print.
func drawPaw(in context: CGContext, centre: CGPoint, size: Double, rotationDegrees: Double) {
    context.saveGState()
    context.translateBy(x: centre.x, y: centre.y)
    context.rotate(by: CGFloat(rotationDegrees * .pi / 180))

    // Pad. A rounded box reads as a bear's paw — the emoji's is a cat's:
    // two rounded lobes at the top with a shallow notch between them, and a
    // broad round base.
    let w = size
    let h = size * 0.80
    let pad = CGMutablePath()
    pad.move(to: CGPoint(x: -w * 0.48, y: h * 0.02))
    pad.addCurve(to: CGPoint(x: -w * 0.28, y: h * 0.50),           // up the left side
                 control1: CGPoint(x: -w * 0.54, y: h * 0.28),
                 control2: CGPoint(x: -w * 0.46, y: h * 0.50))
    pad.addCurve(to: CGPoint(x: -w * 0.02, y: h * 0.58),           // left lobe
                 control1: CGPoint(x: -w * 0.22, y: h * 0.66),
                 control2: CGPoint(x: -w * 0.10, y: h * 0.68))
    pad.addCurve(to: CGPoint(x: w * 0.02, y: h * 0.58),            // the notch
                 control1: CGPoint(x: -w * 0.01, y: h * 0.50),
                 control2: CGPoint(x: w * 0.01, y: h * 0.50))
    pad.addCurve(to: CGPoint(x: w * 0.28, y: h * 0.50),            // right lobe
                 control1: CGPoint(x: w * 0.10, y: h * 0.68),
                 control2: CGPoint(x: w * 0.22, y: h * 0.66))
    pad.addCurve(to: CGPoint(x: w * 0.48, y: h * 0.02),            // down the right side
                 control1: CGPoint(x: w * 0.46, y: h * 0.50),
                 control2: CGPoint(x: w * 0.54, y: h * 0.28))
    pad.addCurve(to: CGPoint(x: 0, y: -h * 0.56),                  // the broad base
                 control1: CGPoint(x: w * 0.48, y: -h * 0.38),
                 control2: CGPoint(x: w * 0.26, y: -h * 0.56))
    pad.addCurve(to: CGPoint(x: -w * 0.48, y: h * 0.02),
                 control1: CGPoint(x: -w * 0.26, y: -h * 0.56),
                 control2: CGPoint(x: -w * 0.48, y: -h * 0.38))
    pad.closeSubpath()
    context.addPath(pad)
    context.fillPath()

    // Four toes, the outer pair set lower so they read as an arc. Placed by
    // explicit offsets rather than by angle: an even angular spread crowds the
    // middle pair together and they merge into one blob at small sizes.
    let toeRadius = size * 0.140
    let toes: [(x: Double, y: Double)] = [
        (-0.430, 0.590), (-0.155, 0.800), (0.155, 0.800), (0.430, 0.590),
    ]
    for toe in toes {
        let toeWidth = toeRadius * (abs(toe.x) > 0.3 ? 1.70 : 1.58)
        let toeHeight = toeRadius * 2.05
        context.addEllipse(in: CGRect(
            x: CGFloat(toe.x) * w - toeWidth / 2,
            y: CGFloat(toe.y) * h - toeHeight / 2,
            width: toeWidth,
            height: toeHeight
        ))
        context.fillPath()
    }

    context.restoreGState()
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        fatalError("could not write \(url.path)")
    }
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

let output = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for variant in variants {
    let context = makeContext(pixels: variant.pixels)
    drawIcon(in: context)
    guard let image = context.makeImage() else {
        fatalError("could not render \(variant.name)")
    }
    write(image, to: output.appendingPathComponent("\(variant.name).png"))
    print("  \(variant.name).png  \(variant.pixels)x\(variant.pixels)")
}

print("wrote \(variants.count) images to \(output.path)")
