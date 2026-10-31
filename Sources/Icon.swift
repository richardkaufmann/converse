import AppKit

// One supplied master for every app surface. Preserve its aspect and artwork.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let master = root.appendingPathComponent("Resources/Branding/Converse-Logo.jpeg")
guard let source = NSImage(contentsOf: master)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("Missing Converse logo master") }
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func png(_ size: Int) -> Data {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let scale = CGFloat(size) / CGFloat(max(source.width, source.height)), w = CGFloat(source.width) * scale, h = CGFloat(source.height) * scale
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}
for size in [16,32,64,128,256,512,1024] {
    let names: [String]
    switch size { case 16: names=["icon_16x16.png"]; case 32: names=["icon_16x16@2x.png","icon_32x32.png"]; case 64: names=["icon_32x32@2x.png"]; case 128: names=["icon_128x128.png"]; case 256: names=["icon_128x128@2x.png","icon_256x256.png"]; case 512: names=["icon_256x256@2x.png","icon_512x512.png"]; default: names=["icon_512x512@2x.png"] }
    let data = png(size)
    for name in names { try data.write(to: output.appendingPathComponent(name)) }
}
if CommandLine.arguments.contains("--all") {
    try png(1024).write(to: root.appendingPathComponent("iPad/Converse/Assets.xcassets/AppIcon.appiconset/Converse.png"))
    try png(512).write(to: root.appendingPathComponent("Resources/Branding/Converse.png"))
    try png(512).write(to: root.appendingPathComponent("docs/converse-icon.png"))
    let packaging = root.appendingPathComponent("windows/packaging/Assets")
    try FileManager.default.createDirectory(at: packaging, withIntermediateDirectories: true)
    for (name, size) in [("StoreLogo",50),("Square150x150Logo",150),("Square44x44Logo",44)] {
        try png(size).write(to: packaging.appendingPathComponent(name + ".png"))
    }
    let sizes = [16,32,48,64,128,256], images = sizes.map(png)
    var ico = Data()
    func word(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { ico.append(contentsOf: $0) } }
    func dword(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { ico.append(contentsOf: $0) } }
    word(0); word(1); word(UInt16(sizes.count))
    var offset = 6 + sizes.count * 16
    for (size, image) in zip(sizes, images) {
        ico.append(contentsOf: [UInt8(size % 256), UInt8(size % 256), 0, 0]); word(1); word(32); dword(UInt32(image.count)); dword(UInt32(offset)); offset += image.count
    }
    for image in images { ico.append(image) }
    try ico.write(to: root.appendingPathComponent("Resources/Branding/Converse.ico"))
}
