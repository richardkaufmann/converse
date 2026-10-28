import UIKit

// Native text gutter, kept fixed horizontally while the document scrolls.
final class PadGutter: UIView {
    weak var text: TailTextView?
    override func draw(_ rect: CGRect) {
        guard let text else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        (dark ? UIColor.black : UIColor.white).setFill(); UIRectFill(bounds)
        let layout = text.layoutManager
        let source = text.text as NSString
        let origin = text.textContainerInset.top - text.contentOffset.y
        func blockRect(_ range: NSRange) -> CGRect? {
            guard range.length > 0, range.location < source.length else { return nil }
            let end = min(NSMaxRange(range), source.length)
            let a = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            let b = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: end - 1), effectiveRange: nil)
            return CGRect(x: 0, y: origin + a.minY, width: bounds.width, height: b.maxY - a.minY)
        }
        if !dark {
            PadPalette.promptBackground.setFill()
            for range in text.promptBlocks { if let rect = blockRect(range) { UIRectFill(rect) } }
            let a = text.historyLength < source.length ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: text.historyLength), effectiveRange: nil) : layout.extraLineFragmentRect
            let b = source.length > text.historyLength && !text.text.hasSuffix("\n") ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: source.length - 1), effectiveRange: nil) : layout.extraLineFragmentRect
            (TranscriptStyle.isTraffic(source.substring(from: min(text.historyLength, source.length))) ? PadPalette.trafficBackground : PadPalette.promptBackground).setFill()
            UIRectFill(CGRect(x: 0, y: origin + a.minY, width: bounds.width, height: max(18, b.maxY - a.minY)))
            PadPalette.trafficBackground.setFill()
            for range in text.trafficBlocks { if let rect = blockRect(range) { UIRectFill(rect) } }
        }
        var offset = 0; var line = 1
        repeat {
            let fragment = offset < source.length ? layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: offset), effectiveRange: nil) : layout.extraLineFragmentRect
            let prompt = offset >= text.historyLength || text.promptBlocks.contains { NSLocationInRange(offset, $0) }
            let traffic = text.trafficBlocks.contains { NSLocationInRange(offset, $0) } || (offset >= text.historyLength && TranscriptStyle.isTraffic(source.substring(from: min(text.historyLength, source.length))))
            let color: UIColor = traffic ? PadPalette.traffic : dark ? (prompt ? .systemBlue : .white) : UIColor(white: 0.475, alpha: 1)
            let label = NSAttributedString(string: String(line), attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color])
            let y = origin + fragment.minY + max(0, (fragment.height - label.size().height) / 2)
            if y >= -20 && y <= bounds.height { label.draw(at: CGPoint(x: bounds.width - label.size().width - 8, y: y)) }
            if offset >= source.length { break }
            offset = NSMaxRange(source.lineRange(for: NSRange(location: offset, length: 0))); line += 1
            if offset == source.length && !text.text.hasSuffix("\n") { break }
        } while offset <= source.length
    }
}
enum PadPalette {
    static let promptBackground = UIColor(red: 212.0 / 255, green: 231.0 / 255, blue: 1, alpha: 1)
    static let trafficBackground = UIColor(red: 1, green: 0.89, blue: 0.76, alpha: 1)
    static let traffic = UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(red: 1, green: 0.70, blue: 0.36, alpha: 1) : UIColor(red: 0.65, green: 0.27, blue: 0, alpha: 1) }
    static func draft(_ text: String) -> UIColor { TranscriptStyle.isTraffic(text) ? traffic : .systemBlue }
}
