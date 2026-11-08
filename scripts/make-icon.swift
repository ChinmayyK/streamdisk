// Turns Design/AppIcon-source.png (the icon tile on a white background) into
// Resources/AppIcon.icns: the tile cut out, placed on Apple's 1024 px icon grid, with a shadow.
// Usage: swift scripts/make-icon.swift
import AppKit
import CoreGraphics

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Design/AppIcon-source.png")
guard let src = NSImage(contentsOf: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("cannot read \(source.path)")
}

// Read pixels to find the tile. The tile is warm cream; the background is white and the shadow
// around the tile is neutral grey, so a warm pixel (red well above blue) marks the tile.
let w = src.width, h = src.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
let reader = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: rgb,
                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
reader.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
func isTile(_ x: Int, _ y: Int) -> Bool {  // y counts from the top
    let i = (y * w + x) * 4
    return Int(px[i]) - Int(px[i + 2]) > 14
}
let left = (0..<w).first { isTile($0, h / 2) }!
let right = (0..<w).reversed().first { isTile($0, h / 2) }!
let side = right - left + 1
// The top edge carries a white highlight, so measure from the bottom edge.
let bottom = (0..<h).reversed().first { isTile(w / 2, $0) }!
let top = bottom - side + 1
let inset = 4  // drop the antialiased edge against white
let tileRect = CGRect(x: left + inset, y: top + inset, width: side - 2 * inset, height: side - 2 * inset)
let tile = src.cropping(to: tileRect)!

func render(_ size: Int) -> Data {
    let s = CGFloat(size) / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Apple's macOS grid: an 824 px tile centred on a 1024 px canvas.
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = CGPath(roundedRect: rect, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 20 * s, color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor(srgbRed: 0.96, green: 0.94, blue: 0.9, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(tile, in: rect)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(1024).write(to: root.appendingPathComponent("Design/AppIcon-1024.png"))

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
