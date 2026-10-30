import SwiftUI
import UIKit

final class TailTextView: UITextView {
    var send: (() -> Void)?
    var insertingNewline = false
    var pastingText = false
    var historyLength = 0
    var promptBlocks: [NSRange] = []
    var trafficBlocks: [NSRange] = []
    let gutter = PadGutter()
    var draftImages: [(location: Int, hash: String)] = []
    private(set) var draftImageButtons: [UIButton] = []
    var removeDraftImage: ((String) -> Void)?
    func configureDraftImageButtons() {
        draftImageButtons.forEach { $0.removeFromSuperview() }; draftImageButtons = []
        for image in draftImages {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)), for: .normal)
            button.tintColor = .white; button.backgroundColor = UIColor.black.withAlphaComponent(0.8)
            button.layer.cornerRadius = 16; button.accessibilityLabel = "Remove image from draft"
            button.addAction(UIAction { [weak self] _ in self?.removeDraftImage?(image.hash) }, for: .touchUpInside)
            addSubview(button); draftImageButtons.append(button)
        }
        setNeedsLayout()
    }
    private func layoutDraftImageButtons() {
        guard !draftImageButtons.isEmpty else { return }
        layoutManager.ensureLayout(for: textContainer)
        for (image, button) in zip(draftImages, draftImageButtons) {
            button.isHidden = !isEditable || removeDraftImage == nil || image.location >= textStorage.length
            guard !button.isHidden else { continue }
            let glyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: image.location, length: 1), actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyph, in: textContainer).offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
            button.frame = CGRect(x: max(rect.minX, rect.maxX - 34), y: rect.minY + 2, width: 32, height: 32)
            bringSubviewToFront(button)
        }
    }
    enum Viewport { case bottom, offset(CGFloat), anchor(Int, CGFloat) }
    var pendingViewport: Viewport?
    private var previousBounds = CGSize.zero
    private var previousContentHeight: CGFloat = 0
    override init(frame: CGRect, textContainer: NSTextContainer?) { super.init(frame: frame, textContainer: textContainer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    static func native() -> TailTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager(); layout.allowsNonContiguousLayout = false; storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true; layout.addTextContainer(container)
        let view = TailTextView(frame: .zero, textContainer: container)
        layout.allowsNonContiguousLayout = false
        return view
    }
    override func layoutSubviews() {
        if pendingViewport == nil, previousBounds != .zero, previousBounds != bounds.size,
           contentOffset.y + previousBounds.height >= previousContentHeight - 80, !isDragging, !isDecelerating {
            pendingViewport = .bottom
        }
        let geometryChanged = previousBounds != bounds.size
        if geometryChanged {
            layoutManager.invalidateLayout(forCharacterRange: NSRange(location: 0, length: textStorage.length), actualCharacterRange: nil)
        }
        super.layoutSubviews()
        if geometryChanged {
            layoutManager.ensureLayout(for: textContainer)
            layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
            setNeedsDisplay()
        }
        if let viewport = pendingViewport, bounds.width > 0, bounds.height > 0 {
            pendingViewport = nil
            layoutManager.ensureLayout(for: textContainer)
            let target: CGFloat
            switch viewport {
            case .bottom: target = contentSize.height - bounds.height + adjustedContentInset.bottom
            case .offset(let y): target = y
            case .anchor(let character, let distance): target = lineTop(at: character) - distance
            }
            let minimum = -adjustedContentInset.top
            let maximum = max(minimum, contentSize.height - bounds.height + adjustedContentInset.bottom)
            setContentOffset(CGPoint(x: 0, y: min(maximum, max(minimum, target))), animated: false)
        }
        previousBounds = bounds.size; previousContentHeight = contentSize.height
        if gutter.superview == nil { gutter.text = self; gutter.isUserInteractionEnabled = false; addSubview(gutter) }
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: 42, height: bounds.height)
        bringSubviewToFront(gutter); gutter.setNeedsDisplay()
        layoutDraftImageButtons()
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        layoutManager.ensureLayout(for: textContainer)
        layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: textStorage.length))
        setNeedsLayout(); setNeedsDisplay()
    }
    override var keyCommands: [UIKeyCommand]? {
        let commands = [UIKeyCommand(input: "\r", modifierFlags: .command, action: #selector(handleReturnCommand(_:))),
                        UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(handleReturnCommand(_:)))]
        for command in commands { command.wantsPriorityOverSystemBehavior = true }
        return commands
    }
    static func isReturn(_ text: String) -> Bool { !text.isEmpty && text.unicodeScalars.allSatisfy { CharacterSet.newlines.contains($0) } }
    @objc private func handleReturnCommand(_ command: UIKeyCommand) { hardwareReturn(modifiers: command.modifierFlags) }
    func hardwareReturn(modifiers: UIKeyModifierFlags) {
        guard isEditable else { return }
        if markedTextRange != nil { unmarkText(); return }
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            let location = max(historyLength, min(selectedRange.location, textStorage.length))
            let length = min(selectedRange.length, textStorage.length - location)
            let coordinator = delegate as? PadTranscript.Coordinator
            coordinator?.updating = true
            textStorage.replaceCharacters(in: NSRange(location: location, length: length), with: "\n")
            selectedRange = NSRange(location: location + 1, length: 0)
            coordinator?.updating = false; coordinator?.textViewDidChange(self)
        } else { send?() }
    }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { press in
            guard let key = press.key, Self.isReturn(key.charactersIgnoringModifiers) else { return true }
            hardwareReturn(modifiers: key.modifierFlags); return false
        }
        if !remaining.isEmpty { super.pressesBegan(Set(remaining), with: event) }
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { !Self.isReturn($0.key?.charactersIgnoringModifiers ?? "") }
        if !remaining.isEmpty { super.pressesEnded(Set(remaining), with: event) }
    }
    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { !Self.isReturn($0.key?.charactersIgnoringModifiers ?? "") }
        if !remaining.isEmpty { super.pressesCancelled(Set(remaining), with: event) }
    }
    override func insertText(_ text: String) {
        guard isEditable else { return }
        if Self.isReturn(text), !insertingNewline, !pastingText, markedTextRange == nil { send?(); return }
        if selectedRange.location < historyLength { selectedRange = NSRange(location: textStorage.length, length: 0) }
        super.insertText(text)
    }
    override func replace(_ range: UITextRange, withText text: String) {
        guard isEditable else { return }
        if Self.isReturn(text), !insertingNewline, !pastingText, markedTextRange == nil { send?(); return }
        if offset(from: beginningOfDocument, to: range.start) < historyLength {
            selectedRange = NSRange(location: textStorage.length, length: 0)
            if !text.isEmpty { insertText(text) }; return
        }
        super.replace(range, withText: text)
    }
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        if let image = UIPasteboard.general.image, let data = image.pngData(), let coordinator = delegate as? PadTranscript.Coordinator { coordinator.parent.attach(data); return }
        pastingText = true; defer { pastingText = false }; super.paste(sender)
    }
    func lineTop(at character: Int) -> CGFloat {
        if character >= textStorage.length { return textContainerInset.top + layoutManager.extraLineFragmentRect.minY }
        let glyph = layoutManager.glyphIndexForCharacter(at: max(0, character))
        return textContainerInset.top + layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
    }
    func visibleCharacter() -> Int? {
        guard textStorage.length > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(for: CGPoint(x: 0, y: max(0, contentOffset.y - textContainerInset.top)), in: textContainer)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }
}

