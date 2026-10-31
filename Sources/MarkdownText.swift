import AppKit

// Native attributed text only: no HTML import, JavaScript, remote images or web view.
// Source stays untouched for persistence, streaming and CLI context.
struct MarkdownText {
    static let font = NSFont.systemFont(ofSize: 16)
    static func inline(_ source: String, bold: Bool = false) -> NSMutableAttributedString {
        let output = NSMutableAttributedString(string: "")
        guard let parsed = try? AttributedString(markdown: TranscriptStyle.imageLinks(source), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSMutableAttributedString(string: source, attributes: [.font: font, .foregroundColor: NSColor.textColor])
        }
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var selectedFont = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) : font
            var traits: NSFontTraitMask = []
            if bold || intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
            selectedFont = NSFontManager.shared.convert(selectedFont, toHaveTrait: traits)
            var attributes: [NSAttributedString.Key: Any] = [.font: selectedFont, .foregroundColor: NSColor.textColor]
            if intent.contains(.code) { attributes[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.10) }
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link, ["https", "http", "converse-help"].contains(link.scheme ?? "") { attributes[.link] = link }
            output.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return output
    }
    // render() terminates a partial final line with a synthetic newline.
    // That terminator is not part of the prefix inside the full document.
    static func renderedOffset(in source: String, utf16Offset: Int) -> Int {
        let offset = min(max(0, utf16Offset), (source as NSString).length)
        guard offset > 0 else { return 0 }
        let prefix = (source as NSString).substring(to: offset)
        let rendered = render(prefix)
        return max(0, rendered.length - (prefix.last?.isNewline == true || !rendered.string.hasSuffix("\n") ? 0 : 1))
    }
    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }; if text.hasSuffix("|") { text.removeLast() }
        var result = [String](); var current = ""; var escaped = false; var code = false
        for character in text {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if character == "`" { code.toggle() }
            if character == "|" && !code { result.append(current.trimmingCharacters(in: .whitespaces)); current = "" }
            else { current.append(character) }
        }
        result.append(current.trimmingCharacters(in: .whitespaces)); return result
    }
    static func tableDivider(_ line: String) -> Bool {
        let values = cells(line)
        return values.count > 1 && values.allSatisfy { $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
    }
    static func render(_ source: String) -> NSMutableAttributedString {
        let output = NSMutableAttributedString(string: "")
        // Homes on Windows can send CRLF, and older sources may use CR.
        // Normalize only for display so table dividers and fences see the
        // same line boundaries; stored/copyable source remains untouched.
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2; paragraph.paragraphSpacing = 0
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
        func append(_ body: NSAttributedString, style: NSParagraphStyle = paragraph) {
            let line = NSMutableAttributedString(attributedString: body)
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            output.append(line); output.append(NSAttributedString(string: "\n", attributes: base.merging([.paragraphStyle: style]) { _, new in new }))
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if i == lines.count - 1 && line.isEmpty { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3)); i += 1
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    append(NSAttributedString(string: lines[i], attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.textColor, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.10)]))
                    i += 1
                }
                if i < lines.count { i += 1 }; continue
            }
            if i + 1 < lines.count && line.contains("|") && tableDivider(lines[i + 1]) {
                var rows = [cells(line)]; let alignments = cells(lines[i + 1]); i += 2
                while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty && lines[i].contains("|") { rows.append(cells(lines[i])); i += 1 }
                let columns = rows[0].count
                let table = NSTextTable(); table.numberOfColumns = columns; table.layoutAlgorithm = .automatic; table.collapsesBorders = true; table.hidesEmptyCells = false
                table.setContentWidth(100, type: .percentageValueType)
                for (rowIndex, row) in rows.enumerated() {
                    for column in 0..<columns {
                        let block = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1, startingColumn: column, columnSpan: 1)
                        block.setBorderColor(.separatorColor); block.setWidth(0.5, type: .absoluteValueType, for: .border)
                        block.setWidth(4, type: .absoluteValueType, for: .padding)
                        if rowIndex == 0 { block.backgroundColor = .controlBackgroundColor }
                        let style = paragraph.mutableCopy() as! NSMutableParagraphStyle; style.textBlocks = [block]
                        if column < alignments.count {
                            let alignment = alignments[column]
                            if alignment.hasPrefix(":"), alignment.hasSuffix(":") { style.alignment = .center }
                            else if alignment.hasSuffix(":") { style.alignment = .right }
                        }
                        append(inline(column < row.count ? row[column] : "", bold: rowIndex == 0), style: style)
                    }
                }
                if i >= lines.count - 1 { output.append(NSAttributedString(string: "\n", attributes: base)) }
                continue
            }
            if let match = trimmed.range(of: "^#{1,6}\\s+", options: .regularExpression) {
                let level = trimmed[match].filter { $0 == "#" }.count
                let title = String(trimmed[match.upperBound...]).replacingOccurrences(of: "\\s+#+$", with: "", options: .regularExpression)
                let body = inline(title, bold: true)
                body.addAttribute(.font, value: NSFont.systemFont(ofSize: level == 1 ? 21 : level == 2 ? 19 : 17, weight: .semibold), range: NSRange(location: 0, length: body.length))
                append(body); i += 1; continue
            }
            if i + 1 < lines.count && !trimmed.isEmpty && lines[i + 1].range(of: "^\\s*(={3,}|-{3,})\\s*$", options: .regularExpression) != nil {
                append(inline(line, bold: true)); i += 2; continue
            }
            if trimmed.range(of: "^([-*_])(?:\\s*\\1){2,}$", options: .regularExpression) != nil {
                append(NSAttributedString(string: "────────────────────", attributes: [.font: font, .foregroundColor: NSColor.separatorColor])); i += 1; continue
            }
            var content = line
            let style = paragraph.mutableCopy() as! NSMutableParagraphStyle
            if let marker = content.range(of: "^\\s*[-+*]\\s+", options: .regularExpression) {
                let prefix = String(content[..<marker.upperBound]); let depth = prefix.prefix { $0 == " " }.count
                content = String(repeating: "  ", count: depth / 2) + "• " + content[marker.upperBound...]
                style.headIndent = CGFloat(18 + depth * 4)
            } else if content.range(of: "^\\s*\\d+[.)]\\s+", options: .regularExpression) != nil { style.headIndent = 22 }
            if let quote = content.range(of: "^\\s*>\\s?", options: .regularExpression) {
                content = String(content[quote.upperBound...]); style.firstLineHeadIndent = 14; style.headIndent = 14
            }
            append(inline(content), style: style); i += 1
        }
        return output
    }
}
