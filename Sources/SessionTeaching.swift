import SwiftUI

/// The switchboard lesson an ordinary session is taught. Bump `version`
/// whenever `Store.switchboardTeaching` changes, so taught sessions show the
/// yellow Re-teach banner once.
enum SwitchboardTeaching {
    /// 1: every lesson before versions were recorded. 2: round 135.
    static let version = 2
    static let talkHelp = "Teaches this session to message your other sessions (tell and ask) and to read and edit Parking Lots through the switchboard. Sends one visible message."
    static let controlHelp = "Lets this session operate Converse for you: create sessions, agents and Parking Lots, and change settings. Normally only App Support needs this."
}

enum TeachingBanner: Equatable {
    /// Never taught: red.
    case untaught
    /// Taught an older lesson: yellow.
    case outdated
}

extension Store {
    /// Ordinary local provider sessions only: not agents, App Support,
    /// unbound imports or remote viewers. The first-run coding session learns
    /// with its first request, so it shows nothing meanwhile.
    func teachingBanner(_ s: Session) -> TeachingBanner? {
        guard sessions.contains(where: { $0 === s }), !s.isAgentSession, !s.supportAssistant, !s.isUnboundImport,
              !["agent", "support"].contains(s.entry.engine) else { return nil }
        if let record = firstRun.record, record.codingID == s.id, record.teachCoding == true { return nil }
        let banner: TeachingBanner
        if let version = s.switchboardTeachingVersion {
            // Turning session messaging off is a choice; don't nag about it.
            guard s.switchboardEnabled, version < SwitchboardTeaching.version else { return nil }
            banner = .outdated
        } else { banner = .untaught }
        return (s.teachingBannerDismissed ?? 0) >= SwitchboardTeaching.version ? nil : banner
    }
    /// Hidden until the lesson changes again.
    func dismissTeachingBanner(_ s: Session) {
        s.teachingBannerDismissed = SwitchboardTeaching.version
        save()
    }
}

/// The pane's teaching banner, when its session should show one.
struct SessionTeachingBanner: View {
    @ObservedObject var store: Store
    @ObservedObject var session: Session
    var body: some View {
        if let banner = store.teachingBanner(session) {
            VStack(spacing: 0) {
                TeachingBannerView(banner: banner, teach: { store.teachSwitchboard(session) }, dismiss: { store.dismissTeachingBanner(session) })
                Divider()
            }
        }
    }
}

struct TeachingBannerView: View {
    let banner: TeachingBanner
    let teach: () -> Void
    let dismiss: () -> Void
    @State private var explaining = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: banner == .untaught ? "exclamationmark.bubble" : "arrow.triangle.2.circlepath")
            Text(banner == .untaught ? "This session can’t message other sessions yet." : "Converse’s session lessons changed. Please re-teach this session.")
                .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            Spacer(minLength: 4)
            Button(banner == .untaught ? "Teach it" : "Re-teach", action: teach)
                .help(SwitchboardTeaching.talkHelp)
            Button("What’s this?") { explaining.toggle() }.buttonStyle(.link)
                .popover(isPresented: $explaining, arrowEdge: .bottom) { TeachingExplanation().padding(14).frame(width: 360) }
            Button("Don’t show again", action: dismiss).buttonStyle(.link)
                .help("Hide this banner until Converse’s lessons change again")
        }.font(.caption).padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(banner == .untaught ? Color.red.opacity(0.2) : Color.yellow.opacity(0.28))
            .accessibilityElement(children: .contain)
    }
}

struct TeachingExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Teaching a session").font(.headline)
            Text("**Talk To Other Sessions** shows this session how to message your other sessions — “tell Muse the build is green”, “ask Codex what it changed” — and how to read and edit your Parking Lots. Teaching sends one visible message and the session answers briefly.")
            Text("It’s in the session’s right-click menu. When Converse changes the lesson, this banner turns yellow so you can re-teach. App Support needs no teaching: Converse keeps it up to date.").foregroundStyle(.secondary)
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }
}
