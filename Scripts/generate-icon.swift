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

    // Background: a warm-to-cool diagonal, so the pet reads as friendly rather
    // than as a system utility.
    context.saveGState()
    context.addPath(shape)
    context.clip()

    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [
            CGColor(red: 0.36, green: 0.44, blue: 0.96, alpha: 1),
            CGColor(red: 0.55, green: 0.36, blue: 0.92, alpha: 1),
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
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
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

    // Paw print, centred on the content square.
    let centre = CGPoint(x: canvas / 2, y: canvas / 2)
    let ink = CGColor(red: 1, green: 1, blue: 1, alpha: 0.97)

    context.setFillColor(ink)

    // Main pad: wider than tall, sitting below centre.
    let padWidth = contentSize * 0.44
    let padHeight = contentSize * 0.36
    let pad = CGPath(
        roundedRect: CGRect(
            x: centre.x - padWidth / 2,
            y: centre.y - padHeight * 0.92,
            width: padWidth,
            height: padHeight
        ),
        cornerWidth: padHeight * 0.46,
        cornerHeight: padHeight * 0.46,
        transform: nil
    )
    context.addPath(pad)
    context.fillPath()

    // Four toes above the pad, the outer pair set lower so they read as an arc.
    //
    // Placed by explicit offsets rather than by angle: an even angular spread
    // crowds the middle pair together and they merge into one blob, which
    // stops looking like a paw at small sizes.
    let toeRadius = contentSize * 0.060
    let toes: [(x: Double, y: Double)] = [
        (-0.200, 0.045), (-0.070, 0.115), (0.070, 0.115), (0.200, 0.045),
    ]
    for toe in toes {
        let x = centre.x + CGFloat(toe.x) * contentSize
        let y = centre.y + CGFloat(toe.y) * contentSize
        context.addEllipse(in: CGRect(
            x: x - toeRadius, y: y - toeRadius * 0.94,
            width: toeRadius * 2, height: toeRadius * 1.88
        ))
        context.fillPath()
    }
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
