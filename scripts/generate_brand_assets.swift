#!/usr/bin/env swift
// Original geometric artwork for GenBooks. No source images, fonts, or third-party marks.
// Run from the repository root: swift scripts/generate_brand_assets.swift
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}

func bookMark(left: NSColor, right: NSColor) {
    let page = NSBezierPath()
    page.move(to: NSPoint(x: 236, y: 682))
    page.curve(to: NSPoint(x: 492, y: 636), controlPoint1: NSPoint(x: 336, y: 720), controlPoint2: NSPoint(x: 414, y: 682))
    page.line(to: NSPoint(x: 492, y: 326))
    page.curve(to: NSPoint(x: 236, y: 372), controlPoint1: NSPoint(x: 400, y: 386), controlPoint2: NSPoint(x: 322, y: 408))
    page.close(); left.setFill(); page.fill()
    let other = NSBezierPath()
    other.move(to: NSPoint(x: 788, y: 682))
    other.curve(to: NSPoint(x: 532, y: 636), controlPoint1: NSPoint(x: 688, y: 720), controlPoint2: NSPoint(x: 610, y: 682))
    other.line(to: NSPoint(x: 532, y: 326))
    other.curve(to: NSPoint(x: 788, y: 372), controlPoint1: NSPoint(x: 624, y: 386), controlPoint2: NSPoint(x: 702, y: 408))
    other.close(); right.setFill(); other.fill()
}

func render(path: String, width: Int, height: Int, background: UInt32, foreground: UInt32, cover: Bool) throws {
    let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let context = NSGraphicsContext(cgContext: cg, flipped: false)
    NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    let canvasHeight: CGFloat = cover ? 1536 : 1024
    context.cgContext.scaleBy(x: CGFloat(width) / 1024, y: CGFloat(height) / canvasHeight)
    color(background).setFill(); NSRect(x: 0, y: 0, width: 1024, height: canvasHeight).fill()
    if cover {
        color(foreground).withAlphaComponent(0.10).setFill()
        NSRect(x: 0, y: 0, width: 60, height: canvasHeight).fill()
        context.cgContext.saveGState()
        context.cgContext.translateBy(x: 0, y: 290)
        bookMark(left: color(foreground), right: color(foreground).withAlphaComponent(0.62))
        context.cgContext.restoreGState()
        color(foreground).withAlphaComponent(0.55).setFill()
        NSRect(x: 236, y: 294, width: 350, height: 7).fill()
        NSRect(x: 236, y: 250, width: 210, height: 7).fill()
    } else {
        bookMark(left: color(0xF1F2E9), right: color(0x78D9CB))
    }
    guard let image = cg.makeImage(),
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("PNG render failed")
    }
    try data.write(to: URL(fileURLWithPath: path), options: .atomic)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconRoot = root.appendingPathComponent("Resources/Assets.xcassets/AppIcon.appiconset")
let iconJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: iconRoot.appendingPathComponent("Contents.json"))) as! [String: Any]
var rendered = Set<String>()
for row in iconJSON["images"] as! [[String: Any]] {
    guard let filename = row["filename"] as? String, rendered.insert(filename).inserted else { continue }
    let points = Double((row["size"] as! String).split(separator: "x")[0])!
    let scale = Double((row["scale"] as? String ?? "1x").dropLast())!
    let pixels = Int(points * scale)
    try render(path: iconRoot.appendingPathComponent(filename).path, width: pixels, height: pixels,
        background: 0x123E36, foreground: 0xF1F2E9, cover: false)
}
let covers: [(String, String, UInt32, UInt32)] = [
    ("CoverArgentina", "argentina", 0xE3E6D5, 0x345F50),
    ("CoverQuran", "quran", 0x1A4038, 0xE3E6D5),
    ("CoverGenerated", "generated", 0xC9DBD3, 0x245148),
    ("CoverImported", "imported", 0xD9DED9, 0x405850)
]
for (catalog, name, background, foreground) in covers {
    let path = root.appendingPathComponent("Resources/Assets.xcassets/\(catalog).imageset/\(catalog).png")
    try render(path: path.path, width: 512, height: 768, background: background, foreground: foreground, cover: true)
    for suffix in ["", "-portrait"] {
        let file = root.appendingPathComponent("Resources/Fixtures/covers/cover-\(name)\(suffix).png")
        // Retain only names already used by the app and its fixtures.
        if FileManager.default.fileExists(atPath: file.path) {
            try render(path: file.path, width: 512, height: 768, background: background, foreground: foreground, cover: true)
        }
    }
}
print("Rendered original GenBooks geometric icon and cover assets.")
