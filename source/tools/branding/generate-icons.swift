// Run from repository root: swift tools/branding/generate-icons.swift
// Android launchers display the central 72 of the adaptive icon's 108 units.
// Scale the foreground by 108/72 for fixed canvases: radii 39 and 27.
import AppKit
import Foundation

func write(_ value: Any, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}
func render(_ size: Int, mac: Bool = false) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 108, y: CGFloat(size) / 108)
    if mac {
        // macOS icons include their own rounded tile and transparent margins.
        context.translateBy(x: 10, y: 10)
        context.scaleBy(x: 88.0 / 108, y: 88.0 / 108)
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 108, height: 108), cornerWidth: 24, cornerHeight: 24, transform: nil))
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
    } else {
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 108, height: 108))
    }
    context.setFillColor(NSColor.white.cgColor)
    context.addEllipse(in: CGRect(x: 15, y: 15, width: 78, height: 78))
    context.addEllipse(in: CGRect(x: 27, y: 27, width: 54, height: 54))
    context.drawPath(using: .eoFill)
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    // iOS requires an opaque icon, including the encoded PNG color type.
    if !mac {
        let opaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<size { for x in 0..<size { opaque.setColor(bitmap.colorAt(x: x, y: y)!, atX: x, y: y) } }
        return opaque.representation(using: .png, properties: [:])!
    }
    return bitmap.representation(using: .png, properties: [:])!
}
let info: [String: Any] = ["author": "xcode", "version": 1]
for platform in ["LimLink-iOS", "LimLink-mac"] {
    let base = "apple/\(platform)/App/Assets.xcassets"
    try write(["info": info], to: "\(base)/Contents.json")
    let app = "\(base)/AppIcon.appiconset"
    try FileManager.default.createDirectory(atPath: app, withIntermediateDirectories: true)
    var images = [[String: String]]()
    if platform == "LimLink-iOS" {
        try render(1024).write(to: URL(fileURLWithPath: "\(app)/AppIcon.png"))
        images.append(["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"])
    } else {
        for size in [16, 32, 128, 256, 512] { for scale in [1, 2] {
            let name = "icon_\(size)x\(size)@\(scale)x.png"
            try render(size * scale, mac: true).write(to: URL(fileURLWithPath: "\(app)/\(name)"))
            images.append(["filename": name, "idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x"])
        } }
    }
    try write(["info": info, "images": images], to: "\(app)/Contents.json")
}
// ICO supports PNG frames; little-endian directory plus multi-resolution PNGs.
var ico = Data()
func u16(_ value: Int) { var v = UInt16(value).littleEndian; withUnsafeBytes(of: &v) { ico.append(contentsOf: $0) } }
func u32(_ value: Int) { var v = UInt32(value).littleEndian; withUnsafeBytes(of: &v) { ico.append(contentsOf: $0) } }
let sizes = [16, 24, 32, 48, 64, 128, 256]
let frames = sizes.map { render($0) }
u16(0); u16(1); u16(sizes.count)
var offset = 6 + 16 * sizes.count
for (index, size) in sizes.enumerated() {
    ico.append(contentsOf: [UInt8(size % 256), UInt8(size % 256), 0, 0])
    u16(1); u16(24); u32(frames[index].count); u32(offset)
    offset += frames[index].count
}
for frame in frames { ico.append(frame) }
try ico.write(to: URL(fileURLWithPath: "windows/src/LimLink.Desktop/AppIcon.ico"))
print("Generated iOS/iPadOS, macOS and Windows icons from Android ring geometry.")
