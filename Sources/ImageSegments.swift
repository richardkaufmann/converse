import Foundation
import CoreGraphics
import ImageIO
import SwiftUI

struct DeviceImageSegment: Codable, Equatable {
    var region: DeviceImageRegion
    var label: String
    var mask: String
}
struct ImageSegment {
    let wire: DeviceImageSegment
    let pixels: [UInt8]
    let area: Int
    let outline: CGImage
    let tint: CGImage
    let anchor: CGPoint
    init(_ wire: DeviceImageSegment) throws {
        let b = wire.region
        guard b.imageWidth > 0, b.imageHeight > 0, b.imageWidth <= 2048, b.imageHeight <= 2048,
              b.x >= 0, b.y >= 0, b.width > 0, b.height > 0, b.x <= b.imageWidth - b.width, b.y <= b.imageHeight - b.height else { throw SAMMask.invalid() }
        self.wire = wire
        pixels = try SAMMask.decode(wire.mask, width: b.width, height: b.height)
        area = pixels.reduce(0) { $0 + Int($1) }
        guard area > 0 else { throw SAMMask.invalid() }
        var edge = [UInt8](repeating: 0, count: pixels.count * 4), fill = edge
        var nearest = 0, distance = Double.infinity
        for y in 0..<b.height { for x in 0..<b.width {
            let i = y * b.width + x
            guard pixels[i] != 0 else { continue }
            let d = pow(Double(x) - Double(b.width) / 2, 2) + pow(Double(y) - Double(b.height) / 2, 2)
            if d < distance { distance = d; nearest = i }
            fill[i * 4] = 72; fill[i * 4 + 1] = 35; fill[i * 4 + 3] = 80
            if x == 0 || y == 0 || x == b.width - 1 || y == b.height - 1 || pixels[i - 1] == 0 || pixels[i + 1] == 0 || pixels[i - b.width] == 0 || pixels[i + b.width] == 0 {
                edge[i * 4] = 255; edge[i * 4 + 1] = 150; edge[i * 4 + 3] = 255
            }
        } }
        outline = try Self.rgbaImage(edge, width: b.width, height: b.height)
        tint = try Self.rgbaImage(fill, width: b.width, height: b.height)
        anchor = CGPoint(x: b.x + nearest % b.width, y: b.y + nearest / b.width)
    }
    func contains(x: Int, y: Int) -> Bool {
        let b = wire.region, x = x - wire.region.x, y = y - wire.region.y
        return x >= 0 && y >= 0 && x < b.width && y < b.height && pixels[y * b.width + x] != 0
    }
    static func prepare(_ wire: [DeviceImageSegment]) throws -> [ImageSegment] {
        guard wire.count <= 32, wire.reduce(0, { $0 + $1.mask.utf8.count }) <= 1_000_000 else { throw SAMMask.invalid() }
        var budget = 0
        for item in wire {
            guard item.region.width > 0, item.region.width <= 2048, item.region.height > 0, item.region.height <= 2048 else { throw SAMMask.invalid() }
            budget += item.region.width * item.region.height
            guard budget <= 24_000_000 else { throw ImageAssistError.invalid("Too many detailed segments. Try a more specific description.") }
        }
        return try wire.map { try ImageSegment($0) }
    }
    static func rgbaImage(_ bytes: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw SAMMask.invalid() }
        return image
    }
    static func export(_ image: CGImage, segments: [ImageSegment], crop: Bool) throws -> CGImage {
        guard !segments.isEmpty, image.width <= 2048, image.height <= 2048,
              segments.allSatisfy({ $0.wire.region.imageWidth == image.width && $0.wire.region.imageHeight == image.height }) else { throw SAMMask.invalid() }
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard drawn else { throw SAMMask.invalid() }
        var union = [UInt8](repeating: 0, count: w * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for segment in segments {
            let b = segment.wire.region
            for y in 0..<b.height { for x in 0..<b.width where segment.pixels[y * b.width + x] != 0 {
                union[(y + b.y) * w + x + b.x] = 1
                minX = min(minX, x + b.x); maxX = max(maxX, x + b.x); minY = min(minY, y + b.y); maxY = max(maxY, y + b.y)
            } }
        }
        for i in union.indices where union[i] == 0 { for channel in 0..<4 { bytes[i * 4 + channel] = 0 } }
        let result = try rgbaImage(bytes, width: w, height: h)
        if crop {
            guard maxX >= minX, maxY >= minY, let cut = result.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { throw SAMMask.invalid() }; return cut
        }
        return result
    }
    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { throw SAMMask.invalid() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SAMMask.invalid() }; return data as Data
    }
}

