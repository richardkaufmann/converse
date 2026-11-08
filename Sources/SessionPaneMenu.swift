import AppKit
import SwiftUI

// The session pane's "…" menu: every option the sidebar right-click and the
// conversation footer already offer, duplicated in one place (1FEA). The
// originals stay where they are; nothing is replaced. Agent panes get the
// agent's own items instead of the plain session's, and their run controls
// ride along from AgentRunControls when the menu renders.
enum SessionPaneMenuAction: Hashable {
    case rename, agentSetup, showAssessment, getPortrait, runOnce, clearAttention
    case configure, teach, disableMessaging, transcriptLimits, trimAllImages
    case stop, toggleQueue, chooseLogin, refreshStatus, attachImage
}

enum SessionPaneMenuRow: Equatable {
    case button(title: String, action: SessionPaneMenuAction, enabled: Bool)
    case divider
}

struct SessionPaneMenuModel: Equatable {
    let rows: [SessionPaneMenuRow]
}

extension SessionPaneMenuModel {
    init(isAgent: Bool, busy: Bool, needsAgentSetup: Bool, switchboardEnabled: Bool,
         hasPending: Bool, queuePaused: Bool, canStop: Bool,
         changingSetting: Bool, probingStatus: Bool) {
        var rows: [SessionPaneMenuRow] = [.button(title: "Rename…", action: .rename, enabled: true)]
        if isAgent {
            rows += [.button(title: "Agent Setup…", action: .agentSetup, enabled: true),
                     .button(title: "Show assessment", action: .showAssessment, enabled: true),
                     .button(title: "Get Portrait", action: .getPortrait, enabled: true),
                     .button(title: "Run once", action: .runOnce, enabled: !needsAgentSetup),
                     .button(title: "Clear attention banner", action: .clearAttention, enabled: true)]
        }
        rows.append(.button(title: "Configure…", action: .configure, enabled: isAgent || !busy))
        rows.append(.button(title: "Teach Session To Talk To Other Sessions", action: .teach, enabled: true))
        if switchboardEnabled {
            rows.append(.button(title: "Disable session messaging", action: .disableMessaging, enabled: true))
        }
        rows += [.divider,
                 .button(title: "Transcript Limits…", action: .transcriptLimits, enabled: true),
                 .button(title: "Trim All Images…", action: .trimAllImages, enabled: true),
                 .divider]
        if !isAgent {
            rows.append(.button(title: "Stop", action: .stop, enabled: canStop))
            if hasPending {
                rows.append(.button(title: queuePaused ? "Resume queue" : "Pause queue", action: .toggleQueue, enabled: true))
            }
        }
        rows += [.button(title: "Choose Login…", action: .chooseLogin, enabled: !busy && !changingSetting),
                 .button(title: "Refresh status", action: .refreshStatus, enabled: !probingStatus),
                 .button(title: "Attach Image…", action: .attachImage, enabled: true)]
        self.init(rows: rows)
    }

    init(_ session: Session) {
        self.init(isAgent: session.isAgentSession, busy: session.busy,
                  needsAgentSetup: session.needsAgentSetup,
                  switchboardEnabled: session.switchboardEnabled,
                  hasPending: !session.pending.isEmpty, queuePaused: session.queuePaused,
                  canStop: session.busy || session.claudeLive != nil,
                  changingSetting: session.changingSetting, probingStatus: session.probingStatus)
    }
}

struct SessionPaneMenuItems: View {
    @ObservedObject var session: Session
    var model: SessionPaneMenuModel { SessionPaneMenuModel(session) }
    var body: some View {
        ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in
            switch row {
            case .divider: Divider()
            case .button(let title, let action, let enabled):
                Button(title) { perform(action) }.disabled(!enabled)
            }
        }
    }
    private func perform(_ action: SessionPaneMenuAction) {
        switch action {
        case .rename: AppDelegate.shared.renameSession(session)
        case .agentSetup: AgentWindows.shared.setup(session)
        case .showAssessment: AgentWindows.shared.widget(session)
        case .getPortrait: Task { await PortraitService.shared.request(session, store: .shared, origin: .menu, reply: .transcript) }
        case .runOnce: Store.shared.queueAgentRun(session)
        case .clearAttention: Store.shared.clearAgentAttention(session)
        case .configure: AppDelegate.shared.configureSession(session)
        case .teach: Store.shared.teachSwitchboard(session)
        case .disableMessaging: session.switchboardEnabled = false; Store.shared.save()
        case .transcriptLimits: TranscriptLimitsPanel.show(session)
        case .trimAllImages: Store.shared.confirmTrimAllImages([session])
        case .stop: Store.shared.stop(session)
        case .toggleQueue: Store.shared.toggleQueue(session)
        case .chooseLogin: AppDelegate.shared.chooseLogin(session)
        case .refreshStatus: Store.shared.refreshStatus(session, quota: true)
        case .attachImage:
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = true
            if panel.runModal() == .OK { for url in panel.urls { if let image = NSImage(contentsOf: url) { Store.shared.attach(session, image: image) } } }
        }
    }
}

