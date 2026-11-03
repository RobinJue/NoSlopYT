#!/usr/bin/env swift
//
// Draws the app icon with CoreGraphics and writes it as a 1024 x 1024 opaque PNG.
//
//   swift scripts/make-icon.swift                 # writes NoSlop/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
//   swift scripts/make-icon.swift /tmp/icon.png   # writes somewhere else
//
// The picture: a red gradient (#FF4E45 at the top left to #B3121A at the bottom right) filling the whole square,
// a white play triangle with rounded corners in the middle, and a small white four-point sparkle at the top right.
// No text. iOS rounds the corners itself, so the artwork is a full square, and the PNG has no alpha channel
// (the App Store rejects icons with transparency).
//
// Everything is drawn in CoreGraphics' own coordinates (origin at the bottom left, y up); the helper `top(_:)`
// turns a distance from the top edge into such a y.

import CoreGraphics
import Foundation
import ImageIO

let canvas: CGFloat = 1024

/// y for a point `distance` below the top edge.
func top(_ distance: CGFloat) -> CGFloat { canvas - distance }

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// A triangle pointing right whose corners are rounded with `radius`, centred so that its centre of mass sits at
/// `centroid` (that is where a right-pointing triangle looks centred).
func roundedPlayTriangle(side: CGFloat, radius: CGFloat, centroid: CGPoint) -> CGPath {
    let width = side * 3.0.squareRoot() / 2          // tip to flat edge
    let flatX = centroid.x - width / 3               // the centre of mass is a third of the way from the flat edge
    let tipX = flatX + width
    let a = CGPoint(x: flatX, y: centroid.y + side / 2)   // upper left
    let b = CGPoint(x: tipX, y: centroid.y)               // tip
    let c = CGPoint(x: flatX, y: centroid.y - side / 2)   // lower left

    let path = CGMutablePath()
    // Start in the middle of one edge, then round each corner with a tangent arc.
    path.move(to: CGPoint(x: (c.x + a.x) / 2, y: (c.y + a.y) / 2))
    path.addArc(tangent1End: a, tangent2End: b, radius: radius)
    path.addArc(tangent1End: b, tangent2End: c, radius: radius)
    path.addArc(tangent1End: c, tangent2End: a, radius: radius)
    path.closeSubpath()
    return path
}

/// A four-point star with concave sides: tips `reach` away from `center` straight up, right, down and left.
func sparkle(center: CGPoint, reach: CGFloat, waist: CGFloat) -> CGPath {
    let tips = [
        CGPoint(x: center.x, y: center.y + reach),
        CGPoint(x: center.x + reach, y: center.y),
        CGPoint(x: center.x, y: center.y - reach),
        CGPoint(x: center.x - reach, y: center.y),
    ]
    // The pull-in point of each side sits on the diagonal between two tips; the nearer to the centre, the sharper.
    let pulls = [
        CGPoint(x: center.x + waist, y: center.y + waist),
        CGPoint(x: center.x + waist, y: center.y - waist),
        CGPoint(x: center.x - waist, y: center.y - waist),
        CGPoint(x: center.x - waist, y: center.y + waist),
    ]
    let path = CGMutablePath()
    path.move(to: tips[0])
    for index in 0..<4 {
        path.addQuadCurve(to: tips[(index + 1) % 4], control: pulls[index])
    }
    path.closeSubpath()
    return path
}

func drawIcon() -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    // `noneSkipLast`: 8-bit RGB with no alpha channel, so the PNG is opaque.
    guard let context = CGContext(
        data: nil,
        width: Int(canvas),
        height: Int(canvas),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    // 1. The gradient, corner to corner.
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [rgb(0xFF4E45), rgb(0xB3121A)] as CFArray,
        locations: [0, 1]
    )
    guard let gradient else { return nil }
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: canvas),
        end: CGPoint(x: canvas, y: 0),
        options: []
    )

    // 2. A soft light from the top left, so the red is not flat.
    if let glow = CGGradient(
        colorsSpace: space,
        colors: [rgb(0xFFFFFF, alpha: 0.20), rgb(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: 250, y: top(220)),
            startRadius: 0,
            endCenter: CGPoint(x: 250, y: top(220)),
            endRadius: 760,
            options: []
        )
    }

    // 3. The play triangle, white, with a soft shadow under it.
    let triangle = roundedPlayTriangle(
        side: 470,
        radius: 62,
        centroid: CGPoint(x: canvas / 2 + 10, y: canvas / 2 - 8)
    )
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -18), blur: 46, color: rgb(0x5A0A10, alpha: 0.45))
    context.setFillColor(rgb(0xFFFFFF))
    context.addPath(triangle)
    context.fillPath()
    context.restoreGState()

    // 4. The sparkle at the top right.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: rgb(0x5A0A10, alpha: 0.30))
    context.setFillColor(rgb(0xFFFFFF))
    context.addPath(sparkle(center: CGPoint(x: 790, y: top(250)), reach: 96, waist: 17))
    context.fillPath()
    context.restoreGState()

    return context.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

// MARK: Run

let outputURL: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1])
    }
    // scripts/make-icon.swift -> the repository root is one level up.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    return root.appendingPathComponent("NoSlop/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
}()

guard let image = drawIcon() else {
    FileHandle.standardError.write(Data("make-icon: could not create the drawing context\n".utf8))
    exit(1)
}
try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
guard writePNG(image, to: outputURL) else {
    FileHandle.standardError.write(Data("make-icon: could not write \(outputURL.path)\n".utf8))
    exit(1)
}
print("Wrote \(outputURL.path) (\(image.width) x \(image.height))")