struct SegmentPicker: View {
    let image: CGImage
    let segments: [ImageSegment]
    @Binding var selected: Set<Int>
    @State private var numbers = ""
    private func toggle(_ i: Int) { if selected.contains(i) { selected.remove(i) } else { selected.insert(i) } }
    var body: some View {
        VStack(alignment: .leading) {
            GeometryReader { space in
                let ratio = min(space.size.width / CGFloat(image.width), space.size.height / CGFloat(image.height))
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1).resizable().frame(width: CGFloat(image.width) * ratio, height: CGFloat(image.height) * ratio)
                    ForEach(segments.indices, id: \.self) { i in
                        let s = segments[i], b = s.wire.region
                        if selected.contains(i) {
                            Image(decorative: s.tint, scale: 1).resizable().frame(width: CGFloat(b.width) * ratio, height: CGFloat(b.height) * ratio).offset(x: CGFloat(b.x) * ratio, y: CGFloat(b.y) * ratio).allowsHitTesting(false)
                        }
                        Image(decorative: s.outline, scale: 1).resizable().interpolation(.none).frame(width: CGFloat(b.width) * ratio, height: CGFloat(b.height) * ratio).offset(x: CGFloat(b.x) * ratio, y: CGFloat(b.y) * ratio).allowsHitTesting(false)
                    }
                }.contentShape(Rectangle()).onTapGesture { point in
                    let hits = segments.indices.filter { segments[$0].contains(x: Int(point.x / ratio), y: Int(point.y / ratio)) }
                    if let i = hits.min(by: { segments[$0].area < segments[$1].area }) { toggle(i) }
                }.overlay(alignment: .topLeading) {
                    ForEach(segments.indices, id: \.self) { i in
                        let s = segments[i]
                        Button { toggle(i) } label: {
                            Text("\(i + 1)").font(.caption.bold()).foregroundStyle(.white).padding(5).background(selected.contains(i) ? Color.orange : Color.black.opacity(0.75), in: Capsule())
                        }.buttonStyle(.plain).accessibilityLabel("Segment \(i + 1): \(s.wire.label), \(selected.contains(i) ? "selected" : "not selected")")
                            .offset(x: max(0, min(CGFloat(image.width) * ratio - 28, s.anchor.x * ratio - 12)), y: max(0, min(CGFloat(image.height) * ratio - 28, s.anchor.y * ratio - 12)))
                    }
                }
            }.frame(height: 320)
            if !segments.isEmpty {
                HStack {
                    Button("All") { selected = Set(segments.indices) }
                    Button("None") { selected = [] }
                    Text("\(selected.count) of \(segments.count) selected").foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Toggle numbers, e.g. 1, 3, 12", text: $numbers).onSubmit(toggleNumbers)
                    Button("Toggle", action: toggleNumbers)
                }
                Text("Tap an object or its number to select it. For overlapping objects, tapping the image picks the smallest; use numbers to choose another.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func toggleNumbers() {
        let values = numbers.split(whereSeparator: { $0 == "," || $0.isWhitespace }).compactMap { Int($0) }
        for n in Set(values) where segments.indices.contains(n - 1) { toggle(n - 1) }; numbers = ""
    }
}
