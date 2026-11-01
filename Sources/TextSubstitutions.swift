import AppKit
import SwiftUI

final class TextSubstitutions: ObservableObject {
    static let shared = TextSubstitutions(folder: Store.shared.folder)
    @Published private(set) var enabled: Bool
    @Published private(set) var generation = 0
    private let file: URL
    init(folder: URL) {
        file = folder.appendingPathComponent("text-substitutions.json")
        enabled = (try? JSONDecoder().decode(Bool.self, from: Data(contentsOf: file))) ?? true
    }
    func setEnabled(_ value: Bool) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
        enabled = value; generation += 1
    }
    func changeFromUI(_ value: Bool) {
        do { try setEnabled(value) } catch { NSAlert(error: error).runModal() }
    }
    static let undoName = "Text Substitution"
    static let replacements = [":-)":"🙂", ":)":"🙂", ":-(":"🙁", ":(":"🙁", ";-)":"😉", ";)":"😉",
        ":-D":"😃", ":D":"😃", ":-P":"😛", ":P":"😛", "-->":"→", "<--":"←", "<-->":"↔",
        "==>":"⇒", "<==":"⇐", "<==>":"⇔", "<->":"↔", "...":"…", "(c)":"©", "(r)":"®", "(tm)":"™"]
    struct Match { let range: NSRange; let replacement: String }
    // Only a standalone token followed by a typed space. Never guess at prose
    // inside Markdown code, indentation, command lines, URLs or larger tokens.
    static func match(in text: String, caret: Int) -> Match? {
        let source = text as NSString
        guard caret > 0, caret <= source.length, source.substring(with: NSRange(location: caret - 1, length: 1)) == " " else { return nil }
        let prefix = source.substring(to: caret - 1)
        var fence: Character?, fenceLength = 0
        let lines = prefix.components(separatedBy: .newlines)
        for line in lines.dropLast() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = trimmed.first!
                let length = trimmed.prefix { $0 == marker }.count
                if fence == nil { fence = marker; fenceLength = length }
                else if marker == fence && length >= fenceLength { fence = nil }
            }
        }
        guard fence == nil, let line = lines.last else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("    "), !line.hasPrefix("\t"), !trimmed.hasPrefix("/"), !trimmed.hasPrefix("$"),
              !trimmed.hasPrefix("```"), !trimmed.hasPrefix("~~~"),
              !hasOpenInlineCode(line) else { return nil }
        let token = line.components(separatedBy: .whitespaces).last ?? ""
        guard let replacement = replacements[token] else { return nil }
        return Match(range: NSRange(location: caret - 1 - (token as NSString).length, length: (token as NSString).length), replacement: replacement)
    }
    private static func hasOpenInlineCode(_ line: String) -> Bool {
        let characters = Array(line)
        var index = 0, delimiter = 0
        while index < characters.count {
            if characters[index] == "\\" && delimiter == 0 { index += 2; continue }
            guard characters[index] == "`" else { index += 1; continue }
            var end = index
            while end < characters.count && characters[end] == "`" { end += 1 }
            let length = end - index
            if delimiter == 0 { delimiter = length } else if delimiter == length { delimiter = 0 }
            index = end
        }
        return delimiter != 0
    }
}

final class SubstitutionFeedback: ObservableObject {
    @Published private(set) var rejectedGeneration: Int?
    func rejected() { rejectedGeneration = TextSubstitutions.shared.generation }
    func offersDisable(_ preferences: TextSubstitutions) -> Bool { rejectedGeneration == preferences.generation }
}

struct SubstitutionButton: View {
    @ObservedObject var preferences = TextSubstitutions.shared
    @ObservedObject var feedback: SubstitutionFeedback
    var body: some View {
        if !preferences.enabled || feedback.offersDisable(preferences) {
            Button(preferences.enabled ? "Turn off substitutions" : "Turn on substitutions") {
                preferences.changeFromUI(!preferences.enabled)
            }.font(.system(size: 12)).buttonStyle(.bordered)
                .help("Change typed-text substitutions for this Mac app. Existing text stays unchanged.")
        }
    }
}

// Remember only the most recent substitution for immediate Backspace reversal.
// An intervening edit or caret move makes normal Backspace behavior win.
struct ImmediateSubstitution {
    let text: String
    let caret: NSRange
    func matches(_ view: NSTextView, start: Int = 0) -> Bool {
        let source = view.string as NSString
        guard start <= source.length else { return false }
        return source.substring(from: start) == text && view.selectedRange() == NSRange(location: start + caret.location, length: caret.length)
    }
}
