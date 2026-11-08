import AppKit
import SwiftUI

/// Per-session automatic transcript trimming. The unit is one message: each
/// prompt (anything Converse delivered as input, including messages from
/// other sessions) and each response counts once, so a prompt/response pair
/// is two. Notices are not counted; they go with the older messages around them.
struct TranscriptLimits: Codable, Equatable {
    var days: Int? = nil
    var count: Int? = 1000
    static let range = 1...1_000_000
    var valid: Bool { [days, count].allSatisfy { $0 == nil || Self.range.contains($0!) } }
    /// Delete a prefix only, retaining the prompt that starts a retained turn.
    func cut(_ messages: [Message], now: Date) -> Int {
        guard valid else { return 0 }
        let counted = messages.indices.filter { ["user", "assistant"].contains(messages[$0].role) }
        var boundary = 0
        if let count, counted.count > count { boundary = counted[counted.count - count] }
        if let days {
            let oldest = now.addingTimeInterval(-Double(days) * 86400)
            // Unknown legacy times are never assumed to be old.
            let ageBoundary = messages.firstIndex { $0.createdAt == nil || $0.createdAt! >= oldest } ?? messages.count
            boundary = max(boundary, ageBoundary)
        }
        if boundary >= messages.count { return messages.count }
        if messages[boundary].role != "user", let prompt = messages[..<boundary].lastIndex(where: { $0.role == "user" }) { boundary = prompt }
        return boundary
    }
    var summary: String {
        let age = days.map { "older than \($0) day" + ($0 == 1 ? "" : "s") }
        let kept = count.map { "beyond the latest \($0.formatted()) message" + ($0 == 1 ? "" : "s") }
        let parts = [age, kept].compactMap { $0 }
        return parts.isEmpty ? "Keeps everything" : "Deletes messages " + parts.joined(separator: " or ")
    }
    static let defaultsKey = "transcriptLimitsDefault"
    /// Self-tests substitute a scratch suite.
    static var defaults = UserDefaults.standard
    /// New sessions start with this (Settings ▸ General). Existing sessions keep their own.
    static var newSessionDefault: TranscriptLimits {
        get { defaults.data(forKey: defaultsKey).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }.flatMap { $0.valid ? $0 : nil } ?? Self() }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey) }
    }
    static let unitExplanation = "Each prompt and each response counts as one message, so a prompt and its response are two. Messages from other sessions count as prompts. Converse notices aren't counted; they go with the older messages around them. A kept response keeps its prompt, so one more message than the limit may stay."
    static let timingExplanation = "Converse checks about a minute after launch and every minute after that. A session is trimmed only while it's idle: no running turn, draft, queued prompts, approval request, provider handoff or unanswered session messages. Message numbers don't change; the oldest kept message keeps its number."
    static let imageExplanation = "Trimming also deletes the images only those messages used, from Converse's own Attachments folder. Images still used by another message, a draft or a queued prompt, and files outside Converse, are never deleted. Trimming runs on the session's home Mac; remote viewers see the result."
}

