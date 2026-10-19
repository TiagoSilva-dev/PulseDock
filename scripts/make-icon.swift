#!/usr/bin/env swift
// Draws PulseDock's original app icon with CoreGraphics and packs it with iconutil.
//   swift scripts/make-icon.swift <output-directory>
import AppKit
import CoreGraphics
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("PulseDock-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func draw(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: s / 1024, y: s / 1024)

    // Body: macOS icon grid (824 pt squircle centred in 1024).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
    context.addPath(path)
    context.setFillColor(color(0x0E1022))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(path)
    context.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x23285A), color(0x111430), color(0x07080F)] as CFArray, locations: [0, 0.55, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Ambient light behind the pulse.
    let glow = CGGradient(colorsSpace: space, colors: [color(0x5B7CFF, 0.55), color(0x7B5CFF, 0.18), color(0x7B5CFF, 0)] as CFArray, locations: [0, 0.45, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0, endCenter: CGPoint(x: 512, y: 560), endRadius: 420, options: [])

    // Glass dock bar.
    let bar = CGRect(x: 214, y: 214, width: 596, height: 132)
    let barPath = CGPath(roundedRect: bar, cornerWidth: 54, cornerHeight: 54, transform: nil)
    context.addPath(barPath)
    context.setFillColor(color(0xFFFFFF, 0.13))
    context.fillPath()
    context.saveGState()
    context.addPath(barPath)
    context.clip()
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sheen, start: CGPoint(x: 512, y: bar.maxY), end: CGPoint(x: 512, y: bar.midY), options: [])
    context.restoreGState()
    context.addPath(barPath)
    context.setStrokeColor(color(0xFFFFFF, 0.32))
    context.setLineWidth(3)
    context.strokePath()

    // Three app tiles in the bar; the last one carries the live state.
    let tiles: [(CGFloat, UInt32, CGFloat)] = [(286, 0xFFFFFF, 0.55), (418, 0xFFFFFF, 0.55), (550, 0xFFFFFF, 0.55)]
    for (x, hex, alpha) in tiles {
        let tile = CGPath(roundedRect: CGRect(x: x, y: 240, width: 80, height: 80), cornerWidth: 22, cornerHeight: 22, transform: nil)
        context.addPath(tile)
        context.setFillColor(color(hex, alpha * 0.42))
        context.fillPath()
    }
    let island = CGPath(roundedRect: CGRect(x: 664, y: 254, width: 110, height: 52), cornerWidth: 26, cornerHeight: 26, transform: nil)
    context.addPath(island)
    context.setFillColor(color(0x67E8F9, 0.95))
    context.fillPath()

    // Pulse line rising from the dock.
    let pulse = CGMutablePath()
    pulse.move(to: CGPoint(x: 214, y: 560))
    pulse.addLine(to: CGPoint(x: 380, y: 560))
    pulse.addLine(to: CGPoint(x: 432, y: 470))
    pulse.addLine(to: CGPoint(x: 500, y: 712))
    pulse.addLine(to: CGPoint(x: 566, y: 452))
    pulse.addLine(to: CGPoint(x: 612, y: 600))
    pulse.addLine(to: CGPoint(x: 650, y: 560))
    pulse.addLine(to: CGPoint(x: 810, y: 560))
    context.saveGState()
    context.setShadow(offset: .zero, blur: 34, color: color(0x6EE7FF, 0.85))
    context.addPath(pulse)
    context.setLineWidth(30)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    let stroke = CGGradient(colorsSpace: space, colors: [color(0x67E8F9), color(0x818CF8), color(0xC084FC)] as CFArray, locations: [0, 0.5, 1])!
    context.drawLinearGradient(stroke, start: CGPoint(x: 214, y: 560), end: CGPoint(x: 810, y: 560), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
    context.restoreGState()

    // Hairline edge.
    context.addPath(path)
    context.setStrokeColor(color(0xFFFFFF, 0.14))
    context.setLineWidth(4)
    context.strokePath()
    return context.makeImage()!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in sizes {
    let rep = NSBitmapImageRep(cgImage: draw(size: size))
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("\(name).png"))
}
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", outputDirectory.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
// Also keep a 1024 px PNG for documentation.
let rep = NSBitmapImageRep(cgImage: draw(size: 1024))
try rep.representation(using: .png, properties: [:])!.write(to: outputDirectory.appendingPathComponent("AppIcon-1024.png"))
try? FileManager.default.removeItem(at: iconset)
print(outputDirectory.appendingPathComponent("AppIcon.icns").path)
