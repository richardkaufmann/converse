import SwiftUI
import UIKit

final class TailTextView: UITextView {
    var send: (() -> Void)?
    var insertingNewline = false
    var historyLength = 0
    var promptBlocks: [NSRange] = []
    var trafficBlocks: [NSRange] = []
    let gutter = PadGutter()
    override init(frame: CGRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    static func native() -> TailTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager(); storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; layout.addTextContainer(container)
        return TailTextView(frame: .zero, textContainer: container)
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        if gutter.superview == nil { gutter.text = self; gutter.isUserInteractionEnabled = false; addSubview(gutter) }
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: 42, height: bounds.height)
        bringSubviewToFront(gutter); gutter.setNeedsDisplay()
    }
    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(newline))]
    }
    @objc private func newline() { insertingNewline = true; insertText("\n"); insertingNewline = false }
    override func insertText(_ text: String) {
        if selectedRange.location < historyLength { selectedRange = NSRange(location: textStorage.length, length: 0) }
        super.insertText(text)
    }
    override func paste(_ sender: Any?) {
        if let image = UIPasteboard.general.image, let data = image.pngData(), let coordinator = delegate as? PadTranscript.Coordinator { coordinator.parent.attach(data); return }
        super.paste(sender)
    }
}

// A single native selectable document: history is protected; only the blue
// tail is editable. Snapshot echoes preserve draft-relative selection.
struct PadTranscript: UIViewRepresentable {
    var messages: [DeviceWireMessage]
    var draft: String
    var images: [String: URL]
    var editable: Bool
    var lineNumbers: Bool
    var edit: (String) -> Void
    var send: () -> Void
    var attach: (Data) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> TailTextView {
        let view = TailTextView.native(); view.delegate = context.coordinator; view.font = .systemFont(ofSize: 16)
        view.backgroundColor = .systemBackground; view.textColor = .label
        view.isEditable = editable; view.isSelectable = true; view.alwaysBounceVertical = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 24, right: 10)
        view.keyboardDismissMode = .interactive; view.returnKeyType = .send
        view.autocorrectionType = .yes; view.smartQuotesType = .no; view.smartDashesType = .no
        view.accessibilityLabel = "Conversation. History followed by editable draft"
        view.send = send
        context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: TailTextView, context: Context) { update(view, coordinator: context.coordinator) }
    func update(_ view: TailTextView, coordinator c: Coordinator) {
        c.parent = self; view.send = send; view.isEditable = editable
        guard !c.updating else { return }
        view.gutter.isHidden = !lineNumbers
        view.textContainerInset.left = lineNumbers ? 48 : 10
        let signature = messages.map { $0.id.uuidString + $0.role + $0.text + $0.imageHashes.joined() }.joined() + images.keys.sorted().joined() + String(lineNumbers)
        guard signature != c.signature || c.lastDraft != draft else { return }
        // Don't overwrite marked text while dictation/IME is composing.
        if view.markedTextRange != nil { return }
        let oldHistoryLength = c.historyLength
        let previousSelection = view.selectedRange
        let relative = previousSelection.location >= c.historyLength ? previousSelection.location - c.historyLength : nil
        let previousHeight = view.contentSize.height
        let nearBottom = view.contentOffset.y + view.bounds.height >= previousHeight - 80
        let prepend = c.firstMessage != nil && messages.first?.id != c.firstMessage
        c.updating = true

        let result = NSMutableAttributedString()
        view.promptBlocks = []; view.trafficBlocks = []
        for message in messages {
            let prompt = message.role == "user"
            let color: UIColor = prompt ? .label : .label
            let body = Self.render(message.text)
            if prompt { body.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: 16), range: NSRange(location: 0, length: body.length)) }
            body.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: body.length))
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            let start = result.length
            if TranscriptStyle.isTraffic(message.text) { body.addAttribute(.foregroundColor, value: PadPalette.traffic, range: NSRange(location: 0, length: body.length)) }
            result.append(body); result.append(NSAttributedString(string: "\n"))
            for hash in message.imageHashes {
                guard let url = images[hash], let image = UIImage(contentsOfFile: url.path) else { continue }
                let attachment = NSTextAttachment(); attachment.image = image
                let maxWidth = max(100, view.bounds.width - 40)
                let ratio = min(1, maxWidth / image.size.width)
                attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * ratio, height: image.size.height * ratio)
                result.append(NSAttributedString(attachment: attachment)); result.append(NSAttributedString(string: "\n"))
            }
            let range = NSRange(location: start, length: result.length - start)
            if prompt { view.promptBlocks.append(range) }
            if TranscriptStyle.isTraffic(message.text) { view.trafficBlocks.append(range) }
        }
        if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
        c.historyLength = result.length
        view.historyLength = result.length
        result.append(NSAttributedString(string: draft, attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: PadPalette.draft(draft)]))
        view.attributedText = result
        view.typingAttributes = [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: PadPalette.draft(draft)]
        if let relative {
            let position = min(result.length, c.historyLength + relative)
            view.selectedRange = NSRange(location: position, length: min(previousSelection.length, result.length - position))
        } else {
            let position = min(result.length, previousSelection.location + (prepend ? max(0, c.historyLength - oldHistoryLength) : 0))
            view.selectedRange = NSRange(location: position, length: min(previousSelection.length, result.length - position))
        }
        view.layoutIfNeeded()
        if prepend && !nearBottom { view.setContentOffset(CGPoint(x: 0, y: max(0, view.contentOffset.y + view.contentSize.height - previousHeight)), animated: false) }
        else if nearBottom { view.scrollRangeToVisible(NSRange(location: result.length, length: 0)) }
        c.signature = signature; c.lastDraft = draft; c.firstMessage = messages.first?.id
        // History changes invalidate the undo stack's character offsets.
        // Clearing it also prevents undo from modifying protected history.
        view.undoManager?.removeAllActions(); c.updating = false
    }
    static func render(_ text: String) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        guard let parsed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSMutableAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 16)])
        }
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? UIFont.monospacedSystemFont(ofSize: 14, weight: .regular) : UIFont.systemFont(ofSize: 16)
            var traits: UIFontDescriptor.SymbolicTraits = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
            if intent.contains(.emphasized) { traits.insert(.traitItalic) }
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { font = UIFont(descriptor: descriptor, size: font.pointSize) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
            if intent.contains(.code) { attrs[.backgroundColor] = UIColor.quaternarySystemFill }
            if let link = run.link, ["http", "https"].contains(link.scheme ?? "") { attrs[.link] = link }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attrs))
        }
        return output
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PadTranscript
        weak var view: TailTextView?
        var updating = false
        var historyLength = 0
        var signature = ""
        var lastDraft = ""
        var firstMessage: UUID?
        init(_ parent: PadTranscript) { self.parent = parent }
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !updating, parent.editable else { return false }
            guard range.location >= historyLength else {
                view.selectedRange = NSRange(location: view.textStorage.length, length: 0); return false
            }
            if text == "\n" {
                // Hardware Command-Return goes through insertText too; use
                // explicit newline action to distinguish it from Send.
                if let tail = view as? TailTextView, tail.insertingNewline { return true }
                parent.send(); return false
            }
            return true
        }
        func textViewDidChange(_ view: UITextView) {
            guard !updating, view.textStorage.length >= historyLength else { return }
            let text = (view.text as NSString).substring(from: historyLength)
            lastDraft = text
            let color = PadPalette.draft(text)
            view.textStorage.addAttribute(.foregroundColor, value: color, range: NSRange(location: historyLength, length: view.textStorage.length - historyLength))
            view.typingAttributes = [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: color]
            (view as? TailTextView)?.gutter.setNeedsDisplay()
            parent.edit(text)
        }
    }
}