// A single native selectable document: history is protected; only the blue
// tail is editable. Snapshot echoes preserve draft-relative selection.
struct PadTranscript: UIViewRepresentable {
    var messages: [DeviceWireMessage]
    var draft: String
    var images: [String: URL]
    var draftImageHashes: [String] = []
    var editable: Bool
    var lineNumbers: Bool
    var edit: (String) -> Void
    var send: () -> Void
    var attach: (Data) -> Void
    var removeImage: (String) -> Void = { _ in }
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
        c.parent = self; view.send = send; view.removeDraftImage = editable ? removeImage : nil
        if view.isEditable != editable { view.isEditable = editable }
        guard !c.updating else { return }
        view.gutter.isHidden = !lineNumbers
        let leftInset: CGFloat = lineNumbers ? 48 : 10
        if view.textContainerInset.left != leftInset { view.textContainerInset.left = leftInset }
        let imageSignature = Set(messages.flatMap(\.imageHashes) + draftImageHashes).sorted().map { $0 + (images[$0]?.path ?? "") }.joined()
        let visibleMessages = messages.filter { $0.role != "activity" && (!$0.text.isEmpty || !$0.imageHashes.isEmpty) }
        let signature = visibleMessages.map { $0.id.uuidString + $0.role + $0.text + $0.imageHashes.joined() }.joined() + imageSignature + draftImageHashes.joined() + String(lineNumbers)
        view.draftImageButtons.forEach { $0.isHidden = !editable }
        guard signature != c.signature || c.lastDraft != draft else { return }
        // Don't overwrite marked text while dictation/IME is composing.
        if view.markedTextRange != nil { return }
        let previousSelection = view.selectedRange
        let relative = previousSelection.location >= c.historyLength ? previousSelection.location - c.historyLength : nil
        let previousOffset = view.contentOffset.y
        let nearBottom = c.signature.isEmpty || (previousOffset + view.bounds.height >= view.contentSize.height - 80 && !view.isDragging && !view.isDecelerating)
        let visibleCharacter = view.visibleCharacter()
        let visibleDistance = visibleCharacter.map { view.lineTop(at: $0) - previousOffset }
        let anchorMessage = visibleCharacter.flatMap { character in c.messageRanges.last { $0.range.location <= character } }
        let oldRanges = c.messageRanges
        c.messageRanges = []
        c.updating = true

