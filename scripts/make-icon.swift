#!/usr/bin/swift
// Draws the app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns] [preview.png]

import AppKit
import CoreGraphics

/// Draws the icon on a 1024-point canvas with the origin in the lower left corner.
func drawIcon(in ctx: CGContext) {
    let canvas: CGFloat = 1024
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    let space = CGColorSpaceCreateDeviceRGB()

    // Soft shadow under the plate.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.addPath(platePath)
    ctx.setFillColor(CGColor(red: 0.10, green: 0.37, blue: 0.84, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Blue plate, lighter at the top.
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let colors = [
        CGColor(red: 0.33, green: 0.72, blue: 1.00, alpha: 1),
        CGColor(red: 0.09, green: 0.36, blue: 0.84, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
    ctx.restoreGState()

    // Two white arrows chasing each other around a circle.
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let radius: CGFloat = 205
    let lineWidth: CGFloat = 72
    let headLength: CGFloat = 135
    let headHalfWidth: CGFloat = 108
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.butt)

    func point(_ degrees: CGFloat, _ distance: CGFloat) -> CGPoint {
        let a = degrees * .pi / 180
        return CGPoint(x: center.x + cos(a) * distance, y: center.y + sin(a) * distance)
    }

    for (start, end) in [(CGFloat(25), CGFloat(150)), (CGFloat(205), CGFloat(330))] {
        // The shaft, counterclockwise from `start` to just inside the head so no seam shows.
        ctx.addArc(center: center, radius: radius, startAngle: start * .pi / 180,
                   endAngle: (end + 3) * .pi / 180, clockwise: false)
        ctx.strokePath()

        // A rounded tail.
        let tail = point(start, radius)
        ctx.fillEllipse(in: CGRect(x: tail.x - lineWidth / 2, y: tail.y - lineWidth / 2,
                                   width: lineWidth, height: lineWidth))

        // The head, pointing along the circle.
        let a = end * .pi / 180
        let base = point(end, radius)
        let tangent = CGPoint(x: -sin(a), y: cos(a))
        ctx.move(to: CGPoint(x: base.x + tangent.x * headLength, y: base.y + tangent.y * headLength))
        ctx.addLine(to: point(end, radius + headHalfWidth))
        ctx.addLine(to: point(end, radius - headHalfWidth))
        ctx.closePath()
        ctx.fillPath()
    }
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: ctx)
    return rep.representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
let output = arguments.count > 1 ? arguments[1] : "Resources/AppIcon.icns"
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for (name, pixels) in [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
] {
    try png(pixels: pixels).write(to: iconset.appendingPathComponent("\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", output, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(output)")

if arguments.count > 2 {
    try png(pixels: 512).write(to: URL(fileURLWithPath: arguments[2]))
    print("Wrote \(arguments[2])")
}
