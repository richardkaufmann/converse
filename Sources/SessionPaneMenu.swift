import AppKit
import SwiftUI

// The session pane's "…" menu: every option the sidebar right-click and the
// conversation footer already offer, duplicated in one place (1FEA). The
// originals stay where they are; nothing is replaced. Agent panes get the
// agent's own items instead of the plain session's, their run controls ride
// along from AgentRunControls, and the footer's loop/voice items are plumbed
// to this menu's own popovers.
enum SessionPaneMenuAction: Hashable {
    case rename, agentSetup, showAssessment, getPortrait, runOnce, refreshAssessment, clearAttention
    case loopControls, toggleTalking, dictate
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
    init(isAgent: Bool, busy: Bool, needsAgentSetup: Bool, noAgentTurns: Bool, talking: Bool,
         switchboardEnabled: Bool, hasPending: Bool, queuePaused: Bool, canStop: Bool,
         changingSetting: Bool, probingStatus: Bool) {
        var rows: [SessionPaneMenuRow] = [.button(title: "Rename…", action: .rename, enabled: true)]
        if isAgent {
            rows += [.button(title: "Agent Setup…", action: .agentSetup, enabled: true),
                     .button(title: "Show assessment", action: .showAssessment, enabled: true),
                     .button(title: "Get Portrait", action: .getPortrait, enabled: true),
                     .button(title: "Run once", action: .runOnce, enabled: !needsAgentSetup),
                     .button(title: "Refresh assessment now", action: .refreshAssessment, enabled: !noAgentTurns),
                     .button(title: "Clear attention banner", action: .clearAttention, enabled: true),
                     .divider,
                     .button(title: "Loop controls…", action: .loopControls, enabled: true),
                     .button(title: talking ? "Stop talking" : "Start talking!", action: .toggleTalking, enabled: true),
                     .button(title: "Dictate…", action: .dictate, enabled: true)]
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
            rows.append(.button(title: "Choose Login…", action: .chooseLogin, enabled: !busy && !changingSetting))
        }
        rows += [.button(title: "Refresh status", action: .refreshStatus, enabled: !probingStatus),
                 .button(title: "Attach Image…", action: .attachImage, enabled: true)]
        self.init(rows: rows)
    }

    init(_ session: Session) {
        self.init(isAgent: session.isAgentSession, busy: session.busy,
                  needsAgentSetup: session.needsAgentSetup,
                  noAgentTurns: (session.agent?.turnLimit ?? 0) == 0,
                  talking: MainActor.assumeIsolated { AgentConversation.shared.owns(session) },
                  switchboardEnabled: session.switchboardEnabled,
                  hasPending: !session.pending.isEmpty, queuePaused: session.queuePaused,
                  canStop: session.busy || session.claudeLive != nil,
                  changingSetting: session.changingSetting, probingStatus: session.probingStatus)
    }
}