extension Store {
    /// Why trimming waits for this session, if it must.
    func transcriptTrimBlocker(_ s: Session) -> String? {
        if s.busy || s.compacting || s.changingSetting { return "a turn is running" }
        if !s.draft.isEmpty || !s.attachments.isEmpty { return "it has a draft" }
        if !s.pending.isEmpty { return "prompts are queued" }
        if !s.requests.isEmpty { return "an approval is waiting" }
        if s.handoffPending != nil || s.restoreRetry != nil { return "a provider handoff is pending" }
        if s.switchboardObligations.contains(where: { !$0.terminal }) || s.switchboardExpectations.contains(where: { !$0.answered }) { return "session messages are awaiting replies" }
        return nil
    }
    struct TranscriptTrim: Equatable { var messages = 0; var counted = 0; var images = 0 }
    func trimPreview(_ s: Session, limits: TranscriptLimits, now: Date = Date()) -> TranscriptTrim {
        let removed = s.messages.prefix(limits.cut(s.messages, now: now))
        return TranscriptTrim(messages: removed.count, counted: removed.filter { ["user", "assistant"].contains($0.role) }.count, images: removed.reduce(0) { $0 + $1.images.count })
    }
    /// Removes this session's trimmed prefix in memory and returns its image paths.
    private func removeTrimmedPrefix(_ s: Session, now: Date) -> (count: Int, images: Set<String>) {
        guard transcriptTrimBlocker(s) == nil else { return (0, []) }
        let cut = s.transcriptLimits.cut(s.messages, now: now)
        guard cut > 0 else { return (0, []) }
        let removed = Array(s.messages.prefix(cut))
        let numbers = s.transcriptMessageNumbers()
        let highest = removed.compactMap { numbers[$0.id] }.max()
        s.messages.removeFirst(cut)
        if let highest { s.trimmedMessageNumber = max(s.trimmedMessageNumber, highest) }
        if let marker = s.clearedThroughMessageID, removed.contains(where: { $0.id == marker }) { s.clearedThroughMessageID = nil }
        s.switchboardTurnStart = s.switchboardTurnStart.map { max(0, $0 - cut) }
        return (cut, Set(removed.flatMap(\.images)))
    }
    @discardableResult func trimIdleTranscripts(now: Date = Date(), deleted: ((Int) -> Void)? = nil) -> Int {
        guard !applicationQuitting else { return 0 }
        var removed = 0, images = Set<String>()
        for session in sessions {
            let result = removeTrimmedPrefix(session, now: now)
            removed += result.count; images.formUnion(result.images)
        }
        if removed > 0 { deleteImagesAfterSave(images, deleted: deleted) }
        return removed
    }
    /// Saves the new limits after the human confirms any deletion they cause
    /// now; returns false (nothing saved) when they decline. An idle session
    /// is trimmed at once, otherwise when it next becomes idle.
    @discardableResult func applyTranscriptLimits(_ s: Session, _ limits: TranscriptLimits, now: Date = Date(),
                                                  confirm: (String, String) -> Bool = Store.confirmDeletion, deleted: ((Int) -> Void)? = nil) -> Bool {
        guard limits.valid else { return false }
        let preview = trimPreview(s, limits: limits, now: now)
        if preview.messages > 0 {
            let images = preview.images == 0 ? "" : " and \(preview.images) image\(preview.images == 1 ? "" : "s")"
            let detail = "This deletes \(preview.counted) prompt\(preview.counted == 1 ? "" : "s") and response\(preview.counted == 1 ? "" : "s")\(images) from this Mac's saved transcript" + (transcriptTrimBlocker(s).map { " when the session is idle (now " + $0 + ")" } ?? " now") + ". It can't be undone. The assistant's own provider history isn't changed."
            guard confirm("Delete older messages from “\(s.title)”?", detail) else { return false }
        }
        s.transcriptLimits = limits
        let result = removeTrimmedPrefix(s, now: now)
        if result.count > 0 { deleteImagesAfterSave(result.images, deleted: deleted) } else { save() }
        return true
    }

