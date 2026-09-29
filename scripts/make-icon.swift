#!/usr/bin/env swift
// Renders Tandem's app icon at every macOS size into the asset catalog.
// Usage: swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit
import CoreGraphics
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "App/Resources/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Squircle plate (Apple grid: 824pt body inside 1024 canvas).
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(platePath)
    ctx.setFillColor(color(0x0E0F16))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x221A45), color(0x0C0E17)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft glow behind the screens.
    let glow = CGGradient(colorsSpace: space, colors: [color(0x7C5CFF, 0.55), color(0x7C5CFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 560, y: 520), startRadius: 0, endCenter: CGPoint(x: 560, y: 520), endRadius: 420, options: [])
    // Top sheen.
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    ctx.restoreGState()

    let accent = CGGradient(colorsSpace: space, colors: [color(0x8B6BFF), color(0x33CFF2)] as CFArray, locations: [0, 1])!

    // Back screen (outlined) — the Mac being shared.
    let back = CGRect(x: 232, y: 420, width: 330, height: 226)
    let backPath = CGPath(roundedRect: back, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.saveGState()
    ctx.addPath(backPath)
    ctx.setLineWidth(22)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    ctx.drawLinearGradient(accent, start: CGPoint(x: back.minX, y: back.maxY), end: CGPoint(x: back.maxX, y: back.minY), options: [])
    ctx.restoreGState()
    // Its base.
    let backBase = CGPath(roundedRect: CGRect(x: 206, y: 382, width: 382, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil)
    ctx.addPath(backBase)
    ctx.setFillColor(color(0x6D7BFF, 0.85))
    ctx.fillPath()

    // Front screen (filled) — the Studio.
    let front = CGRect(x: 452, y: 330, width: 350, height: 240)
    let frontPath = CGPath(roundedRect: front, cornerWidth: 36, cornerHeight: 36, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.45))
    ctx.addPath(frontPath)
    ctx.setFillColor(color(0x33CFF2))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(frontPath)
    ctx.clip()
    ctx.drawLinearGradient(accent, start: CGPoint(x: front.minX, y: front.maxY), end: CGPoint(x: front.maxX, y: front.minY), options: [])
    // Glass highlight on the front screen.
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: front.maxY), end: CGPoint(x: 0, y: front.midY), options: [])
    ctx.restoreGState()
    let frontBase = CGPath(roundedRect: CGRect(x: 424, y: 290, width: 406, height: 24), cornerWidth: 12, cornerHeight: 12, transform: nil)
    ctx.addPath(frontBase)
    ctx.setFillColor(color(0x9FE9FA))
    ctx.fillPath()

    // Chat lines on the front screen.
    ctx.setFillColor(color(0xFFFFFF, 0.92))
    for (index, width) in [196.0, 150.0, 110.0].enumerated() {
        let y = front.maxY - 72 - CGFloat(index) * 44
        let line = CGPath(roundedRect: CGRect(x: front.minX + 44, y: y, width: width, height: 20), cornerWidth: 10, cornerHeight: 10, transform: nil)
        ctx.addPath(line)
        ctx.fillPath()
    }

    // Spark — the AI.
    func spark(center: CGPoint, radius: CGFloat, alpha: CGFloat) {
        let path = CGMutablePath()
        let inner = radius * 0.22
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4 + .pi / 2
            let r = i % 2 == 0 ? radius : inner
            let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(color(0xFFFFFF, alpha))
        ctx.fillPath()
    }
    spark(center: CGPoint(x: 748, y: 668), radius: 74, alpha: 1)
    spark(center: CGPoint(x: 668, y: 740), radius: 30, alpha: 0.8)

    return ctx.makeImage()!
}

let entries: [(size: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
var images: [[String: String]] = []
for entry in entries {
    let pixels = entry.size * entry.scale
    let name = "icon_\(entry.size)x\(entry.size)\(entry.scale == 2 ? "@2x" : "").png"
    let rep = NSBitmapImageRep(cgImage: render(size: pixels))
    try rep.representation(using: .png, properties: [:])!.write(to: outputDirectory.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(entry.size)x\(entry.size)", "scale": "\(entry.scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(entries.count) icon images to \(outputDirectory.path)")
