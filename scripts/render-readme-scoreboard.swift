#!/usr/bin/env swift
// Place measured text onto the commissioned Muse scene without asking an image
// model to invent or redraw numbers. Coordinates belong to this artwork only.
import AppKit
import CoreImage

guard CommandLine.arguments.count == 4 else {
    fatalError("Usage: render-readme-scoreboard.swift background.png measurements.json output.jpg")
}
struct Measurements: Decodable {
    struct Section: Decodable { var label: String; var count: Int; var colors: String }
    var measuredUTC: String
    var revision: Int
    var sections: [Section]
    var stars: Int
    var downloads: Int
    var cloners14d: Int
    var clonersTodayUTC: Int?
}
let measurements = try JSONDecoder().decode(Measurements.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
let backgroundURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let background = CIImage(contentsOf: backgroundURL), background.extent.size == CGSize(width: 1920, height: 1280),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 680, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Invalid artwork or bitmap") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphics
NSColor(calibratedRed: 0.025, green: 0.045, blue: 0.065, alpha: 0.94).setFill()
NSRect(x: 0, y: 0, width: 1200, height: 680).fill()
func text(_ value: String, x: CGFloat, top: CGFloat, width: CGFloat, size: CGFloat, color: NSColor = .white, bold: Bool = false) {
    let style = NSMutableParagraphStyle(); style.lineBreakMode = .byWordWrapping
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .medium), .foregroundColor: color, .paragraphStyle: style]
    let height = ceil((value as NSString).boundingRect(with: NSSize(width: width, height: 200), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).height)
    (value as NSString).draw(in: NSRect(x: x, y: 680 - top - height, width: width, height: height + 3), withAttributes: attributes)
}
let amber = NSColor(calibratedRed: 1, green: 0.77, blue: 0.35, alpha: 1)
let secondary = NSColor(calibratedRed: 0.68, green: 0.79, blue: 0.84, alpha: 1)
text("CONVERSE-DEV STATUS", x: 40, top: 26, width: 1120, size: 58, bold: true)
text("UNFINISHED DEV BACKLOG", x: 40, top: 112, width: 650, size: 29, color: amber, bold: true)
text("PUBLIC · converse", x: 725, top: 112, width: 445, size: 29, color: amber, bold: true)
for (index, section) in measurements.sections.enumerated() {
    let top = CGFloat(164 + index * 90)
    text(section.label + ": " + String(section.count), x: 40, top: top, width: 650, size: 36, bold: true)
    if !section.colors.isEmpty { text(section.colors, x: 40, top: top + 45, width: 650, size: 27, color: secondary) }
}
let metrics = [
    ("Stars", String(measurements.stars)),
    ("Downloads · total", String(measurements.downloads)),
    ("Cloners · 14 days", String(measurements.cloners14d)),
    ("Cloners · today UTC", measurements.clonersTodayUTC.map(String.init) ?? "Unavailable")
]
for (index, metric) in metrics.enumerated() {
    let top = CGFloat(164 + index * 90)
    text(metric.0, x: 725, top: top, width: 435, size: 27, color: secondary)
    text(metric.1, x: 725, top: top + 33, width: 435, size: 40, color: amber, bold: true)
}
text("Lot r\(measurements.revision) · \(measurements.measuredUTC)", x: 40, top: 554, width: 1120, size: 25, color: secondary)
text("Cloners are unique; lifetime total unavailable.", x: 40, top: 594, width: 1120, size: 24, color: secondary)
text("Downloads: cumulative, all public releases", x: 40, top: 631, width: 1120, size: 23, color: secondary)
NSGraphicsContext.restoreGraphicsState()
guard let cg = bitmap.cgImage else { fatalError("Cannot encode scoreboard") }
let panel = CIImage(cgImage: cg).applyingFilter("CIPerspectiveTransform", parameters: [
    "inputTopLeft": CIVector(x: 558, y: 1017),
    "inputTopRight": CIVector(x: 1330, y: 881),
    "inputBottomLeft": CIVector(x: 558, y: 552),
    "inputBottomRight": CIVector(x: 1338, y: 524)
])
let result = panel.composited(over: background).cropped(to: background.extent)
    .applyingFilter("CILanczosScaleTransform", parameters: ["inputScale": 1600.0 / 1920.0, "inputAspectRatio": 1.0])
try CIContext().writeJPEGRepresentation(of: result, to: URL(fileURLWithPath: CommandLine.arguments[3]), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.78])
print("Rendered measured scoreboard: " + CommandLine.arguments[3])
