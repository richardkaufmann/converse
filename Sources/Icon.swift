import AppKit
let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
func path(_ points: [NSPoint], close: Bool = true) -> NSBezierPath { let p = NSBezierPath(); p.move(to: points[0]); for point in points.dropFirst() { p.line(to: point) }; if close { p.close() }; p.lineJoinStyle = .round; return p }
for size in [16,32,64,128,256,512,1024] {
    let image = NSImage(size: NSSize(width: size, height: size)); image.lockFocus()
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(size)/1024); transform.concat()
    let tile = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 968, height: 968), xRadius: 210, yRadius: 210)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.23, blue: 0.35, alpha: 1), ending: NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 1))!.draw(in: tile, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35); shadow.shadowBlurRadius = 26; shadow.shadowOffset = NSSize(width: 0, height: -18); shadow.set()
    let shoe = path([NSPoint(x: 175,y: 330),NSPoint(x: 200,y: 720),NSPoint(x: 405,y: 765),NSPoint(x: 450,y: 560),NSPoint(x: 610,y: 405),NSPoint(x: 805,y: 350),NSPoint(x: 867,y: 300),NSPoint(x: 850,y: 233),NSPoint(x: 180,y: 233)])
    NSColor(calibratedRed: 0.81, green: 0.23, blue: 0.20, alpha: 1).setFill(); shoe.fill()
    NSGraphicsContext.restoreGraphicsState()
    let sole = NSBezierPath(roundedRect: NSRect(x: 160,y: 225,width: 714,height: 90), xRadius: 30,yRadius: 30); NSColor(calibratedWhite: 0.94,alpha: 1).setFill(); sole.fill()
    let stripe = path([NSPoint(x: 175,y: 251),NSPoint(x: 858,y: 251)], close: false); stripe.lineWidth = 9; NSColor(calibratedRed: 0.12,green: 0.17,blue: 0.25,alpha: 1).setStroke(); stripe.stroke()
    let toe = NSBezierPath(); toe.move(to: NSPoint(x: 625,y: 315)); toe.curve(to: NSPoint(x: 850,y: 315), controlPoint1: NSPoint(x: 658,y: 415),controlPoint2: NSPoint(x: 817,y: 382)); toe.close(); NSColor(calibratedWhite: 0.96,alpha: 1).setFill(); toe.fill()
    let patch = NSBezierPath(ovalIn: NSRect(x: 236,y: 480,width: 132,height: 132)); NSColor(calibratedWhite: 0.96,alpha: 1).setFill(); patch.fill()
    var star: [NSPoint] = []; for i in 0..<10 { let angle = Double(i)*Double.pi/5 + Double.pi/2; let radius = i % 2 == 0 ? 47.0 : 21.0; star.append(NSPoint(x: 302 + cos(angle)*radius,y: 546 + sin(angle)*radius)) }; NSColor(calibratedRed: 0.16,green: 0.23,blue: 0.35,alpha: 1).setFill(); path(star).fill()
    for i in 0..<5 { let x = 423.0 + Double(i)*34; let y = 561.0-Double(i)*35; let lace = path([NSPoint(x: x-26,y: y+23),NSPoint(x: x+32,y: y-5)], close: false); lace.lineWidth = 14; lace.lineCapStyle = .round; NSColor(calibratedWhite: 0.97,alpha: 1).setStroke(); lace.stroke() }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let data = bitmap.representation(using: .png, properties: [:])!
    let names: [String]
    switch size { case 16: names=["icon_16x16.png"]; case 32: names=["icon_16x16@2x.png","icon_32x32.png"]; case 64: names=["icon_32x32@2x.png"]; case 128: names=["icon_128x128.png"]; case 256: names=["icon_128x128@2x.png","icon_256x256.png"]; case 512: names=["icon_256x256@2x.png","icon_512x512.png"]; default: names=["icon_512x512@2x.png"] }
    for name in names { try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name)) }
}