/// Identical in look to the Parking Lot pane's "…": a plain ellipsis in a
/// borderless menu. Footer setting submenus (model, effort, permissions and
/// Compact) ride along for plain sessions; agent run controls for agents.
/// Compact therefore stays in both its footer menu and here.
struct SessionPaneEllipsisMenu: View {
    @ObservedObject var session: Session
    @ObservedObject private var store = Store.shared
    var body: some View {
        Menu {
            if session.isAgentSession {
                AgentRunControls(session: session, runOnce: false)
                Divider()
            }
            SessionPaneMenuItems(session: session)
            Toggle("Message numbers", isOn: $store.lineNumbers)
            if !session.isAgentSession {
                Divider()
                Group { SessionSettingSubmenus(model: SessionSettingsMenuModel(session), perform: { Store.shared.perform($0, session: session) }) }
                    .disabled(session.changingSetting)
            }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Session actions")
            .help("Session actions: rename, configure, transcript limits, account and model settings")
    }
}

func sessionPaneMenuSelfTests(_ check: (Bool, String) -> Void) {
    func titles(_ model: SessionPaneMenuModel) -> [String] {
        model.rows.compactMap { if case .button(let title, _, _) = $0 { return title }; return nil }
    }
    func enabled(_ model: SessionPaneMenuModel, _ action: SessionPaneMenuAction) -> Bool? {
        for row in model.rows { if case .button(_, action, let enabled) = row { return enabled } }
        return nil
    }
    let plain = SessionPaneMenuModel(isAgent: false, busy: false, needsAgentSetup: false,
                                     switchboardEnabled: true, hasPending: true, queuePaused: false,
                                     canStop: false, changingSetting: false, probingStatus: false)
    check(titles(plain) == ["Rename…", "Configure…", "Teach Session To Talk To Other Sessions",
                            "Disable session messaging", "Transcript Limits…", "Trim All Images…",
                            "Stop", "Pause queue", "Choose Login…", "Refresh status", "Attach Image…"],
          "The session pane menu duplicates the sidebar and footer options in sidebar order")
    check(enabled(plain, .stop) == false && enabled(plain, .configure) == true,
          "An idle plain session can be configured from the pane menu but not stopped")
    let busyPlain = SessionPaneMenuModel(isAgent: false, busy: true, needsAgentSetup: false,
                                         switchboardEnabled: false, hasPending: false, queuePaused: true,
                                         canStop: true, changingSetting: true, probingStatus: true)
    check(!titles(busyPlain).contains("Disable session messaging") && !titles(busyPlain).contains("Pause queue")
          && enabled(busyPlain, .configure) == false && enabled(busyPlain, .chooseLogin) == false
          && enabled(busyPlain, .refreshStatus) == false && enabled(busyPlain, .stop) == true,
          "A busy plain session disables configure, login and refresh in the pane menu and can stop")
    let agent = SessionPaneMenuModel(isAgent: true, busy: true, needsAgentSetup: true,
                                     switchboardEnabled: true, hasPending: true, queuePaused: false,
                                     canStop: true, changingSetting: false, probingStatus: false)
    check(Array(titles(agent).prefix(7)) == ["Rename…", "Agent Setup…", "Show assessment", "Get Portrait",
                                             "Run once", "Clear attention banner", "Configure…"],
          "The agent pane menu carries the agent's extra sidebar items before Configure")
    check(enabled(agent, .runOnce) == false && enabled(agent, .configure) == true && enabled(agent, .stop) == nil,
          "An agent needing setup cannot run once from the pane menu, keeps its Configure route and uses its run controls to stop")
}
