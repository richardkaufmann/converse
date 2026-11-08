import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct PadConnect: View {
    @ObservedObject var model: PadModel
    var body: some View { ConverseGroupsView() }
}

struct PadRequest: View {
    let id: String
    let request: DeviceRequestDTO
    @ObservedObject private var service = DeviceSyncService.shared
    @State private var answers: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    var questions: [[String: Any]] { request.questionsJSON.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.kind == "approval" ? "PERMISSION REQUIRED" : "QUESTION FROM HOME", systemImage: "exclamationmark.triangle.fill").font(.headline)
            if request.kind == "approval" {
                if let name = request.toolName { Text(name).bold() }
                if let args = request.rawArgs { Text(args).font(.system(.caption, design: .monospaced)).lineLimit(5).textSelection(.enabled) }
                ForEach(request.choices) { choice in Button(choice.label) { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "answer", requestID: request.id, choiceID: choice.id)) }.buttonStyle(.bordered) }
            } else {
                ForEach(questions.indices, id: \.self) { index in
                    let q = questions[index]
                    let qid = q["id"] as? String ?? String(index)
                    let options = q["options"] as? [[String: Any]] ?? []
                    Text(q["question"] as? String ?? "Question")
                    ForEach(options.indices, id: \.self) { oi in
                        let label = options[oi]["label"] as? String ?? "Option"
                        let selected = selections[qid]?.contains(label) == true
                        Button((selected ? "✓ " : "○ ") + label) {
                            let multiple = (q["selection"] as? [String: Any])?["mode"] as? String == "multiple"
                            if multiple { if selected { selections[qid]?.remove(label) } else { selections[qid, default: []].insert(label) } }
                            else { selections[qid] = [label] }
                        }
                    }
                    TextField("Answer", text: Binding(get: { answers[qid] ?? "" }, set: { answers[qid] = $0 })).textFieldStyle(.roundedBorder)
                }
                Button("Send answers") {
                    var result: [[String: Any]] = []
                    for (index, q) in questions.enumerated() {
                        let key = q["id"] as? String ?? String(index)
                        var answer: [String: Any] = ["questionId": key]
                        let labels = (selections[key] ?? []).sorted()
                        if !labels.isEmpty { answer["selectedLabels"] = labels; if labels.count == 1 { answer["selectedLabel"] = labels[0] } }
                        if let text = answers[key], !text.isEmpty { answer["freeText"] = text }
                        result.append(answer)
                    }
                    let data = try? JSONSerialization.data(withJSONObject: result)
                    service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "answer", requestID: request.id, answersJSON: data))
                }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.yellow.opacity(0.65))
    }
}

