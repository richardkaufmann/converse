import AppKit
import WebKit

func transcriptExportSelfTests(_ check: (Bool, String) -> Void) {
    let entry = Entry(name: "Offline model", command: "unused", directory: NSTemporaryDirectory(), engine: "codex")
    let first = Session(entry: entry), second = Session(entry: entry)
    first.title = "Alpha <safe>"; second.title = "Beta"
    let later = Date(timeIntervalSince1970: 200), earlier = Date(timeIntervalSince1970: 100)
    first.messages = [Message(role: "user", text: "Prompt alpha <script>alert(1)</script>", createdAt: later),
                      Message(role: "assistant", text: "# Heading\n**Bold** and *italic* and [link](https://example.com)\n\n| Column | Value |\n| --- | --- |\n| One | Two |\n\n```swift\nlet x = \"<tag>\"\n```\n- First item", images: ["fixture.png"], createdAt: later)]
    first.draft = "DO NOT EXPORT DRAFT"
    first.messages.append(Message(role: "activity", text: "DO NOT EXPORT TOOL", createdAt: earlier))
    second.messages = [Message(role: "user", text: "Prompt beta", createdAt: earlier), Message(role: "assistant", text: "Legacy reply", createdAt: nil)]
    let sessions = [ExportSession(first), ExportSession(second)]
    let chronological = TranscriptExport.items(sessions: sessions, order: .interleaved, content: .both)
    check(chronological.map { $0.message.text }.first == "Prompt beta" && chronological.last?.message.text == "Legacy reply" && chronological.count == 4, "Export interleaves recorded times stably and keeps untimed legacy messages explicit")
    let sequential = TranscriptExport.items(sessions: sessions, order: .sequential, content: .both)
    check(sequential.map { $0.session.id } == [first.id, first.id, second.id, second.id], "Sequential export keeps each session together in recorded message order")
    check(TranscriptExport.items(sessions: sessions, order: .interleaved, content: .prompts).allSatisfy { $0.message.role == "user" } && TranscriptExport.items(sessions: sessions, order: .sequential, content: .responses).count == 2, "Export Prompts and Responses filters exclude the other role and tool activity")
    let selection = TranscriptExportSelection(sessions: sessions)
    selection.format = .text
    check(selection.lineNumbers && selection.format == .text && TranscriptExportFormat.text.fileName("Project.v1.html") == "Project.v1.txt" && TranscriptExportFormat.html.fileName("Project.v1.txt") == "Project.v1.html", "Text format preserves the HTML line-number preference and updates filename extensions without losing dotted names")
    selection.selected = [second.id]
    check(selection.chosen.map(\.id) == [second.id] && selection.includesUntimedMessages, "Export subset selects only checked sessions and flags missing historical times")
    let legacy = try! JSONDecoder().decode(Message.self, from: Data("{\"id\":\"\(UUID().uuidString)\",\"role\":\"assistant\",\"text\":\"old\",\"images\":[]}".utf8))
    let roundTrip = try! JSONDecoder().decode(Message.self, from: JSONEncoder().encode(first.messages[0]))
    check(legacy.createdAt == nil && roundTrip.createdAt == later, "Message dates persist without inventing dates for legacy archives")
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZ1kAAAAASUVORK5CYII=")!
    // Hold actual preparation at its image loader until a main-queue callback
    // runs. This catches accidental main-actor inheritance, without relying on
    // a machine-speed threshold for regex/JSON work.
    var prepared: ConverseExportPreparation.Output?, preparationError: Error?
    var finished = false, mainResponded = false
    let preparing = Task { @MainActor in
        do {
            prepared = try await ConverseExportPreparation.prepare(sessions: sessions, content: .both,
                context: ExportScrubber.Context(), includeImages: true, images: [:],
                attachmentRoot: Store.shared.folder.appendingPathComponent("Attachments"), app: .current,
                imageData: { _ in
                    let gate = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { mainResponded = true; gate.signal() }
                    return gate.wait(timeout: .now() + 2) == .success ? png : nil
                })
        } catch { preparationError = error }
        finished = true
    }
    let preparationDeadline = Date().addingTimeInterval(10)
    while !finished && Date() < preparationDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    preparing.cancel()
    let package = prepared.flatMap { try? ConverseExchange.decode($0.data) }
    check(finished && preparationError == nil && mainResponded && package?.document.sessions.count == 2 && package?.document.attachments.count == 1,
          "Converse export prepares scrubbed sessions and attachments while the main queue remains responsive")
    var cancellationFinished = false, cancelled = false
    var cancelling: Task<Void, Never>?
    cancelling = Task { @MainActor in
        do {
            _ = try await ConverseExportPreparation.prepare(sessions: sessions, content: .both, context: nil,
                includeImages: true, images: [:], attachmentRoot: Store.shared.folder, app: .current,
                imageData: { _ in
                    let gate = DispatchSemaphore(value: 0)
                    DispatchQueue.main.async { cancelling?.cancel(); gate.signal() }
                    _ = gate.wait(timeout: .now() + 2)
                    return png
                })
        } catch is CancellationError { cancelled = true }
        catch { }
        cancellationFinished = true
    }
    let cancellationDeadline = Date().addingTimeInterval(10)
    while !cancellationFinished && Date() < cancellationDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    cancelling?.cancel()
    check(cancellationFinished && cancelled, "Cancelling a Converse export interrupts background preparation and returns no document")
    do {
        let lot = ParkingLotStore(folder: Store.shared.folder.appendingPathComponent("Outline Export QA"))
        let heading = ParkingLotRow(heading: true, text: "Plan <safe>", notes: [ParkingLotNote(author: "Reviewer", text: "Heading note")])
        let parent = ParkingLotRow(heading: false, text: "First **bold** item", notes: [ParkingLotNote(author: "Author", text: "Write to test@example.com")], parentID: heading.id)
        let child = ParkingLotRow(heading: false, text: "Nested [link](https://example.com)", images: ["fixture.png"], done: true, parentID: parent.id)
        lot.openStarter([heading, parent, child])
        let exportedLot = ExportSession(lot: lot)
        let lotController = TranscriptExportController(sessions: [exportedLot], lotOnly: true)
        lotController.configurePanel()
        let lotSelection = lotController.selection
        check(lotSelection.lotOnly && lotSelection.chosen.map(\.id) == [lot.id] && !lotSelection.lineNumbers
              && !lotSelection.limitDates && !lotSelection.includeHandoffs && lotSelection.content == .both
              && lotController.panel.title == "Export Parking Lot" && lotController.panel.nameFieldStringValue == "Parking Lot.html",
              "Lot menu export fixes scope to this whole lot and configures a compact lot-named save panel")
        lotSelection.format = .converse
        check(lotSelection.scrub && !lotSelection.exportsImages, "Lot Converse export defaults to scrubbing with images omitted")
        lotSelection.scrub = false; lotSelection.scrubChosen = true; lotSelection.format = .html
        check(!lotSelection.scrub && lotSelection.exportsImages, "Lot export respects the explicit scrub choice across formats")
        check(!TranscriptExportSelection(sessions: sessions).lotOnly, "Conversation exports retain their full selection controls")
        let outline = try TranscriptExport.html(sessions: [exportedLot], order: .sequential, content: .both, lineNumbers: true, imageData: { _ in png })
        check(outline.contains("<ol type=\"1\">") && outline.contains("<ol type=\"a\">")
              && outline.contains("<p class=\"lot-comment\"><em>Reviewer: Heading note</em></p>")
              && outline.contains("lot-text done") && outline.contains("Plan &lt;safe&gt;")
              && !outline.contains("class=\"ln\"") && !outline.contains("<article") && outline.contains("data:image/png;base64,"),
              "Lot HTML is a semantic nested outline with italic owned comments, Done styling and images, without transcript cards or gutters")
        let excluded = try TranscriptExport.html(sessions: [exportedLot], order: .sequential, content: .both, lineNumbers: false, includeImages: false, imageData: { _ in png })
        check(!excluded.contains("<img") && !excluded.contains("Attached image unavailable"), "Exclude images also excludes structured lot images and placeholders")
        var scrubber = ExportScrubber(context: ExportScrubber.Context())
        let sanitized = exportedLot.scrubbed(&scrubber, includeImages: false, structuredLots: true)
        let safe = try TranscriptExport.html(sessions: [sanitized], order: .sequential, content: .both, lineNumbers: true)
        check(!safe.contains("test@example.com") && !safe.contains("fixture.png") && !safe.contains("<img"),
              "Structured lot exports scrub comments and never fall back to the original unsanitized rows")
        let mixed = try TranscriptExport.html(sessions: [exportedLot] + sessions, order: .interleaved, content: .both, lineNumbers: true)
        check(mixed.components(separatedBy: "<section class=\"parking-lot\">").count == 2
              && mixed.contains("class=\"ln\"") && mixed.contains("<article class=\"message"),
              "Mixed interleaved exports render each lot once while retaining conversation cards and line numbers")
        try outline.write(to: Store.shared.folder.appendingPathComponent("ParkingLotQA.html"), atomically: true, encoding: .utf8)
        let plain = try TranscriptExport.text(sessions: sessions, order: .interleaved, content: .responses)
        check(plain.contains("**Bold**") && plain.contains("[Attached image: fixture.png]") && plain.contains("Time unavailable") && !plain.contains("Prompt beta") && !plain.contains("<article") && !plain.contains("class=\"ln\"") && !plain.contains("DO NOT EXPORT"), "Text export preserves original Markdown and image labels with no HTML, generated line numbers, prompts or private drafts")
        let textFile = Store.shared.folder.appendingPathComponent("ExportQA.txt")
        try plain.write(to: textFile, atomically: true, encoding: .utf8)
        check(try String(contentsOf: textFile, encoding: .utf8) == plain, "Text export writes a standalone UTF-8 file")
        let html = try TranscriptExport.html(sessions: sessions, order: .interleaved, content: .both, lineNumbers: true, imageData: { _ in png })
        check(html.contains("<strong>Bold</strong>") && html.contains("<table>") && html.contains("<code>") && html.contains("<h1>Heading</h1>") && html.contains("https://example.com"), "Export preserves emphasis, headings, code, tables and clickable links")
        check(html.contains("data:image/png;base64,") && !html.contains("fixture.png") && html.contains("Time unavailable"), "Export embeds attachments into one portable file and labels unknown message times")
        check(!html.contains("<script>") && html.contains("&lt;script&gt;") && !html.contains("DO NOT EXPORT") && html.contains("default-src 'none'"), "Export escapes user HTML, blocks active content and excludes drafts and tools")
        let noNumbers = try TranscriptExport.html(sessions: sessions, order: .sequential, content: .responses, lineNumbers: false)
        check(!noNumbers.contains("class=\"ln\"") && !noNumbers.contains("Prompt alpha") && noNumbers.contains("Attached image unavailable"), "Export line numbers can be omitted and missing images are described visibly")
        let file = Store.shared.folder.appendingPathComponent("ExportQA.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        check(try String(contentsOf: file, encoding: .utf8) == html, "Formatted export writes a complete standalone UTF-8 file")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 960, height: 1100))
        web.loadHTMLString(html, baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while web.isLoading && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        var dom: [String: Any]?
        web.evaluateJavaScript("({messages:document.querySelectorAll('article.message').length, bold:document.querySelector('strong').textContent, cells:document.querySelectorAll('table tr').length, scripts:document.scripts.length, blue:getComputedStyle(document.querySelector('.prompt .ln')).backgroundColor,white:getComputedStyle(document.querySelector('.response .ln')).backgroundColor})") { value, _ in dom = value as? [String: Any] }
        while dom == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        check(dom?["messages"] as? Int == 4 && dom?["bold"] as? String == "Bold" && dom?["cells"] as? Int == 2 && dom?["scripts"] as? Int == 0 && dom?["blue"] as? String == "rgb(224, 238, 255)" && dom?["white"] as? String == "rgb(255, 255, 255)", "WebKit renders the standalone export with formatted content and blue/white line-number gutters")
    } catch { check(false, "Transcript export failed: " + error.localizedDescription) }
    check((try? TranscriptExport.html(sessions: [], order: .sequential, content: .both, lineNumbers: true)) == nil, "Empty exports report an actionable error")
}