struct SessionPaneMenuItems: View {
    @ObservedObject var session: Session
    var loopControls: () -> Void = {}
    var toggleTalking: () -> Void = {}
    var dictate: () -> Void = {}
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
        case .refreshAssessment: Store.shared.queueAssessmentRefresh(session)
        case .clearAttention: Store.shared.clearAgentAttention(session)
        case .loopControls: loopControls()
        case .toggleTalking: toggleTalking()
        case .dictate: dictate()
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
/// borderless menu at small control size. Footer setting submenus (model,
/// effort, permissions and Compact) ride along for plain sessions, except
/// unbound imports, whose footer hides them behind the provider picker;
/// agent run controls ride along for agents. Compact therefore stays in
/// both its footer menu and here.
struct SessionPaneEllipsisMenu: View {
    @ObservedObject var session: Session
    @State private var loopSettings = false
    @State private var dictating = false
    @StateObject private var voice = AgentDictation()
    @ObservedObject private var conversation = AgentConversation.shared
    private var lineNumbers: Binding<Bool> {
        Binding(get: { Store.shared.lineNumbers }, set: { Store.shared.lineNumbers = $0 })
    }
    var body: some View {
        Menu {
            if session.isAgentSession {
                AgentRunControls(session: session, runOnce: false)
                Divider()
            }
            SessionPaneMenuItems(session: session,
                                 loopControls: { loopSettings = true },
                                 toggleTalking: {
                                     if conversation.owns(session) { conversation.stop() }
                                     else { dictating = false; voice.cancel(); conversation.start(session, store: .shared) }
                                 },
                                 dictate: { conversation.stop(); dictating = true })
            Toggle("Message numbers", isOn: lineNumbers)
            if !session.isAgentSession && !session.isUnboundImport {
                Divider()
                Group { SessionSettingSubmenus(model: SessionSettingsMenuModel(session), perform: { Store.shared.perform($0, session: session) }) }
                    .id(SessionSettingsMenuModel(session))
                    .disabled(session.changingSetting)
            }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
            .accessibilityLabel("Session actions")
            .help("Session actions: rename, configure, transcript limits, account and model settings")
            .popover(isPresented: $loopSettings) { AgentLoopOptions(session: session, close: { loopSettings = false }) }
            .popover(isPresented: $dictating) { AgentDictationView(voice: voice, session: session, close: { dictating = false }) }
            .onDisappear { if conversation.owns(session) { conversation.stop() } }
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
                                     noAgentTurns: true, talking: false,
                                     switchboardEnabled: true, hasPending: true, queuePaused: false,
                                     canStop: false, changingSetting: false, probingStatus: false)
    check(titles(plain) == ["Rename…", "Configure…", "Teach Session To Talk To Other Sessions",
                            "Disable session messaging", "Transcript Limits…", "Trim All Images…",
                            "Stop", "Pause queue", "Choose Login…", "Refresh status", "Attach Image…"],
          "The session pane menu duplicates the sidebar and footer options in sidebar order")
    check(enabled(plain, .stop) == false && enabled(plain, .configure) == true,
          "An idle plain session can be configured from the pane menu but not stopped")
    let busyPlain = SessionPaneMenuModel(isAgent: false, busy: true, needsAgentSetup: false,
                                         noAgentTurns: true, talking: false,
                                         switchboardEnabled: false, hasPending: false, queuePaused: true,
                                         canStop: true, changingSetting: true, probingStatus: true)
    check(!titles(busyPlain).contains("Disable session messaging") && !titles(busyPlain).contains("Pause queue")
          && enabled(busyPlain, .configure) == false && enabled(busyPlain, .chooseLogin) == false
          && enabled(busyPlain, .refreshStatus) == false && enabled(busyPlain, .stop) == true,
          "A busy plain session disables configure, login and refresh in the pane menu and can stop")
    let agent = SessionPaneMenuModel(isAgent: true, busy: true, needsAgentSetup: true,
                                     noAgentTurns: true, talking: false,
                                     switchboardEnabled: true, hasPending: true, queuePaused: false,
                                     canStop: true, changingSetting: false, probingStatus: false)
    check(Array(titles(agent).prefix(11)) == ["Rename…", "Agent Setup…", "Show assessment", "Get Portrait",
                                              "Run once", "Refresh assessment now", "Clear attention banner",
                                              "Loop controls…", "Start talking!", "Dictate…", "Configure…"],
          "The agent pane menu carries the agent's sidebar and footer items, including loop and voice, before Configure")
    check(enabled(agent, .runOnce) == false && enabled(agent, .refreshAssessment) == false
          && enabled(agent, .configure) == true && enabled(agent, .stop) == nil && enabled(agent, .chooseLogin) == nil,
          "An agent needing setup cannot run or refresh from the pane menu, keeps its Configure route, and has no plain-session stop or login items")
    let talkingAgent = SessionPaneMenuModel(isAgent: true, busy: false, needsAgentSetup: false,
                                            noAgentTurns: false, talking: true,
                                            switchboardEnabled: false, hasPending: false, queuePaused: false,
                                            canStop: false, changingSetting: false, probingStatus: false)
    check(titles(talkingAgent).contains("Stop talking") && enabled(talkingAgent, .refreshAssessment) == true
          && enabled(talkingAgent, .runOnce) == true,
          "A talking agent's pane menu offers Stop talking and enables run and refresh")
}