struct PadHelp: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let book: HelpBook?
    @StateObject private var videos: HelpVideoPresenter
    init() {
        let book = try? HelpBook.load()
        self.book = book
        _videos = StateObject(wrappedValue: HelpVideoPresenter(videos: book?.videos ?? []))
    }
    var body: some View {
        NavigationStack {
            List {
                Section { Link("GitHub README (sign-in required)", destination: ConverseAbout.readme)
                    Text("This repository is private. Sign into GitHub with an authorized account to open it. The same documentation is available offline below.").font(.caption).foregroundStyle(.secondary) }
                if let book {
                    if let security = book.topics.first(where: { $0.id == "security-and-privacy" }) {
                        NavigationLink("Security and privacy") { ScrollView { Text(security.plainText).textSelection(.enabled).padding() }.navigationTitle("Security and privacy") }
                    }
                    Section { Text("Converse " + ConverseAbout.versionBuild + " · Offline help from the README").font(.caption).foregroundStyle(.secondary) }
                    ForEach(book.search(query)) { topic in
                        NavigationLink(topic.title) {
                            ScrollView {
                                Text((try? AttributedString(markdown: topic.markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(topic.plainText)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                            }.navigationTitle(topic.title).navigationBarTitleDisplayMode(.inline)
                        }
                    }
                    if book.search(query).isEmpty { Text("No matching topics.") }
                } else { Link("Read Converse Help on GitHub", destination: URL(string: "https://github.com/richardkaufmann/converse#readme")!) }
            }.searchable(text: $query, prompt: "Search Help").navigationTitle("Converse Help")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        // Manifest video links play here; every other Help link opens as usual.
        .environment(\.openURL, OpenURLAction { videos.open($0) ? .handled : .systemAction })
        .fullScreenCover(item: $videos.playback) { PadHelpVideo(playback: $0, close: videos.close) }
        .onDisappear(perform: videos.close)
    }
}

// Done, swipe-down and closing Help all clear the presenter's playback, which
// stops it and releases the player. Full screen in every orientation; on a
// landscape phone Done moves to a side rail so the video keeps the height.
struct PadHelpVideo: View {
    @ObservedObject var playback: HelpVideoPlayback
    let close: () -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    var body: some View {
        let rail = verticalSizeClass == .compact
        // AnyLayout keeps the player's identity across rotation: the same
        // AVKit controller and AVPlayer, so position and pause state survive.
        let layout = rail ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        let bar = rail ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            bar {
                if !rail { Text(playback.video.title + " · " + playback.video.durationLabel).font(.headline).lineLimit(1) }
                Spacer(minLength: 0)
                Button("Done", action: close).fontWeight(.semibold)
            }.padding(rail ? .vertical : .horizontal, 12).padding(rail ? .horizontal : .vertical, 10)
                .frame(maxWidth: rail ? nil : .infinity, maxHeight: rail ? .infinity : nil)
            Group {
                if case .failed(let message) = playback.state {
                    VStack(spacing: 14) {
                        Text(message).multilineTextAlignment(.center)
                        Button("Retry") { playback.retry() }.buttonStyle(.borderedProminent)
                        // Opened directly: Help's openURL handler would route it back here.
                        if let url = playback.video.browserURL { Button("Open link") { UIApplication.shared.open(url) } }
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    HelpVideoPlayerView(player: playback.player).overlay { if playback.state == .loading { ProgressView() } }
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { drag in
            if drag.translation.height > 120 && abs(drag.translation.width) < drag.translation.height / 2 { close() }
        })
        .onDisappear(perform: close)
    }
}

// AVKit's own player: scrubbing, AirPlay and aspect-fit, so the whole frame
// shows with black bars instead of being cropped. Picture in Picture stays
// off so dismissing a Help video always ends playback.
struct HelpVideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer?
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.videoGravity = .resizeAspect
        controller.allowsPictureInPicturePlayback = false
        controller.entersFullScreenWhenPlaybackBegins = false
        controller.view.backgroundColor = .black
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) { controller.player = nil }
}

struct PadAbout: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("performanceCapture") private var captureTimings = false
    @State private var timingFile: TimingExportFile?
    @State private var exportTimings = false
    @State private var timingError = ""
    var body: some View {
        NavigationStack {
            Form {
                Section { Text("Converse " + ConverseAbout.versionBuild).font(.headline) }
                Section { Text(ConverseAbout.copyright); Text(ConverseAbout.license); Link("GPLv3 or later · licensing details", destination: ConverseAbout.licenseURL) }
                Section { Link("GitHub README (sign-in required)", destination: ConverseAbout.readme); Link("richard@kaoslabs.app", destination: URL(string: "mailto:richard@kaoslabs.app")!) }
                Section("Performance diagnostics") {
                    Toggle("Record performance timings", isOn: $captureTimings)
                        .onChange(of: captureTimings) { _, enabled in
                            PerformanceCapture.shared.configure(folder: DeviceSyncService.shared.storageFolder, enabled: enabled)
                        }
                    Text("Records timing and counts, including Parking Lot save round trips. No lot text or message contents. Starting a capture replaces the previous capture.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("Export timings…") {
                        PerformanceCapture.shared.prepareExport { url in
                            guard let url else { timingError = "Record some timings first."; return }
                            do { timingFile = TimingExportFile(data: try Data(contentsOf: url)); timingError = ""; exportTimings = true }
                            catch { timingError = error.localizedDescription }
                        }
                    }
                    if !timingError.isEmpty { Text(timingError).font(.footnote).foregroundStyle(.red) }
                }
            }.navigationTitle("About Converse")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .fileExporter(isPresented: $exportTimings, document: timingFile, contentType: .json, defaultFilename: "Converse performance timings") { result in
            if case .failure(let error) = result { timingError = error.localizedDescription }
        }
    }
}
private struct TimingExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct PadRenameSession: View {
    let row: DeviceSidebarRow
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var error = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Session name", text: $name)
                Text("Saves the name on its home for everyone in the group. The current viewer keeps control.").font(.caption)
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Rename session").onAppear { name = row.title }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Rename") {
                            saving = true
                            Task { @MainActor in
                                let result = await DeviceSyncService.shared.renameRemoteSession(row.globalID, title: name)
                                saving = false
                                if result.outcome == "completed" { dismiss() } else { error = result.detail }
                            }
                        }.disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.utf8.count > 200)
                    }
                }
        }
    }
}
