// Makes AppIcon.icns from icon-source.png (the icon artwork on a light background): finds the dark rounded square, crops it, masks the corners, and writes the macOS icon sizes.
// Run: swiftc make_icon.swift -o /tmp/make_icon && /tmp/make_icon icon-source.png AppIcon.icns
import Cocoa
let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]), let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("usage: make_icon in.png out.icns"); exit(1) }
let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
var x0 = w, x1 = 0, y0 = h, y1 = 0
for y in 0..<h { for x in 0..<w {
    let i = (y * w + x) * 4
    if Int(px[i]) + Int(px[i+1]) + Int(px[i+2]) < 3 * 95 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) }
} }
let side = min(x1 - x0, y1 - y0) - 2           // 1 px in from the rim, so no background shows at the edge
let crop = CGRect(x: x0 + 1, y: y0 + 1, width: side, height: side)
print("icon found at", crop)
guard let art = cg.cropping(to: crop) else { exit(1) }
let size = 1024, body: CGFloat = 824, pad = (CGFloat(size) - body) / 2
let out = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
out.interpolationQuality = .high
let rect = CGRect(x: pad, y: pad, width: body, height: body)
let path = CGPath(roundedRect: rect, cornerWidth: body * 0.2237, cornerHeight: body * 0.2237, transform: nil)
out.saveGState()
out.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
out.addPath(path); out.setFillColor(CGColor(gray: 0.1, alpha: 1)); out.fillPath()
out.restoreGState()
out.addPath(path); out.clip()
out.draw(art, in: rect)
let big = out.makeImage()!
let set = (args[2] as NSString).deletingPathExtension + ".iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(big, in: CGRect(x: 0, y: 0, width: px, height: px))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); p.arguments = ["-c", "icns", set, "-o", args[2]]; try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: set)
print("wrote", args[2])
