import Foundation
import AppKit
import SwiftUI

// Fixed destination: model output can supply report text, never a host or credential.
struct GitHubBugReport {
    static let repository = "richardkaufmann/converse"
    static let newIssue = URL(string: "https://github.com/\(repository)/issues/new")!
    var title: String
    var body: String
    func validated() throws -> Self {
        let value = Self(title: title.trimmingCharacters(in: .whitespacesAndNewlines), body: body.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !value.title.isEmpty, value.title.count <= 200, !value.body.isEmpty, value.body.count <= 12000 else {
            throw AgentFailure.message("Add a title (up to 200 characters) and description (up to 12,000 characters).")
        }
        return value
    }
    func browserURL() throws -> URL {
        let value = try validated()
        var parts = URLComponents(url: Self.newIssue, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "title", value: value.title), URLQueryItem(name: "body", value: value.body)]
        guard let url = parts.url, url.absoluteString.utf8.count <= 7500 else {
            throw AgentFailure.message("This report is too long for a browser link. Shorten it, or copy the description and paste it into GitHub.")
        }
        return url
    }
    func submit(token: String, api: AgentAPI) async throws -> URL {
        let value = try validated()
        guard !token.isEmpty else { throw AgentFailure.message("Sign in on GitHub to submit this report.") }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/issues")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("Converse", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": value.title, "body": value.body])
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await api.request(request) }
        catch { throw AgentFailure.message("GitHub did not confirm the result. Check the issue list before trying again; this report was not automatically retried.") }
        guard response.statusCode == 201 else {
            throw AgentFailure.message("GitHub did not confirm creation (HTTP \(response.statusCode)). Use GitHub in your browser to sign in and check access. Check the issue list before trying again.")
        }
        guard data.count <= 2_000_000, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let number = json["number"] as? Int, number > 0, json["pull_request"] == nil,
              let raw = json["html_url"] as? String, raw == "https://github.com/\(Self.repository)/issues/\(number)" else {
            throw AgentFailure.message("GitHub accepted the request but returned an unexpected receipt. Check the issue list; do not submit it again.")
        }
        return URL(string: raw)!
    }
}

@MainActor final class BugReportWindow: NSObject, NSWindowDelegate {
    private static var windows: [UUID: BugReportWindow] = [:]
    let id: UUID
    let window: NSWindow
    init(id: UUID, report: GitHubBugReport, completion: @escaping (String) -> Void) {
        self.id = id
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 570), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Report a Converse bug · GitHub"; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: BugReportView(report: report, completion: completion))
        window.center()
    }
    static func show(id: UUID = UUID(), report: GitHubBugReport, completion: @escaping (String) -> Void = { _ in }) {
        if let prior = windows[id] { prior.window.makeKeyAndOrderFront(nil); return }
        let owner = BugReportWindow(id: id, report: report, completion: completion); windows[id] = owner
        owner.window.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { Self.windows.removeValue(forKey: id) }
}

private struct BugReportView: View {
    @State var report: GitHubBugReport
    let completion: (String) -> Void
    @State private var status = ""
    @State private var sending = false
    @State private var attempted = false
    @State private var receipt: URL?
    @State private var hasToken = false
    @State private var tokenInput = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report a Converse bug").font(.title2.bold())
            Text("To: richardkaufmann/converse on GitHub").font(.callout)
            TextField("Title", text: $report.title).textFieldStyle(.roundedBorder).disabled(sending || receipt != nil)
            TextEditor(text: $report.body).font(.body).border(.secondary.opacity(0.3)).disabled(sending || receipt != nil)
            Text("Review what you’re sharing. No logs, attachments or other conversations are added automatically.").font(.caption).foregroundStyle(.secondary)
            Text(hasToken ? "GitHub token saved. Submit reports directly from Converse." : "Recommended: save a GitHub token once, then submit reports here.").font(.callout)
            HStack {
                SecureField(hasToken ? "Replace GitHub token (optional)" : "Paste GitHub token", text: $tokenInput)
                Button("Save token") {
                    do {
                        try AgentSecrets.update("github", value: tokenInput, remove: false)
                        tokenInput = ""; hasToken = true; status = "GitHub token saved in Keychain. It is also available in Agent Setup."
                    } catch { status = error.localizedDescription }
                }.disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
            HStack {
                Link("Create or manage a GitHub token", destination: URL(string: "https://github.com/settings/tokens")!)
                Text("Needs access to this repository and permission to create issues.").font(.caption)
            }
            if !hasToken { Text("Without a token, copy the report and submit it on GitHub instead. Discord is not required.").font(.caption) }
            if !status.isEmpty { Text(status).textSelection(.enabled).font(.callout) }
            if let receipt { Link("View filed issue", destination: receipt) }
            HStack {
                Button("Copy description") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(report.body, forType: .string) }
                Link("Issue list", destination: URL(string: "https://github.com/richardkaufmann/converse/issues")!)
                Spacer()
                Button("Continue on GitHub…") {
                    do {
                        guard NSWorkspace.shared.open(try report.browserURL()) else { throw AgentFailure.message("Could not open the browser.") }
                        status = "Draft opened on GitHub. Sign in if asked, then click Submit new issue. Nothing has been filed by Converse."
                        completion(status)
                    } catch { status = error.localizedDescription }
                }.disabled(sending || receipt != nil)
                if hasToken {
                    Button(sending ? "Sending…" : "Submit report") {
                        // Read only at explicit submission. Never supply credentials to a model.
                        do {
                            _ = try report.validated()
                            guard let token = try AgentSecrets.read("github"), !token.isEmpty else { hasToken = false; return }
                            sending = true; attempted = true
                            Task { @MainActor in
                                defer { sending = false }
                                do {
                                    let url = try await report.submit(token: token, api: AgentAPI()); receipt = url
                                    status = "Filed on GitHub."; completion("Bug report filed: " + url.absoluteString)
                                } catch { status = error.localizedDescription; completion(status) }
                            }
                        } catch { status = error.localizedDescription }
                    }.disabled(sending || attempted)
                }
            }
        }.padding(18).onAppear { hasToken = ((try? AgentSecrets.read("github")) ?? "").isEmpty == false }
    }
}
