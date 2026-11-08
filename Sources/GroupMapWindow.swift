import AppKit
import WebKit

enum GroupMapResources {
    static let scheme = "converse-group-map"
    static let d3File = "d3.v7.9.0.min.js"
    static let d3Version = "7.9.0"
    static let d3SHA256 = "f2094bbf6141b359722c4fe454eb6c4b0f0e42cc10cc7af921fc158fceb86539"
    static var folder: URL? { Bundle.main.resourceURL?.appendingPathComponent("GroupMap") }
    static let pages: [String: String] = [
        "/group-map.html": "text/html", "/group-map.css": "text/css",
        "/group-map.js": "text/javascript", "/" + d3File: "text/javascript"
    ]
}

/// Serves exactly the bundled page. The web view has no file access and every
/// other URL fails here, so the page cannot reach anything else.
final class GroupMapSchemeHandler: NSObject, WKURLSchemeHandler {
    private(set) var served: [String] = []
    private(set) var refused: [String] = []
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == GroupMapResources.scheme, url.host == "app",
              let type = GroupMapResources.pages[url.path], let folder = GroupMapResources.folder,
              let data = try? Data(contentsOf: folder.appendingPathComponent(String(url.path.dropFirst()))),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type, "Cache-Control": "no-store"]) else {
            refused.append(task.request.url?.absoluteString ?? "")
            task.didFailWithError(URLError(.unsupportedURL)); return
        }
        served.append(url.path)
        task.didReceive(response); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

private final class GroupMapScriptProxy: NSObject, WKScriptMessageHandler {
    weak var page: GroupMapPage?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) { page?.receive(message.body) }
}

/// The web view plus its one-way bridge. Native data arrives only through
/// GroupMap.apply; the page may report only that it is ready or has failed.
final class GroupMapPage: NSObject, WKNavigationDelegate {
    private static let handlerName = "groupMap"
    let webView: WKWebView
    let schemes = GroupMapSchemeHandler()
    private let proxy = GroupMapScriptProxy()
    var onReady: (() -> Void)?
    private(set) var isReady = false
    private(set) var errors: [String] = []
    private(set) var refusedNavigations: [String] = []

    init(frame: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemes, forURLScheme: GroupMapResources.scheme)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(proxy, name: Self.handlerName)
        webView = WKWebView(frame: frame, configuration: configuration)
        super.init()
        proxy.page = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
    }
    func load() { webView.load(URLRequest(url: URL(string: GroupMapResources.scheme + "://app/group-map.html")!)) }
    fileprivate func receive(_ body: Any) {
        guard let message = body as? [String: Any], let type = message["type"] as? String else { return }
        if type == "ready" { isReady = true; onReady?() }
        if type == "error" { errors.append(String((message["message"] as? String ?? "").prefix(300))) }
    }
    func apply(_ data: Data, completion: @escaping () -> Void) {
        let span = PerformanceCapture.shared.begin()
        webView.callAsyncJavaScript("GroupMap.apply(payload)", arguments: ["payload": String(decoding: data, as: UTF8.self)], in: nil, in: .page) { result in
            PerformanceCapture.shared.end(.groupMapApply, span)
            if case .failure(let error) = result { self.errors.append(String(error.localizedDescription.prefix(300))) }
            completion()
        }
    }
    func setPaused(_ paused: Bool) { webView.callAsyncJavaScript("GroupMap.setPaused(paused)", arguments: ["paused": paused], in: nil, in: .page, completionHandler: nil) }
    func teardown() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName)
        onReady = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if action.request.url?.scheme == GroupMapResources.scheme { decisionHandler(.allow); return }
        refusedNavigations.append(action.request.url?.absoluteString ?? "")
        decisionHandler(.cancel)
    }
}

/// View → Group. The feed runs only while the window is actually visible.
final class GroupMapWindows: NSObject, NSWindowDelegate {
    static let shared = GroupMapWindows()
    private var window: NSWindow?
    private var page: GroupMapPage?
    private var feed: GroupMapFeed?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Group"; window.isReleasedWhenClosed = false; window.setFrameAutosaveName("ConverseGroupMap")
        window.minSize = NSSize(width: 480, height: 320)
        let page = GroupMapPage(frame: window.contentLayoutRect)
        page.webView.autoresizingMask = [.width, .height]
        window.contentView = page.webView
        let feed = GroupMapFeed(store: .shared, service: Store.shared.participantService) { [weak page] data, done in
            guard let page else { done(); return }
            page.apply(data, completion: done)
        }
        page.onReady = { [weak self] in self?.syncVisibility() }
        window.delegate = self
        self.window = window; self.page = page; self.feed = feed
        page.load()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func syncVisibility() {
        guard let window, let page, let feed, page.isReady else { return }
        let visible = window.occlusionState.contains(.visible)
        if visible, !feed.isRunning { page.setPaused(false); feed.start() }
        else if !visible, feed.isRunning { feed.stop(); page.setPaused(true) }
    }
    func windowDidChangeOcclusionState(_ notification: Notification) { syncVisibility() }
    func windowWillClose(_ notification: Notification) {
        feed?.stop(); page?.teardown()
        window?.delegate = nil
        window = nil; page = nil; feed = nil
    }
}
