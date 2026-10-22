// Renders the app icon (1024×1024 PNG). Usage: swift scripts/make-icon.swift <out.png>
// A round sieve seen from above: a fine mesh inside a metal ring, with violet grains falling through below.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: an 824 pt rounded square centred on the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.32))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x15131F))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
// Ink tile with a violet glow rising from below, where the grains fall.
let base = CGGradient(colorsSpace: space, colors: [rgb(0x221E33), rgb(0x0E0D14)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(base, start: CGPoint(x: tile.midX, y: tile.maxY), end: CGPoint(x: tile.midX, y: tile.minY), options: [])
let glow = CGGradient(colorsSpace: space, colors: [rgb(0x6F5CFF, 0.55), rgb(0x6F5CFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: tile.midX, y: tile.minY + 120), startRadius: 0,
                       endCenter: CGPoint(x: tile.midX, y: tile.minY + 120), endRadius: 420, options: [])
ctx.setStrokeColor(rgb(0xFFFFFF, 0.12))
ctx.setLineWidth(6)
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
ctx.strokePath()

// The sieve: an ellipse (seen at an angle) filled with a fine mesh.
let center = CGPoint(x: tile.midX, y: tile.midY + 110)
let rim = CGRect(x: center.x - 290, y: center.y - 150, width: 580, height: 300)
ctx.saveGState()
ctx.addEllipse(in: rim.insetBy(dx: 18, dy: 12))
ctx.clip()
let meshFill = CGGradient(colorsSpace: space, colors: [rgb(0x2C2840), rgb(0x1A1726)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(meshFill, start: CGPoint(x: rim.midX, y: rim.maxY), end: CGPoint(x: rim.midX, y: rim.minY), options: [])
ctx.setStrokeColor(rgb(0xC9C4E6, 0.42))
ctx.setLineWidth(4)
let step: CGFloat = 34
var x = rim.minX
while x <= rim.maxX {
    // Mesh lines run diagonally so the grid reads as woven wire, not a spreadsheet.
    ctx.move(to: CGPoint(x: x - 160, y: rim.minY)); ctx.addLine(to: CGPoint(x: x + 160, y: rim.maxY))
    ctx.move(to: CGPoint(x: x + 160, y: rim.minY)); ctx.addLine(to: CGPoint(x: x - 160, y: rim.maxY))
    x += step
}
ctx.strokePath()
ctx.restoreGState()

// Metal rim: light top edge, darker bottom edge.
let rimGradient = CGGradient(colorsSpace: space, colors: [rgb(0xF4F2FF), rgb(0x8E89A8)] as CFArray, locations: [0, 1])!
ctx.saveGState()
let ring = CGMutablePath()
ring.addEllipse(in: rim)
ring.addEllipse(in: rim.insetBy(dx: 22, dy: 15))
ctx.addPath(ring)
ctx.clip(using: .evenOdd)
ctx.drawLinearGradient(rimGradient, start: CGPoint(x: rim.midX, y: rim.maxY), end: CGPoint(x: rim.midX, y: rim.minY), options: [])
ctx.restoreGState()

// Grains falling through: few, precise, brightest at the bottom.
let grains: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (-70, -250, 22, 0.95), (40, -300, 26, 1.0), (-10, -390, 30, 1.0), (95, -420, 18, 0.8), (-120, -360, 16, 0.7),
]
for (dx, dy, r, a) in grains {
    let p = CGPoint(x: center.x + dx, y: center.y + dy)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: r * 1.6, color: rgb(0x8F84FF, 0.9 * a))
    ctx.setFillColor(rgb(0x9D93FF, a))
    ctx.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
    ctx.restoreGState()
}
ctx.restoreGState()

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