    /// Images, drafts and queued prompts are kept. Busy sessions are skipped.
    func trimAllImagesPreview(_ targets: [Session]) -> (images: Int, sessions: Int, busy: Int) {
        let live = targets.filter { s in sessions.contains { $0 === s } }
        let busy = live.filter { $0.busy || $0.compacting || $0.changingSetting }
        let images = live.filter { s in !busy.contains { $0 === s } }.reduce(0) { $0 + $1.messages.reduce(0) { $0 + $1.images.count } }
        return (images, live.count, busy.count)
    }
    @discardableResult func trimAllImages(_ targets: [Session], deleted: ((Int) -> Void)? = nil) -> Int {
        var candidates = Set<String>(), removed = 0
        for s in targets where sessions.contains(where: { $0 === s }) && !(s.busy || s.compacting || s.changingSetting) {
            var count = 0
            for index in s.messages.indices where !s.messages[index].images.isEmpty {
                count += s.messages[index].images.count; candidates.formUnion(s.messages[index].images)
                s.messages[index].images = []
                // An image-only message keeps a visible line, so later numbers don't move.
                if Store.visibleText(s.messages[index].text).isEmpty { s.messages[index].text = "[image removed]" }
            }
            guard count > 0 else { continue }
            removed += count
            s.messages.append(Message(role: "notice", text: "Removed \(count) image\(count == 1 ? "" : "s") from this transcript. Your draft and queued prompts keep theirs."))
        }
        if removed > 0 { deleteImagesAfterSave(candidates, deleted: deleted) }
        return removed
    }
    /// Returns false when the human cancels or there is nothing to remove.
    @discardableResult func confirmTrimAllImages(_ targets: [Session], confirm: (String, String) -> Bool = Store.confirmDeletion, deleted: ((Int) -> Void)? = nil) -> Bool {
        let preview = trimAllImagesPreview(targets)
        let live = targets.filter { s in sessions.contains { $0 === s } }
        guard let first = live.first else { return false }
        let scope = live.count == 1 ? "“\(first.title)”" : "\(live.count) sessions"
        guard preview.images > 0 else {
            _ = confirm("No images to trim in " + scope, preview.busy > 0 ? "Sessions with a running turn are skipped; try again when they finish." : "Drafts and queued prompts keep their images."); return false
        }
        let busy = preview.busy == 0 ? "" : " \(preview.busy) busy session\(preview.busy == 1 ? " is" : "s are") skipped."
        guard confirm("Trim all images from \(scope)?", "This removes \(preview.images) image\(preview.images == 1 ? "" : "s") from the transcript and deletes their files from Converse's Attachments folder when nothing else uses them. Text, drafts, queued prompts and files outside Converse are kept. It can't be undone." + busy) else { return false }
        trimAllImages(targets, deleted: deleted)
        return true
    }
    static func confirmDeletion(_ title: String, _ detail: String) -> Bool {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail; alert.alertStyle = .warning
        if title.hasPrefix("No images") { alert.addButton(withTitle: "OK"); alert.runModal(); return false }
        alert.addButton(withTitle: "Cancel")
        let delete = alert.addButton(withTitle: "Delete"); delete.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Image files are deleted only once the trimmed archive is on disk, so a
    /// failed save never leaves restored messages pointing at missing files.
    func deleteImagesAfterSave(_ candidates: Set<String>, deleted: ((Int) -> Void)? = nil) {
        let generation = save()
        guard !candidates.isEmpty else { deleted?(0); return }
        ArchiveWriter.shared.flushThen(folder.path, atLeast: generation) { [weak self] durable in
            guard let self, durable else { deleted?(0); return }
            deleted?(self.deleteUnreferencedImages(candidates))
        }
    }
    /// Every image path and text that may still use a file: live sessions'
    /// messages, drafts, queued prompts and agent art, plus closed sessions
    /// that File ▸ Restore Closed Conversation can bring back.
    func imageReferences() -> (paths: Set<String>, texts: [String]) {
        var paths = Set<String>(), texts: [String] = []
        func prompt(_ p: PendingPrompt) { paths.formUnion(p.images); texts.append(p.text); p.components?.forEach(prompt) }
        func add(_ s: SavedSession) {
            for message in s.messages { paths.formUnion(message.images); texts.append(message.text) }
            paths.formUnion(s.attachments); texts.append(s.draft); s.pending?.forEach(prompt)
            if let art = s.agent?.artPath { paths.insert(art) }
        }
        sessions.forEach { add($0.saved) }
        let closed = folder.appendingPathComponent("Deleted Sessions")
        for file in (try? FileManager.default.contentsOfDirectory(at: closed, includingPropertiesForKeys: nil)) ?? [] {
            guard let data = try? Data(contentsOf: file) else { continue }
            // An unreadable snapshot still protects every path it mentions.
            if let saved = try? JSONDecoder().decode(SavedSession.self, from: data) { add(saved) } else { texts.append(String(decoding: data, as: UTF8.self)) }
        }
        paths.formUnion(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        return (paths, texts.filter { $0.contains("Attachments") })
    }
    /// Deletes regular files inside this profile's Attachments folder that
    /// nothing references. Anything else, including symbolic links and
    /// paths that resolve outside the folder, is left alone.
    @discardableResult func deleteUnreferencedImages(_ candidates: Set<String>) -> Int {
        let fm = FileManager.default
        let root = folder.appendingPathComponent("Attachments").resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let references = imageReferences()
        var deleted = 0
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(root), (try? fm.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeRegular,
                  !references.paths.contains(path), !references.paths.contains(url.standardizedFileURL.path), !references.paths.contains(resolved) else { continue }
            let forms = Set([path, resolved, url.absoluteString, path.replacingOccurrences(of: "/", with: "\\/")])
            guard !references.texts.contains(where: { text in forms.contains { text.contains($0) } }) else { continue }
            if (try? fm.removeItem(atPath: path)) != nil { deleted += 1 }
        }
        return deleted
    }
}

/// One session's limits, from its sidebar menu.
@MainActor enum TranscriptLimitsPanel {
    private static var windows: [UUID: NSWindow] = [:]
    static func show(_ s: Session) {
        if let window = windows[s.id] { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Transcript Limits · " + s.title; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            TranscriptLimitsView(session: s)
            Text(TranscriptLimits.unitExplanation + " " + TranscriptLimits.imageExplanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(width: 480))
        window.center(); window.makeKeyAndOrderFront(nil)
        let id = s.id
        windows[id] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { windows[id] = nil }
        }
    }
}
