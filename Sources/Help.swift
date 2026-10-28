import AppKit
import SwiftUI

final class HelpViewModel: ObservableObject {
    let book: HelpBook
    @Published var selectedID: String?
    @Published var query = "" {
        didSet { if !matches.contains(where: { $0.id == selectedID }) { selectedID = matches.first?.id } }
    }
    var matches: [HelpTopic] { book.search(query) }
    var selected: HelpTopic? { book.topics.first { $0.id == selectedID } }
    init(book: HelpBook) { self.book = book; selectedID = book.topics.first?.id }
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
    @FocusState private var searchFocused: Bool
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
                    HelpText(markdown: topic.markdown, query: model.query).frame(minWidth: 360)
                } else {
                    Text("No Help topics match your search.").foregroundStyle(.secondary).frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.onAppear { searchFocused = true }
    }
}

struct HelpText: NSViewRepresentable {
    let markdown: String
    let query: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 600)); scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let text = NSTextView(frame: scroll.contentView.bounds); text.isEditable = false; text.isSelectable = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 18, height: 16)
        text.usesFindBar = true; text.setAccessibilityLabel("Help article")
        scroll.documentView = text; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
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
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var markdown: String?; var query: String? }
}
