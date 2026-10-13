// Renders PalMeet's app icon (1024×1024 master) and writes the asset catalog + .icns.
//   swift scripts/make-icon.swift
import AppKit
import CoreGraphics
import Foundation

let size: CGFloat = 1024
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render() -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // Body: Apple's icon grid (824 pt rounded square centred on 1024), with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x4338CA))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x5B4BF5), color(0x3B6FF0), color(0x0FB5C9)] as CFArray, locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
    // Soft light from the top.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 380, y: 880), startRadius: 0, endCenter: CGPoint(x: 380, y: 880), endRadius: 620, options: [])
    ctx.restoreGState()

    // Speech bubble with a tail at the bottom left.
    let bubble = CGRect(x: 232, y: 372, width: 560, height: 392)
    let bubblePath = CGMutablePath()
    bubblePath.addRoundedRect(in: bubble, cornerWidth: 132, cornerHeight: 132)
    bubblePath.move(to: CGPoint(x: 330, y: 400))
    bubblePath.addLine(to: CGPoint(x: 286, y: 270))
    bubblePath.addLine(to: CGPoint(x: 452, y: 384))
    bubblePath.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x1E1B4B, 0.35))
    ctx.addPath(bubblePath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Waveform bars inside the bubble, in the background's colours.
    let heights: [CGFloat] = [0.34, 0.68, 1.0, 0.62, 0.3]
    let barWidth: CGFloat = 46, gap: CGFloat = 30, maxHeight: CGFloat = 236
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    let centerY = bubble.midY
    ctx.saveGState()
    let bars = CGMutablePath()
    for (i, h) in heights.enumerated() {
        let x = bubble.midX - totalWidth / 2 + CGFloat(i) * (barWidth + gap)
        let height = maxHeight * h
        bars.addRoundedRect(in: CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height), cornerWidth: barWidth / 2, cornerHeight: barWidth / 2)
    }
    ctx.addPath(bars)
    ctx.clip()
    let barGradient = CGGradient(colorsSpace: space, colors: [color(0x5B4BF5), color(0x0FB5C9)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(barGradient, start: CGPoint(x: bubble.minX, y: bubble.maxY), end: CGPoint(x: bubble.maxX, y: bubble.minY), options: [])
    ctx.restoreGState()

    // AI sparkle at the bubble's top-right corner.
    func sparkle(center: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let inner = radius * 0.22
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4 + .pi / 2
            let r = i.isMultiple(of: 2) ? radius : inner
            let point = CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r)
            i == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 22, color: color(0xFFFFFF, 0.8))
    ctx.addPath(sparkle(center: CGPoint(x: 788, y: 778), radius: 92))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.addPath(sparkle(center: CGPoint(x: 870, y: 664), radius: 40))
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, pixels: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let master = render()
let assets = root.appending(path: "Resources/Assets.xcassets")
let appIcon = assets.appending(path: "AppIcon.appiconset")
let iconset = root.appending(path: "build/AppIcon.iconset")
for dir in [appIcon, iconset] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
try #"{"info":{"author":"xcode","version":1}}"#.write(to: assets.appending(path: "Contents.json"), atomically: true, encoding: .utf8)

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try writePNG(master, pixels: points * scale, to: appIcon.appending(path: name))
        try writePNG(master, pixels: points * scale, to: iconset.appending(path: name))
        images.append(#"{"filename":"\#(name)","idiom":"mac","scale":"\#(scale)x","size":"\#(points)x\#(points)"}"#)
    }
}
try #"{"images":[\#(images.joined(separator: ","))],"info":{"author":"xcode","version":1}}"#
    .write(to: appIcon.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
try writePNG(master, pixels: 1024, to: root.appending(path: "Resources/AppIcon-1024.png"))
print("Wrote \(appIcon.path) and \(iconset.path)")