        let result = NSMutableAttributedString()
        view.promptBlocks = []; view.trafficBlocks = []
        for message in visibleMessages {
            let prompt = message.role == "user"
            let color: UIColor = prompt ? .label : .label
            let body = Self.render(message.text)
            let contentLength = TranscriptStyle.blockContentLength(body.string)
            body.deleteCharacters(in: NSRange(location: contentLength, length: body.length - contentLength))
            if body.length == 0 && message.imageHashes.isEmpty { continue }
            if prompt { body.addAttribute(.font, value: UIFont.italicSystemFont(ofSize: 16), range: NSRange(location: 0, length: body.length)) }
            body.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: body.length))
            let start = result.length
            if TranscriptStyle.isTraffic(message.text) { body.addAttribute(.foregroundColor, value: PadPalette.traffic, range: NSRange(location: 0, length: body.length)) }
            result.append(body)
            for hash in message.imageHashes {
                guard let url = images[hash], let image = UIImage(contentsOfFile: url.path) else { continue }
                let attachment = NSTextAttachment(); attachment.image = image
                let maxWidth = max(100, view.bounds.width - 40)
                let ratio = min(1, maxWidth / image.size.width)
                attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * ratio, height: image.size.height * ratio)
                if result.length > 0 && !result.string.hasSuffix("\n") { result.append(Self.separator()) }
                result.append(NSAttributedString(attachment: attachment))
            }
            guard result.length > start else { continue }
            let last = result.length - 1
            let paragraphRange = (result.string as NSString).paragraphRange(for: NSRange(location: last, length: 0))
            let style = ((result.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle) ?? .default).mutableCopy() as! NSMutableParagraphStyle
            style.paragraphSpacing = TranscriptStyle.blockSpacing
            result.append(Self.separator())
            result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: paragraphRange.location, length: result.length - paragraphRange.location))
            let range = NSRange(location: start, length: result.length - start)
            c.messageRanges.append((message.id, range))
            if prompt { view.promptBlocks.append(range) }
            if TranscriptStyle.isTraffic(message.text) { view.trafficBlocks.append(range) }
        }
        view.draftImages = []
        for hash in draftImageHashes {
            guard let url = images[hash], let image = UIImage(contentsOfFile: url.path) else { continue }
            let attachment = NSTextAttachment(); attachment.image = image
            let ratio = min(1, max(100, view.bounds.width - view.textContainerInset.left - view.textContainerInset.right - 10) / image.size.width, 260 / image.size.height)
            attachment.bounds = CGRect(x: 0, y: 0, width: image.size.width * ratio, height: image.size.height * ratio)
            view.draftImages.append((result.length, hash))
            result.append(NSAttributedString(attachment: attachment)); result.append(Self.separator())
        }
        c.historyLength = result.length
        view.historyLength = result.length
        result.append(NSAttributedString(string: draft, attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: PadPalette.draft(draft)]))
        view.textStorage.setAttributedString(result)
        view.configureDraftImageButtons()
        view.typingAttributes = [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: PadPalette.draft(draft), .paragraphStyle: NSParagraphStyle.default]
        if let relative {
            let position = min(result.length, c.historyLength + relative)
            view.selectedRange = NSRange(location: position, length: min(previousSelection.length, result.length - position))
        } else {
            let selectedMessage = oldRanges.last { $0.range.location <= previousSelection.location }
            let moved = selectedMessage.flatMap { old in c.messageRanges.first { $0.id == old.id }.map { $0.range.location - old.range.location } } ?? 0
            let position = max(0, min(result.length, previousSelection.location + moved))
            view.selectedRange = NSRange(location: position, length: min(previousSelection.length, result.length - position))
        }
        if nearBottom { view.pendingViewport = .bottom }
        else if let character = visibleCharacter, let distance = visibleDistance, let old = anchorMessage,
                let new = c.messageRanges.first(where: { $0.id == old.id }) {
            view.pendingViewport = .anchor(new.range.location + min(character - old.range.location, max(0, new.range.length - 1)), distance)
        } else { view.pendingViewport = .offset(previousOffset) }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        c.signature = signature; c.lastDraft = draft
        // History changes invalidate the undo stack's character offsets.
        // Clearing it also prevents undo from modifying protected history.
        view.undoManager?.removeAllActions(); c.updating = false
    }
    static func separator() -> NSAttributedString { NSAttributedString(string: "\n", attributes: [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: UIColor.label]) }
    // UIKit has no NSTextTable. Render tables as wrapping, labelled records
    // so narrow panes remain readable, while keeping the stored Markdown intact.
    static func render(_ text: String) -> NSMutableAttributedString {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let result = NSMutableAttributedString()
        func cells(_ line: String) -> [String] {
            var line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") { line.removeFirst() }; if line.hasSuffix("|") { line.removeLast() }
            var out: [String] = [], value = "", escaped = false, code = false
            for c in line {
                if escaped { value.append(c); escaped = false; continue }
                if c == "\\" { value.append(c); escaped = true; continue }
                if c == "`" { code.toggle() }
                if c == "|" && !code { out.append(value.trimmingCharacters(in: .whitespaces)); value = "" }
                else { value.append(c) }
            }
            out.append(value.trimmingCharacters(in: .whitespaces)); return out
        }
        func append(_ body: NSAttributedString) { result.append(body); result.append(separator()) }
        var i = 0
        while i < lines.count {
            let line = lines[i], trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3)); i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    append(NSAttributedString(string: lines[i], attributes: [.font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: UIColor.label, .backgroundColor: UIColor.quaternarySystemFill])); i += 1
                }
                if i < lines.count { i += 1 }; continue
            }
            if i + 1 < lines.count && cells(line).count > 1 && cells(lines[i + 1]).allSatisfy({ $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }) {
                let headers = cells(line); i += 2
                while i < lines.count && lines[i].contains("|") && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let row = cells(lines[i])
                    for column in headers.indices {
                        let entry = inline(headers[column])
                        entry.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 16), range: NSRange(location: 0, length: entry.length))
                        entry.append(inline(": " + (column < row.count ? row[column] : ""))); append(entry)
                    }
                    append(NSAttributedString(string: "")); i += 1
                }
                continue
            }
            if let match = trimmed.range(of: "^#{1,6} +", options: .regularExpression) {
                let heading = inline(String(trimmed[match.upperBound...]))
                heading.addAttribute(.font, value: UIFont.boldSystemFont(ofSize: 18), range: NSRange(location: 0, length: heading.length)); append(heading)
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                append(inline("• " + trimmed.dropFirst(2)))
            } else { append(inline(line)) }
            i += 1
        }
        if !text.hasSuffix("\n") && result.string.hasSuffix("\n") { result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1)) }
        return result
    }
    static func inline(_ text: String) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        guard let parsed = try? AttributedString(markdown: TranscriptStyle.imageLinks(text), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
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
        var messageRanges: [(id: UUID, range: NSRange)] = []
        init(_ parent: PadTranscript) { self.parent = parent }
        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard !updating, parent.editable else { return false }
            guard range.location >= historyLength else {
                view.selectedRange = NSRange(location: view.textStorage.length, length: 0); return false
            }
            if TailTextView.isReturn(text) {
                // Hardware Command-Return goes through insertText too; use
                // explicit newline action to distinguish it from Send.
                if let tail = view as? TailTextView, tail.insertingNewline || tail.pastingText { return true }
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
            view.typingAttributes = [.font: UIFont.systemFont(ofSize: 16), .foregroundColor: color, .paragraphStyle: NSParagraphStyle.default]
            (view as? TailTextView)?.gutter.setNeedsDisplay()
            parent.edit(text)
        }
    }
}
