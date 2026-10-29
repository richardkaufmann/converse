import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, color) in [("meta", NSColor(srgbRed: 4/255, green: 103/255, blue: 223/255, alpha: 1)), ("anthropic", NSColor(srgbRed: 217/255, green: 119/255, blue: 87/255, alpha: 1)), ("openai", NSColor.black), ("openai-dark", NSColor.white)] {
    let source = name == "openai-dark" ? "openai" : name
    let image = NSImage(contentsOf: root.appendingPathComponent(source + ".svg"))!
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    image.draw(in: NSRect(x: 0, y: 0, width: 60, height: 60))
    color.setFill()
    NSRect(x: 0, y: 0, width: 60, height: 60).fill(using: .sourceIn)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(name + ".png"))
}
