#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns from the "1a" logo of the Claude Design
// project "ChromaDB Manager logo".
//
// The artwork is drawn with Core Graphics instead of being pasted in as a
// bitmap, so every size in the iconset is rendered natively (crisp at 16pt)
// and the icon can be regenerated after a design change:
//
//     swift Scripts/generate-app-icon.swift
//
// Source design (variant 1a), 280×280 reference box:
//   - squircle, radius 63 (= 0.225 × side)
//   - background: linear-gradient(155deg, #71747EEB, #000000EB, #313131EB)
//   - radial highlight at 30%/20%, white 0.28, fading out at 55%
//   - inset 0 1px 1px white 0.35, drop shadow 0 20px 40px -12px violet 0.45
//   - open ring: r 66, stroke 24, round caps, 290/415 dash, rotated 38°
//
// The design's colours carry an EB (92%) alpha over the canvas background
// #e9e9ec; they are pre-composited here, because an app icon has no canvas
// behind it.

import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design constants (fractions of the icon body, from the 280pt box)

enum Design {
    /// Apple's macOS icon grid: a 824×824 body centred in a 1024 canvas.
    static let bodyRatio: CGFloat = 824.0 / 1024.0
    static let cornerRatio: CGFloat = 63.0 / 280.0

    static let gradientAngle: CGFloat = 155.0
    static let gradientColors: [NSColor] = [
        NSColor(srgbRed: 0x7A / 255, green: 0x7D / 255, blue: 0x87 / 255, alpha: 1),
        NSColor(srgbRed: 0x12 / 255, green: 0x12 / 255, blue: 0x13 / 255, alpha: 1),
        NSColor(srgbRed: 0x3F / 255, green: 0x3F / 255, blue: 0x40 / 255, alpha: 1),
    ]

    static let highlightCenter = CGPoint(x: 0.30, y: 0.20)   // from the body's top-left
    static let highlightRadius: CGFloat = 0.585              // 55% of the farthest-corner radius
    static let highlightAlpha: CGFloat = 0.28

    // The design's drop shadow (0 20px 40px -12px, violet 0.45) reads well on
    // the canvas, but as an app icon it becomes a halo: it bleeds past the
    // 824pt body into the Dock's spacing, and such a wide, low-alpha violet
    // wash visibly bands in 8-bit over dark wallpapers. Kept violet, tightened
    // to the proportions macOS icons actually use.
    static let shadowOffset: CGFloat = 0.030
    static let shadowBlur: CGFloat = 0.075
    static let shadowSpread: CGFloat = 0.040
    static let shadowColor = NSColor(srgbRed: 64 / 255, green: 62 / 255, blue: 142 / 255, alpha: 0.42)

    static let innerHighlightOffset: CGFloat = 1.0 / 280.0
    static let innerHighlightAlpha: CGFloat = 0.35

    static let ringRadius: CGFloat = 66.0 / 280.0
    static let ringWidth: CGFloat = 24.0 / 280.0
    static let ringAlpha: CGFloat = 0.95
    /// Dash 290 of a 414.69 circumference → 251.7° drawn, gap on the right.
    static let ringStartDegrees: CGFloat = 38.0
    static let ringSweepDegrees: CGFloat = 290.0 / (2 * .pi * 66.0) * 360.0
}

// MARK: - Geometry helpers

/// Apple's continuous ("squircle") corner, taken straight from SwiftUI so the
/// shape matches other macOS icons rather than a plain rounded rectangle.
func squirclePath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        .path(in: rect)
        .cgPath
}

/// Endpoints of a CSS `linear-gradient(<angle>deg, …)` line for a square box,
/// expressed in a y-up (Core Graphics) coordinate system.
func gradientEndpoints(angleDegrees: CGFloat, in rect: CGRect) -> (CGPoint, CGPoint) {
    let radians = angleDegrees * .pi / 180
    // CSS: 0deg points up, angles grow clockwise. In y-up space that is:
    let direction = CGVector(dx: sin(radians), dy: cos(radians))
    let length = abs(rect.width * direction.dx) + abs(rect.height * direction.dy)
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let half = length / 2
    let start = CGPoint(x: center.x - direction.dx * half, y: center.y + direction.dy * half)
    let end = CGPoint(x: center.x + direction.dx * half, y: center.y - direction.dy * half)
    return (start, end)
}

// MARK: - Drawing

