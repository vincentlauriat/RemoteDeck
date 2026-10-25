#!/usr/bin/env swift
// Draws RemoteDeck's app icon (modeled on MarkdownViewer's Scripts/make-icon.swift): a macOS
// Big Sur+ rounded square (inset to the 824/1024 grid with a soft drop shadow) in deep blue, holding
// a remote screen: a display with a teal-to-blue desktop, a pointer on it and a short stand.
//
// Usage:
//   ./Scripts/make-icon.swift preview <output.png>   one 1024 x 1024 render, to look at
//   ./Scripts/make-icon.swift all [<appiconset dir>]  every macOS size + Contents.json
//                                                     (default: RemoteDeck/Assets.xcassets/AppIcon.appiconset)
//
// Each PNG is drawn into a bitmap of exactly the target pixel size (never lockFocus, whose size
// follows the screen's backing scale).
import AppKit

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func renderIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    // Every coordinate below is on the 1024 grid; y grows upward (Core Graphics).
    let scale = CGFloat(pixels) / 1024
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // 1. The rounded square: 824 x 824 centred, radius 185 (Apple's macOS icon grid), shadow below.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = roundedRect(tile, 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0, 0, 0, 0.30))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(16, 30, 66))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(40, 74, 150), color(14, 26, 60)]),
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft light from the top.
    ctx.drawRadialGradient(gradient([color(255, 255, 255, 0.16), color(255, 255, 255, 0)]),
                           startCenter: CGPoint(x: 512, y: 960), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 960), endRadius: 560, options: [])
    ctx.restoreGState()

    // 2. Stand: neck and foot, light aluminium.
    let metal = gradient([color(222, 230, 242), color(160, 174, 196)])
    let neck = CGMutablePath()
    neck.move(to: CGPoint(x: 462, y: 330))
    neck.addLine(to: CGPoint(x: 562, y: 330))
    neck.addLine(to: CGPoint(x: 580, y: 262))
    neck.addLine(to: CGPoint(x: 444, y: 262))
    neck.closeSubpath()
    // Neck and foot clipped one at a time: one clip of both paths would cancel their overlap.
    for part in [neck, roundedRect(CGRect(x: 372, y: 236, width: 280, height: 34), 17)] {
        ctx.saveGState()
        ctx.addPath(part)
        ctx.clip()
        ctx.drawLinearGradient(metal, start: CGPoint(x: 512, y: 330), end: CGPoint(x: 512, y: 236), options: [])
        ctx.restoreGState()
    }

    // 3. Display: bezel, then the remote desktop inside it.
    let bezel = CGRect(x: 214, y: 318, width: 596, height: 420)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: color(0, 0, 0, 0.35))
    ctx.addPath(roundedRect(bezel, 46))
    ctx.setFillColor(color(232, 238, 248))
    ctx.fillPath()
    ctx.restoreGState()

    let screen = bezel.insetBy(dx: 26, dy: 26)
    ctx.saveGState()
    ctx.addPath(roundedRect(screen, 24))
    ctx.clip()
    ctx.drawLinearGradient(gradient([color(54, 196, 214), color(46, 112, 232), color(58, 62, 196)]),
                           start: CGPoint(x: screen.minX, y: screen.maxY),
                           end: CGPoint(x: screen.maxX, y: screen.minY), options: [])
    // A remote window on the desktop, as on a Screen Sharing session.
    let window = CGRect(x: 282, y: 452, width: 250, height: 196)
    ctx.addPath(roundedRect(window, 18))
    ctx.setFillColor(color(255, 255, 255, 0.92))
    ctx.fillPath()
    ctx.addPath(roundedRect(CGRect(x: window.minX, y: window.maxY - 40, width: window.width, height: 40), 18))
    ctx.setFillColor(color(214, 224, 240))
    ctx.fillPath()
    for (i, dot) in [color(255, 95, 87), color(254, 188, 46), color(40, 200, 64)].enumerated() {
        ctx.setFillColor(dot)
        ctx.fillEllipse(in: CGRect(x: window.minX + 18 + CGFloat(i) * 26, y: window.maxY - 28, width: 16, height: 16))
    }
    ctx.setFillColor(color(178, 194, 220))
    for (row, width) in [(0, 180.0), (1, 140.0), (2, 160.0)] {
        ctx.fill(CGRect(x: window.minX + 22, y: window.maxY - 78 - CGFloat(row) * 34, width: width, height: 14))
    }
    ctx.restoreGState()

    // 4. The pointer, crossing the screen toward the remote window (read at 16 px as a white arrow).
    let pointer = CGMutablePath()
    let tip = CGPoint(x: 574, y: 600)
    pointer.move(to: tip)
    pointer.addLine(to: CGPoint(x: tip.x, y: tip.y - 196))
    pointer.addLine(to: CGPoint(x: tip.x + 46, y: tip.y - 150))
    pointer.addLine(to: CGPoint(x: tip.x + 80, y: tip.y - 224))
    pointer.addLine(to: CGPoint(x: tip.x + 112, y: tip.y - 210))
    pointer.addLine(to: CGPoint(x: tip.x + 80, y: tip.y - 138))
    pointer.addLine(to: CGPoint(x: tip.x + 142, y: tip.y - 138))
    pointer.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0, 0, 0, 0.35))
    ctx.addPath(pointer)
    ctx.setFillColor(color(255, 255, 255))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(pointer)
    ctx.setStrokeColor(color(20, 30, 60))
    ctx.setLineWidth(12)
    ctx.setLineJoin(.round)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// macOS AppIcon slots: (point size, scale) → file name and pixel size.
let slots: [(size: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                        (256, 1), (256, 2), (512, 1), (512, 2)]

let args = CommandLine.arguments
switch args.count >= 2 ? args[1] : "" {
case "preview":
    guard args.count >= 3 else {
        FileHandle.standardError.write(Data("usage: make-icon.swift preview <output.png>\n".utf8)); exit(64)
    }
    try renderIcon(pixels: 1024).write(to: URL(fileURLWithPath: args[2]))
    print("✓ \(args[2]) (1024 x 1024)")
case "all":
    let root = URL(fileURLWithPath: args[0]).deletingLastPathComponent().deletingLastPathComponent()
    let dir = args.count >= 3 ? URL(fileURLWithPath: args[2])
        : root.appendingPathComponent("RemoteDeck/Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for slot in slots {
        let pixels = slot.size * slot.scale
        let name = "icon_\(slot.size)x\(slot.size)\(slot.scale == 2 ? "@2x" : "").png"
        try renderIcon(pixels: pixels).write(to: dir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(slot.scale)x", "size": "\(slot.size)x\(slot.size)"])
        print("✓ \(name) (\(pixels) x \(pixels))")
    }
    let json: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        .write(to: dir.appendingPathComponent("Contents.json"))
    print("✓ Contents.json (\(images.count) images) in \(dir.path)")
default:
    FileHandle.standardError.write(Data("usage: make-icon.swift preview <output.png> | all [<appiconset dir>]\n".utf8))
    exit(64)
}
