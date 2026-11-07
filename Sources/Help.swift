import AppKit
import AVKit
import SwiftUI

final class HelpViewModel: ObservableObject {
    let book: HelpBook
    let videos: HelpVideoPresenter
    @Published var selectedID: String?
    @Published var query = "" {
        didSet { if !matches.contains(where: { $0.id == selectedID }) { selectedID = matches.first?.id } }
    }
    var matches: [HelpTopic] { book.search(query) }
    var selected: HelpTopic? { book.topics.first { $0.id == selectedID } }
    init(book: HelpBook) { self.book = book; videos = HelpVideoPresenter(videos: book.videos ?? []); selectedID = book.topics.first?.id }
}

final class HelpSearchItem: NSObject {
    let topic: HelpTopic
    init(_ topic: HelpTopic) { self.topic = topic }
}

final class ConverseHelpController: NSObject, NSUserInterfaceItemSearching {
    let model: HelpViewModel
    private var window: NSWindow?
    override init() {
        let fallback = HelpBook(schemaVersion: 1, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", appBuild: "", sourceCommit: "", title: "Converse Help", sourceURL: "https://github.com/richardkaufmann/converse", sourceSHA256: "", topics: [HelpTopic(id: "unavailable", title: "Help unavailable", markdown: "This copy does not include offline Help. [Read the documentation on GitHub](https://github.com/richardkaufmann/converse).", plainText: "Help unavailable")])
        model = HelpViewModel(book: (try? HelpBook.load()) ?? fallback)
        super.init()
    }
    func show(topic: String? = nil, query: String? = nil) {
        if let query { model.query = query }
        if let topic { model.selectedID = topic }
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 700), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "Converse Help"; created.isReleasedWhenClosed = false
            created.contentMinSize = NSSize(width: 680, height: 440)
            created.contentView = NSHostingView(rootView: ConverseHelpView(model: model))
            created.setFrameAutosaveName("ConverseHelp"); created.center(); window = created
            // Closing Help with a video sheet up must not leave it playing.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: created, queue: .main) { [model] _ in
                MainActor.assumeIsolated { model.videos.close() }
            }
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func searchForItems(withSearch searchString: String, resultLimit: Int, matchedItemHandler handleMatchedItems: @escaping ([Any]) -> Void) {
        handleMatchedItems(model.book.search(searchString, limit: resultLimit).map(HelpSearchItem.init))
    }
    func localizedTitles(forItem item: Any) -> [String] {
        guard let item = item as? HelpSearchItem else { return [] }
        return ["Converse Help", item.topic.title]
    }
    func performAction(forItem item: Any) {
        guard let item = item as? HelpSearchItem else { return }
        DispatchQueue.main.async { self.show(topic: item.topic.id, query: "") }
    }
    func showAllHelpTopics(forSearch searchString: String) {
        DispatchQueue.main.async { self.show(query: searchString) }
    }
}

struct ConverseHelpView: View {
    @ObservedObject var model: HelpViewModel
    @ObservedObject private var videos: HelpVideoPresenter
    @FocusState private var searchFocused: Bool
    init(model: HelpViewModel) { self.model = model; videos = model.videos }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
                Text(model.book.appVersion).font(.caption).foregroundStyle(.secondary)
                TextField("Search Help", text: $model.query).textFieldStyle(.roundedBorder).focused($searchFocused).accessibilityLabel("Search Help")
                Button { searchFocused = true } label: { Image(systemName: "magnifyingglass") }.keyboardShortcut("f", modifiers: .command).help("Search Help")
                if let url = URL(string: model.book.sourceURL) { Link("GitHub README", destination: url) }
            }.padding(12)
            Divider()
            HSplitView {
                List(selection: $model.selectedID) {
                    ForEach(model.matches) { topic in Text(topic.title).tag(topic.id) }
                }.frame(minWidth: 180, idealWidth: 220, maxWidth: 330).accessibilityLabel("Help topics")
                if let topic = model.selected {
                    HelpText(markdown: topic.markdown, query: model.query, videos: videos).frame(minWidth: 360)
                } else {
                    Text("No Help topics match your search.").foregroundStyle(.secondary).frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.onAppear { searchFocused = true }
            .sheet(item: $videos.playback) { HelpVideoSheet(playback: $0, close: videos.close) }
    }
}

// In-app player for manifest videos. Done, Escape and closing Help all clear
// the presenter's playback, which stops it and releases the player.
struct HelpVideoSheet: View {
    @ObservedObject var playback: HelpVideoPlayback
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(playback.video.title).font(.headline)
                Text(playback.video.durationLabel).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
            }
            if case .failed(let message) = playback.state {
                VStack(spacing: 12) {
                    Text(message).multilineTextAlignment(.center).textSelection(.enabled)
                    HStack {
                        Button("Retry") { playback.retry() }.keyboardShortcut(.defaultAction)
                        if let url = playback.video.browserURL { Button("Open link") { NSWorkspace.shared.open(url) }.help(url.absoluteString) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HelpPlayerView(player: playback.player).overlay { if playback.state == .loading { ProgressView() } }
            }
        }.padding(14).frame(minWidth: 640, idealWidth: 960, minHeight: 420, idealHeight: 600)
            .onDisappear(perform: close)
    }
}

struct HelpPlayerView: NSViewRepresentable {
    let player: AVPlayer?
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .inline; view.player = player; return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) { view.player = nil }
}

