#!/usr/bin/env swift
import AppKit

// Run from the repository root: swift Scripts/generate-brand-assets.swift
// The SVG is the single source for website, app, and system icons.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let files = FileManager.default
guard let logo = NSImage(contentsOf: root.appendingPathComponent("website/assets/kodi-logo.svg")) else {
    fatalError("Run from the repository root; cannot load website/assets/kodi-logo.svg")
}

func write(_ data: Data, to path: String) throws {
    let url = root.appendingPathComponent(path)
    try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
}

func json(_ object: [String: Any], to path: String) throws {
    try write(JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), to: path)
}

func png(width: Int, height: Int? = nil, inset: CGFloat = 0, background: NSColor? = nil) -> Data {
    let height = height ?? width
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    if let background {
        background.setFill()
        bounds.fill()
    }
    let side = CGFloat(min(width, height)) * (1 - 2 * inset)
    logo.draw(in: NSRect(x: (CGFloat(width) - side) / 2, y: (CGFloat(height) - side) / 2,
                        width: side, height: side))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let catalog = "App/Assets.xcassets"
let info: [String: Any] = ["author": "xcode", "version": 1]
try json(["info": info], to: "\(catalog)/Contents.json")
var icons: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "icon_\(size)x\(size)@\(scale)x.png"
        // macOS icons have transparent breathing room around the rounded tile.
        try write(png(width: size * scale, inset: 0.1), to: "\(catalog)/AppIcon.appiconset/\(filename)")
        icons.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
try json(["images": icons, "info": info], to: "\(catalog)/AppIcon.appiconset/Contents.json")

var images: [[String: String]] = []
for scale in [1, 2] {
    let filename = "kodi-logo@\(scale)x.png"
    try write(png(width: 128 * scale), to: "\(catalog)/KodiLogo.imageset/\(filename)")
    images.append(["idiom": "mac", "scale": "\(scale)x", "filename": filename])
}
try json(["images": images, "info": info, "properties": ["template-rendering-intent": "original"]],
         to: "\(catalog)/KodiLogo.imageset/Contents.json")

try write(png(width: 512), to: "website/assets/kodi-logo.png")
try write(png(width: 32), to: "website/assets/favicon-32.png")
let green = NSColor(srgbRed: 36.0 / 255, green: 87.0 / 255, blue: 68.0 / 255, alpha: 1)
try write(png(width: 180, background: green), to: "website/assets/apple-touch-icon.png")
try write(png(width: 1200, height: 630, inset: 0.2, background: .white), to: "website/assets/social-card.png")

// ICO directory with PNG payloads for browsers that do not use SVG favicons.
func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var value = value.littleEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
let sizes = [16, 32, 48]
let payloads = sizes.map { png(width: $0) }
var ico = littleEndian(UInt16(0)) + littleEndian(UInt16(1)) + littleEndian(UInt16(sizes.count))
var offset = 6 + 16 * sizes.count
for (size, data) in zip(sizes, payloads) {
    ico.append(contentsOf: [UInt8(size), UInt8(size), 0, 0])
    ico.append(littleEndian(UInt16(1)))
    ico.append(littleEndian(UInt16(32)))
    ico.append(littleEndian(UInt32(data.count)))
    ico.append(littleEndian(UInt32(offset)))
    offset += data.count
}
for data in payloads { ico.append(data) }
try write(ico, to: "website/favicon.ico")
print("Generated app icons, welcome logo, favicons, and social card from kodi-logo.svg.")
