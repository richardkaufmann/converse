import SwiftUI

// A small vector tennis shoe stays crisp at sidebar and pane-title sizes.
struct ParkingLotShoe: View {
    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 24, y: size.height / 24)
            let upper = Path { p in
                p.move(to: CGPoint(x: 2, y: 7))
                p.addQuadCurve(to: CGPoint(x: 7, y: 9), control: CGPoint(x: 4, y: 10))
                p.addLine(to: CGPoint(x: 10, y: 5))
                p.addQuadCurve(to: CGPoint(x: 16, y: 12), control: CGPoint(x: 12, y: 10))
                p.addQuadCurve(to: CGPoint(x: 22, y: 16), control: CGPoint(x: 22, y: 12))
                p.addLine(to: CGPoint(x: 22, y: 19))
                p.addLine(to: CGPoint(x: 2, y: 19))
                p.closeSubpath()
            }
            context.fill(upper, with: .color(Color(red: 0.12, green: 0.43, blue: 0.86)))
            context.stroke(upper, with: .color(Color(red: 0.07, green: 0.27, blue: 0.57)), lineWidth: 0.7)
            let sole = Path(roundedRect: CGRect(x: 1.5, y: 17, width: 21, height: 3.2), cornerRadius: 1.3)
            context.fill(sole, with: .color(Color(white: 0.96)))
            context.stroke(sole, with: .color(Color(white: 0.45)), lineWidth: 0.7)
            let laces = Path { p in
                p.move(to: CGPoint(x: 9, y: 9)); p.addLine(to: CGPoint(x: 12, y: 9))
                p.move(to: CGPoint(x: 10, y: 11)); p.addLine(to: CGPoint(x: 14, y: 11))
                p.move(to: CGPoint(x: 12, y: 13)); p.addLine(to: CGPoint(x: 16, y: 13))
            }
            context.stroke(laces, with: .color(.white), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
    }
}