struct HelpText: NSViewRepresentable {
    let markdown: String
    let query: String
    let videos: HelpVideoPresenter
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 600)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let text = NSTextView(frame: scroll.contentView.bounds); text.isEditable = false; text.isSelectable = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 18, height: 16)
        text.usesFindBar = true; text.setAccessibilityLabel("Help article"); text.delegate = context.coordinator
        scroll.documentView = text; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.videos = videos
        guard let text = scroll.documentView as? NSTextView, context.coordinator.markdown != markdown || context.coordinator.query != query else { return }
        context.coordinator.markdown = markdown; context.coordinator.query = query
        let content = MarkdownText.render(markdown), string = content.string as NSString
        var firstMatch: NSRange?
        for word in [query.trimmingCharacters(in: .whitespacesAndNewlines)] where !word.isEmpty {
            var location = 0
            while location < string.length {
                let found = string.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: NSRange(location: location, length: string.length - location))
                guard found.location != NSNotFound, found.length > 0 else { break }
                content.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.28), range: found)
                if firstMatch == nil { firstMatch = found }
                location = NSMaxRange(found)
            }
        }
        text.textStorage?.setAttributedString(content)
        text.scrollRangeToVisible(firstMatch ?? NSRange(location: 0, length: 0))
    }
    func makeCoordinator() -> Coordinator { Coordinator(videos: videos) }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var markdown: String?; var query: String?; var videos: HelpVideoPresenter
        init(videos: HelpVideoPresenter) { self.videos = videos }
        // Manifest video links play in Help; every other link opens as usual.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            return videos.open(url)
        }
    }
}

@MainActor func helpVideoSelfTests(_ check: (Bool, String) -> Void) {
    let media = "https://github.com/richardkaufmann/converse/releases/download/help-videos/fixture-v1.mp4"
    let video = HelpVideo(id: "fixture", title: "Fixture", durationSeconds: 2, mediaURL: media, watchURL: "https://example.com/watch/fixture", sha256: String(repeating: "0", count: 64), description: "Fixture", recordedWith: "Test")
    let others = ["https://github.com/richardkaufmann/converse#readme", media + "?X-Amz-Signature=abc", "http://github.com/richardkaufmann/converse/releases/download/help-videos/fixture-v1.mp4", media.replacingOccurrences(of: "-v1", with: "-v2"), "converse-help://first-launch"]
    check(HelpVideo.route(URL(string: media)!, in: [video]) == video && HelpVideo.route(URL(string: "https://GitHub.com/richardkaufmann/converse/releases/download/help-videos/fixture-v1.mp4#t=3")!, in: [video]) == video && HelpVideo.route(URL(string: "https://example.com/watch/fixture")!, in: [video]) == video, "Help routes manifest media and watch URLs to the video player")
    check(others.allSatisfy { HelpVideo.route(URL(string: $0)!, in: [video]) == nil }, "Help leaves README, signed, insecure, other-version and Help links alone")
    check(video.durationLabel == "2 s" && HelpVideo(id: "x", title: "x", durationSeconds: 125.4, mediaURL: media, sha256: "", description: "", recordedWith: "").durationLabel == "2 min 5 s", "Help video durations read as seconds or minutes")
    let offline = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)])
    let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse)
    check(HelpVideoPlayback.message(for: offline).contains("offline") && !HelpVideoPlayback.message(for: refused).contains("offline"), "Help says offline only for a not-connected network error")
    if let book = try? HelpBook.load() {
        let first = book.videos?.first { $0.id == "first-run" }
        let topic = book.topics.first { $0.id == "videos" }
        check(first != nil && topic?.markdown.contains(first?.mediaURL ?? "-") == true && book.topics.first { $0.id == "first-launch" }?.markdown.contains(first?.mediaURL ?? "-") == true, "Offline Help carries the video manifest, a Videos topic and the First launch link")
    }

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("converse-help-video-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = folder.appendingPathComponent("fixture-v1.mp4")
    do { try HelpVideoFixture.writeMP4(to: fixture) } catch { check(false, "Help video fixture writes: \(error.localizedDescription)") }
    let presenter = HelpVideoPresenter(videos: [video]) { _ in fixture }
    let coordinator = HelpText.Coordinator(videos: presenter), text = NSTextView()
    check(!coordinator.textView(text, clickedOnLink: URL(string: others[0])!, at: 0) && presenter.playback == nil, "Help hands non-video links to normal link handling")
    func wait(_ done: () -> Bool) { let end = Date().addingTimeInterval(10); while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } }
    var playback: HelpVideoPlayback?
    weak var released: AVPlayer?, item: AVPlayerItem?
    // AVFoundation autoreleases the player while creating it. The app's event
    // loop drains that pool; this command-line test drains its own.
    autoreleasepool {
        check(coordinator.textView(text, clickedOnLink: media, at: 0) && presenter.playback?.video == video, "Clicking a manifest video link in Help opens the player")
        playback = presenter.playback
        wait { playback?.state == .ready && (playback?.player?.rate ?? 0) > 0 }
        check(playback?.state == .ready && (playback?.player?.rate ?? 0) > 0, "Help plays a local MP4 through the same player path")
        released = playback?.player; item = released?.currentItem
        presenter.close()
    }
    wait { released == nil }
    check(presenter.playback == nil && playback?.player == nil && released == nil && item == nil, "Dismissing the Help video stops playback and releases the player")
    let missing = HelpVideoPresenter(videos: [video]) { _ in folder.appendingPathComponent("missing-v1.mp4") }
    _ = missing.open(URL(string: media)!)
    wait { if case .failed = missing.playback?.state { return true }; return false }
    if case .failed(let message) = missing.playback?.state { check(!message.contains("offline") && missing.playback?.player == nil && missing.playback?.video.browserURL != nil, "A failed Help video offers Retry and Open link without claiming to be offline") }
    else { check(false, "A missing Help video reports a failure") }
    missing.close()
}
