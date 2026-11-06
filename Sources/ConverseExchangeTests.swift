import AppKit
import SwiftUI

func converseExchangeSelfTests(_ check: (Bool, String) -> Void) {
    exportScrubberSelfTests(check)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-exchange-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1kAAAAASUVORK5CYII=")!
    // Source profile: a session with an image, an agent transcript and a lot.
    let source = Store(folder: root.appendingPathComponent("source"))
    let sourceLibrary = ParkingLotLibrary(folder: source.folder)
    let entry = Entry(name: "Claude", command: "unused", directory: NSTemporaryDirectory(), engine: "claude")
    let chat = source.create(entry); chat.title = "Framework"
    let imagePath = source.folder.appendingPathComponent("Attachments/" + chat.id.uuidString + "/Screenshot.png")
    try? FileManager.default.createDirectory(at: imagePath.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? png.write(to: imagePath)
    let when = Date(timeIntervalSince1970: 1_800_000_000.25)
    chat.messages = [Message(role: "user", text: "How do we plan?", images: [imagePath.path], createdAt: when),
                     Message(role: "assistant", text: "Use **headings**.\n![chart](file:///tmp/private.png)", createdAt: nil),
                     Message(role: "activity", text: "DO NOT EXPORT TOOL"), Message(role: "notice", text: "DO NOT EXPORT NOTICE")]
    chat.draft = "DO NOT EXPORT DRAFT"
    let agent = source.create(Entry(name: "Agent", command: "", directory: NSTemporaryDirectory(), engine: "agent"))
    agent.title = "Steward"; agent.agent = AgentConfig(); agent.agent?.objective = "SECRET OBJECTIVE"
    agent.messages = [Message(role: "assistant", text: "Weekly summary")]
    let lot: ParkingLotStore
    do { lot = try sourceLibrary.create(name: "Ideas") } catch { check(false, "Exchange fixture lot: " + error.localizedDescription); return }
    let lotImage = lot.attachmentFolder.appendingPathComponent("Pasted.png")
    try? FileManager.default.createDirectory(at: lot.attachmentFolder, withIntermediateDirectories: true)
    try? png.write(to: lotImage)
    let heading = ParkingLotRow(heading: true, text: "Plans", done: true)
    let item = ParkingLotRow(heading: false, text: "Ship import", editedBy: "Reviewer", notes: [ParkingLotNote(author: "Reviewer", text: "Looks right")], images: [lotImage.path], done: false, tag: .blue)
    do { try lot.replaceUserRows([heading, item], revision: lot.document.revision) } catch { check(false, "Exchange fixture rows: " + error.localizedDescription) }
    let exportSessions = [ExportSession(chat), ExportSession(agent), ExportSession(lot: lot)]
    check(exportSessions[1].isAgent && exportSessions[2].lotDocument?.rows.count == 2, "Export keeps agent kind and the lot's own rows")
    let images: (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    var noScrub: ExportScrubber? = nil
    let data: Data
    do { data = try ConverseExchange.export(exportSessions, content: .both, scrubber: &noScrub, includeImages: true, imageData: images, now: when) }
    catch { check(false, "Converse export failed: " + error.localizedDescription); return }
    let json = String(decoding: data, as: UTF8.self)
    check(json.contains("\"format\":\"converse-export\"") && json.contains("\"version\":1") && json.contains("\"platform\":\"macOS\"") && json.contains("\"kind\":\"agent\""), "Converse export writes the documented header and agent kind")
    check(!json.contains("DO NOT EXPORT") && !json.contains("SECRET OBJECTIVE") && !json.contains(NSTemporaryDirectory()) && !json.contains(imagePath.path), "Converse export excludes drafts, tool activity, notices, agent configuration and local paths")
    let package: ConverseExchange.Package
    do { package = try ConverseExchange.decode(data) } catch { check(false, "Converse decode failed: " + error.localizedDescription); return }
    check(package.document.parkingLots.first?.document.rows.last?.tag == .blue, "Color tags survive Converse package export and decode")
    let key = DeviceBlob.sha256Hex(png)
    check(package.document.sessions.count == 2 && package.document.parkingLots.count == 1 && package.document.attachments.keys.sorted() == [key] && package.images[key] != nil && !package.document.scrub.applied, "Converse export round-trips sessions, lots and one de-duplicated verified image")
    check(package.document.sessions[0].messages.count == 2 && ConverseExchange.date(package.document.sessions[0].messages[0].createdAt) == when && package.document.sessions[0].messages[1].createdAt == nil, "Message times round-trip; unknown legacy times stay unknown")

    let review = ConverseImportSelection(package: package, fileName: "Shared.converse")
    let reviewView = NSHostingView(rootView: ConverseImportView(selection: review, cancel: {}, confirm: {}))
    reviewView.frame = NSRect(x: 0, y: 0, width: 540, height: 470); reviewView.layoutSubtreeIfNeeded()
    check(review.chosen == 3 && review.selectionState == .on && review.scrubSummary.contains("without removing") && reviewView.fittingSize.height > 200, "The import review lists every session and lot, selected by default, with the scrub status")
    review.toggleAll()
    check(review.chosen == 0 && review.selectionState == .off, "The import review can clear its selection")
    // Import into a different profile.
    let target = Store(folder: root.appendingPathComponent("target"))
    let library = ParkingLotLibrary(folder: target.folder)
    let existing = target.create(entry); existing.title = "Framework"
    let all = Set(package.document.sessions.map(\.exportID)), lots = Set(package.document.parkingLots.map(\.exportID))
    do {
        let result = try target.importConverse(package, sessions: all, lots: lots, library: library)
        let imported = result.sessions
        check(imported.count == 2 && imported.allSatisfy { $0.isUnboundImport && $0.agent == nil && $0.importedTranscriptPending && !$0.started && $0.remoteID == nil } && !all.contains(imported[0].id), "Imported sessions get fresh IDs and are not bound to any provider; agents import as plain sessions")
        check(imported[0].title == "Framework (imported)" && imported[1].title == "Steward" && existing.title == "Framework" && existing.messages.isEmpty, "Title clashes get an imported suffix and never merge into an existing session")
        let first = imported[0]
        check(first.messages.map(\.role) == ["user", "assistant"] && first.messages[0].text == "How do we plan?" && first.messages[0].createdAt == when, "Imported transcript keeps roles, text and times")
        check(first.messages[0].images.count == 1 && first.messages[0].images[0].hasPrefix(target.folder.appendingPathComponent("Attachments/" + first.id.uuidString).path) && FileManager.default.contents(atPath: first.messages[0].images[0]) != nil, "Imported images are stored with the new session")
        check(first.messages[1].text.contains("[chart](file:///tmp/private.png)") && !first.messages[1].text.contains("![chart]"), "Imported local image embeds become plain links, so no local file is captured")
        check(target.importResponseImages(first) == false, "Imported text cannot pull files from this Mac into the transcript")
        let reloaded = Store(folder: target.folder)
        check(reloaded.sessions.contains { $0.id == first.id && $0.isUnboundImport && $0.importedTranscriptPending && $0.messages.count == 2 }, "Unbound imported sessions survive relaunch")
        let newLot = result.lots.first
        check(newLot != nil && newLot!.id != lot.id && newLot!.name == "Ideas" && library.records.contains { $0.id == newLot!.id }, "Parking Lots import as new lots with fresh lot IDs")
        let rows = newLot?.document.rows ?? []
        check(rows.map(\.id) == [heading.id, item.id] && rows[0].isDone && !rows[1].isDone && rows[1].notes == item.notes && rows[1].editedBy == "Reviewer", "Imported lot rows keep IDs, Done state, notes and editors")
        check(rows[1].images?.count == 1 && rows[1].images![0].hasPrefix(newLot!.attachmentFolder.path) && FileManager.default.contents(atPath: rows[1].images![0]) != nil, "Imported lot images move into the new lot's attachments")
        let again = try target.importConverse(package, sessions: all, lots: lots, library: library)
        let third = try target.importConverse(package, sessions: all, lots: lots, library: library)
        check(again.sessions[0].title == "Framework (imported 2)" && again.sessions[1].title == "Steward (imported)" && again.lots[0].name == "Ideas (imported)" && third.lots[0].name == "Ideas (imported 2)", "Repeated imports get distinct names and never merge")
        do { _ = try target.importConverse(package, sessions: [], lots: [], library: library); check(false, "Empty import selection rejected") }
        catch { check(error.localizedDescription.contains("Select at least one"), "An empty import selection explains itself") }

        // Unbound until a provider is chosen; the draft is kept.
        var asked: Session?
        target.chooseImportProvider = { asked = $0 }
        first.draft = "Continue from here"
        target.submit(first)
        check(asked === first && first.draft == "Continue from here" && first.messages.count == 2 && !first.busy, "Sending in an unbound import opens the provider picker and keeps the draft")
        target.chooseImportProvider = nil
        target.submit(first)
        check(first.messages.last?.text == Store.importProviderNotice && first.draft == "Continue from here", "Without a picker, an unbound import explains why nothing was sent")
        first.messages.removeLast()
        target.refreshStatus(first)
        check(!first.probingStatus, "Unbound imports never probe a provider")
        check(!target.assistantFamilies.contains(ConverseExchange.unboundEngine), "The new-session menu never offers the unbound placeholder as a provider")
        if let command = ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"], let profile = target.preferredLogin(engine: "muse") {
            let echo = Entry(name: "Echo", command: command, directory: NSTemporaryDirectory(), engine: "muse")
            check(target.bindImportedSession(first, entry: echo, profile: profile) && !first.isUnboundImport && first.entry.engine == "muse" && first.entry.accountID == profile.id, "Choosing a provider binds the imported session without losing its history")
            let draft = first.draft
            check(draft.hasPrefix(RestoreContext.framing) && draft.hasSuffix(RestoreContext.separator + "Continue from here") && !first.busy && first.messages.count == 2, "Binding fills in the catch-up draft before the kept draft and sends nothing")
            target.send(first)
            let deadline = Date().addingTimeInterval(20)
            while first.busy && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            let file = target.handoffTranscriptURL(first)
            let markdown = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let reply = first.messages.last { $0.role == "assistant" }?.text ?? ""
            check(markdown.contains("How do we plan?") && markdown.contains("Use **headings**.") && markdown.contains("## Prompt") && file.path == target.folder.appendingPathComponent("Handoffs/" + first.id.uuidString + "/transcript.md").path, "Binding an import writes the transcript to Handoffs/<session-id>/transcript.md")
            check(reply.contains("Full transcript: " + file.path) && reply.contains("Continue from here") && !reply.contains(ConverseExchange.preface(path: file.path)) && first.messages.contains { $0.role == "user" && $0.text == draft }, "The first prompt is the visible catch-up draft pointing at the transcript; no hidden preface")
            check(!first.importedTranscriptPending, "No transcript preface is left pending")
            first.draft = "Second prompt"; target.send(first)
            let second = Date().addingTimeInterval(20)
            while first.busy && Date() < second { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            check(first.messages.last { $0.role == "assistant" }?.text.contains("[Converse: this conversation was imported") == false, "Later prompts are sent without the preface")
        } else { check(false, "Imported session send test needs the echo provider") }
    } catch { check(false, "Converse import failed: " + error.localizedDescription) }

    // Future row fields decode; this build ignores keys it does not know.
    if var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], var lotsJSON = object["parkingLots"] as? [[String: Any]],
       var document = lotsJSON.first?["document"] as? [String: Any], var rows = document["rows"] as? [[String: Any]] {
        rows[1]["parentID"] = heading.id.uuidString; rows[1]["siblingOrder"] = 3
        document["rows"] = rows; lotsJSON[0]["document"] = document; object["parkingLots"] = lotsJSON
        let future = try? ConverseExchange.decode(JSONSerialization.data(withJSONObject: object))
        check(future?.document.parkingLots.first?.document.rows.map(\.id) == [heading.id, item.id], "Lot rows with future fields (parent ID, sibling order) still import with the store's own decoder")
        var lotV2 = lotsJSON; var docV2 = document; docV2["schemaVersion"] = ConverseExchange.supportedLotSchemaVersion + 1; lotV2[0]["document"] = docV2; object["parkingLots"] = lotV2
        do { _ = try ConverseExchange.decode(JSONSerialization.data(withJSONObject: object)); check(false, "Newer Parking Lot schema rejected") }
        catch { check(error.localizedDescription.contains("newer Parking Lot format"), "A lot with a newer schemaVersion is refused instead of dropping its fields") }
        docV2["schemaVersion"] = 1; lotV2[0]["document"] = docV2; object["parkingLots"] = lotV2
        check((try? ConverseExchange.decode(JSONSerialization.data(withJSONObject: object))) != nil, "schemaVersion 1 lots import")
        docV2["schemaVersion"] = ConverseExchange.supportedLotSchemaVersion; lotV2[0]["document"] = docV2; object["parkingLots"] = lotV2
        check((try? ConverseExchange.decode(JSONSerialization.data(withJSONObject: object))) != nil, "Lots at the current schemaVersion (nested) import")
        object["parkingLots"] = lotsJSON
        object["version"] = 2
        do { _ = try ConverseExchange.decode(JSONSerialization.data(withJSONObject: object)); check(false, "Newer version rejected") }
        catch { check(error.localizedDescription.contains("newer version of Converse"), "A newer export version is rejected with an update message") }
        object["version"] = 1; object["format"] = "something-else"
        do { _ = try ConverseExchange.decode(JSONSerialization.data(withJSONObject: object)); check(false, "Unknown format rejected") }
        catch { check(error.localizedDescription.contains("isn’t a Converse export"), "An unknown format is rejected clearly") }
        object["format"] = ConverseExchange.format
        if var attachments = object["attachments"] as? [String: Any], var image = attachments[key] as? [String: Any] {
            image["data"] = Data("not the image".utf8).base64EncodedString(); attachments[key] = image; object["attachments"] = attachments
            do { _ = try ConverseExchange.decode(JSONSerialization.data(withJSONObject: object)); check(false, "Tampered image rejected") }
            catch { check(error.localizedDescription.contains("integrity"), "Attachment hashes are verified before anything is imported") }
        } else { check(false, "Attachment fixture") }
    } else { check(false, "Future row fixture") }
    for (bad, label) in [(Data("not json".utf8), "Non-JSON files are rejected"), (Data("{\"format\":\"converse-export\",\"version\":1}".utf8), "Truncated exports are rejected")] {
        do { _ = try ConverseExchange.decode(bad); check(false, label) } catch { check(true, label) }
    }
    do { _ = try ConverseExchange.decode(Data(count: ConverseExchange.maxFileBytes + 1)); check(false, "Oversized file rejected") }
    catch { check(error.localizedDescription.contains("200 MB"), "Files over 200 MB are rejected before parsing") }
    func limited(_ sessions: [ConverseExchange.SessionRecord], lots: [ConverseExchange.LotRecord] = []) -> Data {
        let document = ConverseExchange.Document(format: ConverseExchange.format, version: 1, exportedAt: "2026-11-05T00:00:00Z", app: .init(version: "x", build: "1", platform: "macOS"),
                                                 scrub: .init(applied: false, counts: [:]), sessions: sessions, parkingLots: lots, attachments: [:])
        return (try? JSONEncoder().encode(document)) ?? Data()
    }
    let empty = { ConverseExchange.SessionRecord(exportID: UUID(), title: "S", provider: "P", engine: "claude", kind: "session", messages: []) }
    let tooMany = limited((0...ConverseExchange.maxSessions).map { _ in empty() })
    check((try? ConverseExchange.decode(tooMany)) == nil, "More than 500 sessions are rejected")
    var long = empty(); long.messages = Array(repeating: .init(role: "user", text: "x", createdAt: nil, images: []), count: ConverseExchange.maxMessages + 1)
    check((try? ConverseExchange.decode(limited([long]))) == nil && (try? ConverseExchange.decode(limited([empty()]))) != nil, "Sessions over 20,000 messages are rejected")
    let lots51 = (0...ConverseExchange.maxLots).map { _ in ConverseExchange.LotRecord(exportID: UUID(), name: "L", document: ParkingLotDocument()) }
    check((try? ConverseExchange.decode(limited([], lots: lots51))) == nil, "More than 50 Parking Lots are rejected")
    check(ConverseExchange.cleanName("A\u{202E}gnp.exe\nB\t", limit: 120, fallback: "x") == "A gnp.exe B" && ConverseExchange.cleanName(" \n", limit: 10, fallback: "Untitled") == "Untitled" && ConverseExchange.cleanName(String(repeating: "a", count: 300), limit: 120, fallback: "") .count == 120, "Imported names are single-line, bounded and free of direction overrides")

    // Scrubbing during export.
    let context = ExportScrubber.Context(homePath: "/Users/casey", fullName: "Casey Example", accountName: "casey", devices: [])
    var scrubber: ExportScrubber? = ExportScrubber(context: context)
    chat.messages = [Message(role: "user", text: "Mail casey.example@example.com from /Users/casey/notes with key sk-ant-api03-abcdefghijklmnopqrstuvwx", images: [imagePath.path])]
    do {
        let scrubbed = try ConverseExchange.decode(ConverseExchange.export([ExportSession(chat), ExportSession(lot: lot)], content: .both, scrubber: &scrubber, includeImages: false, imageData: images))
        let text = scrubbed.document.sessions[0].messages[0].text
        check(text == "Mail [email 1] from ~/notes with key [secret]" && scrubbed.document.sessions[0].messages[0].images.isEmpty && scrubbed.document.attachments.isEmpty && scrubbed.document.parkingLots[0].document.rows[1].images == nil, "Scrubbed Converse exports replace secrets and personal info and leave images out by default")
        check(scrubbed.document.scrub.applied && scrubbed.document.scrub.counts["email"] == 1 && scrubbed.document.scrub.counts["secret"] == 1 && scrubbed.document.scrub.counts["path"] == 1, "The export records what scrubbing removed")
    } catch { check(false, "Scrubbed export: " + error.localizedDescription) }
    var htmlScrubber = ExportScrubber(context: context)
    let cleanSession = ExportSession(chat).scrubbed(&htmlScrubber, includeImages: false)
    check(cleanSession.messages[0].text.contains("[email 1]") && cleanSession.messages[0].images.isEmpty && ((try? TranscriptExport.text(sessions: [cleanSession], order: .sequential, content: .both)) ?? "").contains("[secret]"), "HTML and Text exports can scrub too")
    let selection = TranscriptExportSelection(sessions: [ExportSession(chat)])
    check(!selection.scrub && selection.exportsImages, "HTML export starts unscrubbed with images")
    selection.format = .converse
    check(selection.scrub && !selection.exportsImages && TranscriptExportFormat.converse.fileName("Shared.html") == "Shared.converse", "The Converse format scrubs by default and leaves images out unless included")
    selection.includeImages = true; selection.imagesChosen = true
    check(selection.exportsImages, "Include images (not scrubbed) puts images back")
    selection.scrub = false; selection.scrubChosen = true; selection.format = .html; selection.format = .converse
    check(!selection.scrub, "A deliberate scrub choice survives format changes")
    selection.format = .text
    check(!selection.exportsImages, "Text exports never carry images")
    let plain = TranscriptExportSelection(sessions: [ExportSession(chat)])
    plain.includeImages = false; plain.imagesChosen = true
    check(!plain.exportsImages, "Include images can be turned off for an unscrubbed HTML export")

    // Date range: only messages sent inside the window; untimed messages are left out; lots stay whole.
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let timed = Session(entry: Entry(name: "Claude", command: "claude", directory: "~", engine: "claude"))
    timed.messages = [Message(role: "user", text: "early", createdAt: base),
                      Message(role: "assistant", text: "middle", createdAt: base.addingTimeInterval(3600)),
                      Message(role: "user", text: "untimed", createdAt: nil),
                      Message(role: "assistant", text: "late", createdAt: base.addingTimeInterval(7200))]
    let ranged = TranscriptExportSelection(sessions: [ExportSession(timed)])
    check(ranged.windowed(ExportSession(timed)).messages.count == 4, "Without a date range every message is exported")
    ranged.limitDates = true; ranged.startDate = base.addingTimeInterval(1800); ranged.endDate = base.addingTimeInterval(5400)
    check(ranged.windowed(ExportSession(timed)).messages.map(\.text) == ["middle"], "A date range keeps only messages inside it and drops untimed ones")
    ranged.startDate = base; ranged.endDate = base.addingTimeInterval(7200)
    check(ranged.windowed(ExportSession(timed)).messages.map(\.text) == ["early", "middle", "late"], "Date range bounds are inclusive")
    ranged.endDate = base.addingTimeInterval(-60)
    check(!ranged.validDateRange, "A start after the end is invalid")
    var lotSession = ExportSession(timed); lotSession.isParkingLot = true
    ranged.endDate = base.addingTimeInterval(1)
    check(ranged.windowed(lotSession).messages.count == 4, "Parking Lots are exported whole, whatever the date range")
}

func exportScrubberSelfTests(_ check: (Bool, String) -> Void) {
    let deviceID = String(repeating: "ab12", count: 16)
    let context = ExportScrubber.Context(homePath: "/Users/casey", fullName: "Casey Example", accountName: "casey",
                                         devices: [ExportScrubber.Device(id: deviceID, names: ["Studio Mac Pro"])])
    func scrub(_ text: String) -> String { var s = ExportScrubber(context: context); return s.scrub(text) }
    let positives: [(String, String, String)] = [
        ("-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----", "[secret]", "PEM private keys"),
        ("key sk-ant-api03-abcdefghijklmnopqrstuvwx", "key [secret]", "Anthropic keys"),
        ("key sk-proj-abcdefghijklmnopqrstuvwx1234", "key [secret]", "OpenAI project keys"),
        ("key sk-abcdefghijklmnopqrstuvwx1234", "key [secret]", "OpenAI keys"),
        ("ghp_abcdefghijklmnopqrstuvwxyz0123456789 and gho_abcdefghijklmnopqrstuvwxyz0123456789 and ghs_abcdefghijklmnopqrstuvwxyz0123456789", "[secret] and [secret] and [secret]", "GitHub tokens"),
        ("github_pat_11ABCDEFG0abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ", "[secret]", "GitHub fine-grained tokens"),
        ("xoxb-1234567890-abcdefghij", "[secret]", "Slack tokens"),
        ("AKIAIOSFODNN7EXAMPLE", "[secret]", "AWS access key IDs"),
        ("AIzaSyA1234567890abcdefghijklmnopqrstuv", "[secret]", "Google API keys"),
        ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "[secret]", "JWTs"),
        ("Authorization: Bearer abc123def456ghi789jkl", "Authorization: Bearer [secret]", "Bearer tokens"),
        ("MTA4NjE0NjY5MjQ5NzQ1MDk2NQ.GhXyZa.abcdefghijklmnopqrstuvwxyz0123456", "[secret]", "Discord bot tokens"),
        ("https://discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz0123456789ABCD", "https://discord.com/api/webhooks/[discord 1]/[secret]", "Discord webhook tokens"),
        ("password = hunter22\nAPI_KEY: \"abcd efgh\"\ndb_passwd='opensesame'", "password = [secret]\nAPI_KEY: [secret]\ndb_passwd=[secret]", "Password, secret, token and API key assignments"),
        ("value Xk9Lm2Pq8Rt5Vw3Yz7Ab4Cd6Ef1Gh0JkQ end", "value [secret] end", "Long high-entropy strings"),
        ("Write to casey.example@example.com or CASEY.EXAMPLE@example.com, then bob@example.org", "Write to [email 1] or [email 1], then [email 2]", "Emails, numbered consistently"),
        ("Call (415) 555-0132 or +44 20 7946 0958 or 415.555.0132", "Call [phone 1] or [phone 2] or [phone 1]", "Phone numbers"),
        ("Hosts 192.168.1.20, 10.0.0.5 and fe80::1ff:fe23:4567:890a", "Hosts [ip 1], [ip 2] and [ip 3]", "IPv4 and IPv6 addresses"),
        ("Open /Users/casey/Developer/app", "Open ~/Developer/app", "Home folder paths"),
        ("Signed, Casey Example (casey)", "Signed, [name] ([user])", "Full name and account name"),
        ("Studio Mac Pro is " + deviceID + " (" + String(deviceID.prefix(16)).uppercased() + ")", "[device 1] is [device 1] ([device 1])", "This Group's device names and IDs"),
        ("ssh caseys-mbp.local", "ssh [host 1]", ".local host names"),
        ("See https://discord.com/channels/123456789012345678/876543210987654321", "See https://discord.com/channels/[discord 1]/[discord 2]", "Discord IDs in Discord links"),
    ]
    for (input, expected, label) in positives {
        let output = scrub(input)
        check(output == expected, "Scrubber removes " + label + (output == expected ? "" : " · got: " + output))
    }
    let negatives: [(String, String)] = [
        ("Commit 9008238 and da8d8be0f1c2a3b4c5d6e7f8091a2b3c4d5e6f70 merged", "git SHAs"),
        ("Digest 3f2a9c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80", "SHA-256 digests"),
        ("Session 3F2504E0-4F89-11D3-9A0C-0305E82C3301 and 123e4567-e89b-12d3-a456-426614174000", "UUIDs"),
        ("Release 0.6.4 build 129 shipped on 2026-11-05 at 10:30:45 to localhost and 127.0.0.1.", "versions, dates, times and loopback"),
        ("The token is in the keychain; set max_tokens: 4096 and password: required. Use the secret sauce.", "ordinary prose about tokens and passwords"),
        ("Use std::vector and TranscriptExportSelectionController for the UI.", "code identifiers"),
        ("Clone git@github.com:richardkaufmann/converse.git into ~/Developer", "git remotes"),
        ("Visit https://example.com/docs?page=2#intro for 42 examples.", "ordinary links and numbers"),
        ("Attached Screenshot-3F2504E0-4F89-11D3-9A0C-0305E82C3301.png from Attachments/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789/x", "attachment names and path segments"),
    ]
    for (input, label) in negatives {
        let output = scrub(input)
        check(output == input, "Scrubber keeps " + label + (output == input ? "" : " · got: " + output))
    }
    var counted = ExportScrubber(context: context)
    _ = counted.scrub("a@example.com b@example.com sk-ant-api03-abcdefghijklmnopqrstuvwx")
    _ = counted.scrub("a@example.com again")
    check(counted.counts["email"] == 3 && counted.counts["secret"] == 1 && counted.scrub("c@example.com") == "[email 3]", "Scrubber counts every replacement and numbers consistently across one export")
    check(ExportScrubber.describe(counted.counts).hasPrefix("Removed 1 secret, 4 email addresses") && ExportScrubber.describe([:]) == "Nothing was found to remove.", "Scrub summary names each category")
}
