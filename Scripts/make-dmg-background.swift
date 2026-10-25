#!/usr/bin/env swift
// Draws the DMG installer background (modeled on MarkdownViewer's Scripts/make-dmg-background.swift):
// a light window-sized canvas with an arrow from the app's slot to the /Applications alias, and a
// one-line hint under them. Finder paints the icons and their labels on top.
//
// Geometry, the same as Scripts/dmg-settings.py (dmgbuild): window 540 x 380, icon size 128,
// RemoteDeck.app centred at (140, 200) and Applications at (400, 200), Finder coordinates (origin
// top left). Exactly 540 x 380 pixels: drawn into an NSBitmapImageRep, never lockFocus (whose pixel
// size follows the screen's backing scale, 1080 x 760 on a Retina display).
//
// Usage: ./Scripts/make-dmg-background.swift <output.png>
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-dmg-background.swift <output.png>\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

let width = 540, height = 380
let W = CGFloat(width), H = CGFloat(height)
/// Finder y (top-left origin) → Core Graphics y (bottom-left origin).
func y(_ finderY: CGFloat) -> CGFloat { H - finderY }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
let ctx = context.cgContext
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Background: near-white with a faint blue glow at the top (the icon's palette, kept light so the
// black Finder labels stay readable).
ctx.setFillColor(color(250, 251, 254))
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
let glow = CGGradient(colorsSpace: srgb, colors: [color(46, 112, 232, 0.10), color(46, 112, 232, 0)] as CFArray,
                      locations: nil)!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: H + 40), startRadius: 0,
                       endCenter: CGPoint(x: W / 2, y: H + 40), endRadius: 360, options: [])

// Arrow between the two icon slots (icons span x 76…204 and 336…464 at size 128).
let accent = color(46, 112, 232)
let arrowY = y(200)
let startX: CGFloat = 222, endX: CGFloat = 318, head: CGFloat = 18
ctx.setStrokeColor(accent)
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: startX, y: arrowY))
ctx.addLine(to: CGPoint(x: endX - head * 0.7, y: arrowY))
ctx.strokePath()
ctx.setFillColor(accent)
ctx.move(to: CGPoint(x: endX, y: arrowY))
ctx.addLine(to: CGPoint(x: endX - head, y: arrowY + head * 0.62))
ctx.addLine(to: CGPoint(x: endX - head, y: arrowY - head * 0.62))
ctx.closePath()
ctx.fillPath()

// Hint, below the icon labels.
let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let hint = NSAttributedString(string: "Drag RemoteDeck to Applications to install it", attributes: [
    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.36, green: 0.40, blue: 0.47, alpha: 1),
    .paragraphStyle: paragraph,
])
hint.draw(in: CGRect(x: 0, y: y(326), width: W, height: 20))

NSGraphicsContext.restoreGraphicsState()
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("failed to encode PNG\n".utf8))
    exit(1)
}
try png.write(to: output)
print("✓ wrote \(output.path) (\(width) x \(height))")
