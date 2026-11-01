import AppKit
import SwiftUI

@MainActor func textSubstitutionSelfTests(_ check: (Bool, String) -> Void) {
    for (token, replacement) in TextSubstitutions.replacements {
        let input = "🦊 hello " + token + " "
        let match = TextSubstitutions.match(in: input, caret: input.utf16.count)
        check(match.map { (input as NSString).replacingCharacters(in: $0.range, with: $0.replacement) } == "🦊 hello " + replacement + " ", "Substitution preserves Unicode offsets and space: " + token)
    }
    for literal in ["word:-) ", "https://example.com/:-) ", "`hello :-) ", "``hello :-) ", "`` ` hello :-) ", "````\n```\n:-) ", "```swift\n:-) ", "~~~\n--> ", "    :-) ", "\t--> ", "/help :-) ", "$ echo :-) ", ":-)"] {
        check(TextSubstitutions.match(in: literal, caret: literal.utf16.count) == nil, "Substitution leaves code/command/token literal: " + literal.debugDescription)
    }
    check(TextSubstitutions.match(in: "```\ncode\n```\n:-) ", caret: "```\ncode\n```\n:-) ".utf16.count) != nil, "Substitution resumes after a closed code fence")
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("substitution-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let preferences = TextSubstitutions(folder: folder)
    check(preferences.enabled, "Substitutions default on in a new isolated profile")
    try! preferences.setEnabled(false)
    check(!TextSubstitutions(folder: folder).enabled, "Substitution preference survives reopening")
    let shared = TextSubstitutions.shared, original = TextSubstitutions.shared.enabled
    defer { try? shared.setEnabled(original) }
    try! shared.setEnabled(true)
    let session = Session(entry: Entry(name: "Substitution fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex"))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    let text = ConversationTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
    window.contentView = text; text.allowsUndo = true; text.isRichText = false
    let coordinator = ScrollingConversation.Coordinator(session)
    text.delegate = coordinator; coordinator.render(text)
    func type(_ value: String) { for ch in value { text.insertText(String(ch), replacementRange: text.selectedRange()) } }
    text.setSelectedRange(NSRange(location: text.inputStart, length: 0))
    type("Hello :-) ")
    check(session.draft == "Hello 🙂 ", "Native prompt substitutes a typed token")
    text.undo(nil)
    check(session.draft == "Hello :-) " && text.substitutionFeedback.offersDisable(shared), "Undo restores exact typed prompt and offers disabling")
    text.redo(nil)
    check(session.draft == "Hello 🙂 ", "Redo restores prompt substitution")
    session.messages.append(Message(role: "assistant", text: "New streaming output")); coordinator.render(text)
    text.undo(nil)
    check(session.draft == "Hello :-) " && text.string.contains("New streaming output"), "Substitution Undo survives transcript growth without changing history")
    text.redo(nil)
    text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
    type("--> "); text.deleteBackward(nil)
    check(session.draft == "Hello 🙂 --> ", "Immediate Backspace reverses substitution including the trigger space")
    try! shared.setEnabled(false)
    check(!text.substitutionFeedback.offersDisable(shared), "Changing preference dismisses the old rejection hint")
    type(":-) ")
    check(session.draft.hasSuffix(":-) "), "Disabled substitutions leave typed characters literal")
    try! shared.setEnabled(true)
    let lot = ParkingLotStore(folder: folder.appendingPathComponent("lot")); lot.open()
    let editor = ParkingLotEditor.Coordinator(ParkingLotEditor(lot: lot, collapsed: .constant([]), reorder: {}))
    let outline = ParkingOutlineText(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    outline.isRichText = false; outline.owner = editor; outline.delegate = editor; editor.text = outline; editor.render()
    let row = lot.document.rows[1]
    lot.update(row.id, text: "Idea"); editor.render()
    let range = editor.projection.entries.first { $0.row.id == row.id }!.range
    outline.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
    for ch in " :-) " { outline.insertText(String(ch), replacementRange: outline.selectedRange()) }
    check(lot.document.rows.first { $0.id == row.id }?.text == "Idea 🙂 ", "Parking Lot typing substitutes without changing row identity")
    outline.undo(nil)
    check(lot.document.rows.first { $0.id == row.id }?.text == "Idea :-) " && lot.substitutionFeedback.offersDisable(shared), "Parking Lot Undo restores literal token and offers disabling")
    outline.redo(nil)
    check(lot.document.rows.first { $0.id == row.id }?.text == "Idea 🙂 ", "Parking Lot Redo restores substitution")
    check(outline.undoManager?.undoActionName == TextSubstitutions.undoName, "Parking Lot Redo keeps the substitution Undo action")
    session.supportTeachingVersion = AppSupport.version
    let store = Store.shared
    let result = try? store.appSupportResult(AppSupportCommand(action: "set-substitutions", enabled: false), session: session, openUI: false)
    check(result?.contains("now off") == true && !shared.enabled, "Taught Support agent can turn substitutions off")
    _ = try? store.appSupportResult(AppSupportCommand(action: "set-substitutions", enabled: true), session: session, openUI: false)
    check(shared.enabled && (try? store.appSupportResult(AppSupportCommand(action: "set-substitutions"), session: session, openUI: false)) == nil, "Support agent can enable substitutions and rejects a missing boolean")
}