func renderIcon(pixels: Int) -> CGImage {
    let size = CGFloat(pixels)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("cannot create a \(pixels)×\(pixels) bitmap context")
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let side = (size * Design.bodyRatio).rounded()
    let body = CGRect(
        x: ((size - side) / 2).rounded(),
        y: ((size - side) / 2).rounded(),
        width: side,
        height: side
    )
    let corner = side * Design.cornerRatio
    let path = squirclePath(in: body, cornerRadius: corner)

    // 1. Drop shadow. CSS spread (-12px) has no Core Graphics equivalent, so
    //    the shadow is cast by a shrunken copy of the shape.
    context.saveGState()
    let spread = side * Design.shadowSpread
    let shrunk = body.insetBy(dx: spread, dy: spread)
    context.setShadow(
        offset: CGSize(width: 0, height: -side * Design.shadowOffset),
        blur: side * Design.shadowBlur,
        color: Design.shadowColor.cgColor
    )
    context.addPath(squirclePath(in: shrunk, cornerRadius: corner - spread))
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    // 2. Body gradient.
    context.saveGState()
    context.addPath(path)
    context.clip()

    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: Design.gradientColors.map { $0.cgColor } as CFArray,
        locations: [0.0, 0.5, 1.0]
    )!
    let (start, end) = gradientEndpoints(angleDegrees: Design.gradientAngle, in: body)
    context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    // 3. Radial highlight from the top-left.
    let highlightCenter = CGPoint(
        x: body.minX + side * Design.highlightCenter.x,
        y: body.maxY - side * Design.highlightCenter.y
    )
    let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            NSColor(white: 1, alpha: Design.highlightAlpha).cgColor,
            NSColor(white: 1, alpha: 0).cgColor,
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawRadialGradient(
        highlight,
        startCenter: highlightCenter,
        startRadius: 0,
        endCenter: highlightCenter,
        endRadius: side * Design.highlightRadius,
        options: []
    )

    // 4. Inner top highlight (CSS `inset 0 1px 1px`): a shadow cast into the
    //    shape by the surrounding area, clipped to the body.
    let unit = max(side * Design.innerHighlightOffset, 0.5)
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -unit),
        blur: unit,
        color: NSColor(white: 1, alpha: Design.innerHighlightAlpha).cgColor
    )
    let inverse = CGMutablePath()
    inverse.addRect(CGRect(x: -side, y: -side, width: size + side * 2, height: size + side * 2))
    inverse.addPath(path)
    context.addPath(inverse)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath(using: .evenOdd)
    context.restoreGState()

    context.restoreGState()

    // 5. The open ring — a "C" with its gap on the right.
    let ringCenter = CGPoint(x: body.midX, y: body.midY)
    let radius = side * Design.ringRadius
    context.saveGState()
    context.setStrokeColor(NSColor(white: 1, alpha: Design.ringAlpha).cgColor)
    context.setLineWidth(side * Design.ringWidth)
    context.setLineCap(.round)
    // The design rotates a clockwise SVG arc by 38°; in y-up space that is a
    // clockwise sweep starting at -38°.
    let startAngle = -Design.ringStartDegrees * .pi / 180
    let endAngle = startAngle - Design.ringSweepDegrees * .pi / 180
    context.addArc(
        center: ringCenter,
        radius: radius,
        startAngle: startAngle,
        endAngle: endAngle,
        clockwise: true
    )
    context.strokePath()
    context.restoreGState()

    guard let image = context.makeImage() else { fatalError("cannot snapshot the icon context") }
    return image
}

// MARK: - Output

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot finalize \(url.path)") }
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let root = scriptURL.path.hasSuffix("Scripts")
    ? scriptURL.deletingLastPathComponent()
    : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

let resources = root.appendingPathComponent("Resources")
let docs = root.appendingPathComponent("docs")
let iconset = resources.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

// The ten entries `iconutil` expects for a macOS app icon.
let variants: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for variant in variants {
    let pixels = variant.base * variant.scale
    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let name = "icon_\(variant.base)x\(variant.base)\(suffix).png"
    write(renderIcon(pixels: pixels), to: iconset.appendingPathComponent(name))
    print("  \(name) — \(pixels)×\(pixels)")
}

// A standalone 1024 PNG for the README and the design project.
write(renderIcon(pixels: 1024), to: docs.appendingPathComponent("app-icon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = [
    "--convert", "icns",
    "--output", resources.appendingPathComponent("AppIcon.icns").path,
    iconset.path,
]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(iconutil.terminationStatus)")
}

print("\nWrote \(resources.appendingPathComponent("AppIcon.icns").path)")
print("Wrote \(docs.appendingPathComponent("app-icon-1024.png").path)")
