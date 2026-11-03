import SwiftUI

// One description of the footer's Model / Effort / Permissions / Compact choices.
// The wide footer and the narrow ⋯ menu both render it and route through perform(_:),
// so neither layout can show different values or call a different action.
enum SessionSettingAction: Hashable {
    case clearOverride(String), model(String), effort(String), access(String), customModel, customEffort, compact
}
enum SessionSettingRow: Hashable {
    case button(String, SessionSettingAction, enabled: Bool)
    case text(String)
    case divider
}
struct SessionSettingMenu: Hashable {
    let title: String
    let rows: [SessionSettingRow]
}
struct SessionSettingsMenuModel: Hashable {
    let menus: [SessionSettingMenu]
    let compact: SessionSettingRow?
    let compactHelp: String

    static func make(engine: String, model: String, effort: String, access: String, modelChoices: [MuseModelChoice], efforts: [String], accessChoices: [MuseAccessChoice], probing: Bool, compactable: Bool, compactEnabled: Bool, busy: Bool) -> SessionSettingsMenuModel {
        let defaults = engine != "muse"
        func cliDefault(_ field: String) -> [SessionSettingRow] { defaults ? [.button("CLI default", .clearOverride(field), enabled: true), .divider] : [] }
        let models = cliDefault("model") + modelChoices.map { .button($0.label, .model($0.id), enabled: true) } + [.divider, .button("Other model…", .customModel, enabled: true)]
        let effortRows = cliDefault("effort")
            + (efforts.isEmpty ? [.text(probing ? "Loading supported effort levels…" : "This model has no reported effort options")] : [])
            + efforts.map { .button($0, .effort($0), enabled: true) } + [.divider, .button("Other effort…", .customEffort, enabled: true)]
        let accessRows = cliDefault("access") + accessChoices.map { .button($0.label, .access($0.id), enabled: $0.available) }
        return SessionSettingsMenuModel(menus: [
            SessionSettingMenu(title: "Model: " + model, rows: models),
            SessionSettingMenu(title: "Effort: " + effort, rows: effortRows),
            SessionSettingMenu(title: "Permissions: " + access, rows: accessRows),
        ], compact: compactable ? .button("Compact", .compact, enabled: compactEnabled) : nil, compactHelp: busy ? "Compact after this turn" : "Compact context")
    }
    init(menus: [SessionSettingMenu], compact: SessionSettingRow?, compactHelp: String) { self.menus = menus; self.compact = compact; self.compactHelp = compactHelp }
    init(_ s: Session) {
        self = Self.make(engine: s.entry.engine, model: s.toolStatus.model, effort: s.toolStatus.effort, access: s.toolStatus.access, modelChoices: s.modelChoices, efforts: s.availableEfforts, accessChoices: s.accessChoices, probing: s.probingStatus, compactable: s.compactionState != nil, compactEnabled: !(s.compacting || s.compactionRequested || s.changingSetting), busy: s.busy)
    }
}
extension Store {
    func perform(_ action: SessionSettingAction, session s: Session) {
        switch action {
        case .clearOverride(let field): clearOverride(s, field: field)
        case .model(let id): if let model = s.modelChoices.first(where: { $0.id == id }) { changeSetting(s, .model(model)) }
        case .effort(let effort): changeSetting(s, .effort(effort))
        case .access(let access): changeSetting(s, .access(access))
        case .customModel: chooseCustomModel(s)
        case .customEffort: chooseCustomEffort(s)
        case .compact: _ = requestCompaction(s)
        }
    }
}

struct SessionSettingRows: View {
    let rows: [SessionSettingRow]
    let perform: (SessionSettingAction) -> Void
    var body: some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            switch row {
            case .button(let title, let action, let enabled): Button(title) { perform(action) }.disabled(!enabled)
            case .text(let title): Text(title)
            case .divider: Divider()
            }
        }
    }
}
// Wide footer: each setting is its own borderless pop-up.
struct SessionSettingControls: View {
    let model: SessionSettingsMenuModel
    let perform: (SessionSettingAction) -> Void
    var body: some View {
        ForEach(model.menus, id: \.self) { menu in
            Menu(menu.title) { SessionSettingRows(rows: menu.rows, perform: perform) }.menuStyle(.borderlessButton).fixedSize()
        }
        if case .button(let title, let action, let enabled)? = model.compact {
            Button(title) { perform(action) }.disabled(!enabled).help(model.compactHelp)
        }
    }
}
// Narrow ⋯ menu: plain submenus. Styled pop-up Menus nested inside a Menu drop their
// selections and keep stale titles, so these must stay unstyled.
struct SessionSettingSubmenus: View {
    let model: SessionSettingsMenuModel
    let perform: (SessionSettingAction) -> Void
    var body: some View {
        ForEach(model.menus, id: \.self) { menu in
            Menu(menu.title) { SessionSettingRows(rows: menu.rows, perform: perform) }
        }
        if let compact = model.compact { SessionSettingRows(rows: [compact], perform: perform) }
    }
}

func sessionSettingsMenuSelfTests(_ check: (Bool, String) -> Void) {
    let s = Session(entry: Entry(name: "Settings QA", command: "false", directory: "/tmp", engine: "claude"))
    s.modelChoices = [MuseModelChoice(id: "opus", label: "Opus · claude-opus", provider: "claude", profile: nil, efforts: ["low", "high"])]
    s.accessChoices = [("default", "Manual"), ("bypassPermissions", "Bypass permissions")].map { MuseAccessChoice(id: $0.0, label: $0.1, available: true) }
    s.toolStatus.model = "Opus · claude-opus"; s.toolStatus.effort = "CLI default"; s.toolStatus.access = "Manual"
    let before = SessionSettingsMenuModel(s)
    check(before.menus.map(\.title) == ["Model: Opus · claude-opus", "Effort: CLI default", "Permissions: Manual"], "Footer setting menus are titled from the session's current values")
    let actions = before.menus[2].rows.compactMap { row -> SessionSettingAction? in if case .button(_, let action, _) = row { return action }; return nil }
    check(actions == [.clearOverride("access"), .access("default"), .access("bypassPermissions")], "Permissions menu lists CLI default and every provider choice")
    Store.shared.perform(.access("bypassPermissions"), session: s)
    Store.shared.perform(.model("opus"), session: s)
    Store.shared.perform(.effort("high"), session: s)
    let after = SessionSettingsMenuModel(s)
    check(s.choices.access == "bypassPermissions" && s.choices.model == "opus" && s.choices.effort == "high", "Setting menu actions reach changeSetting")
    check(after.menus.map(\.title) == ["Model: Opus · claude-opus", "Effort: high", "Permissions: Bypass permissions"] && after != before, "Setting menus relabel after a choice so the narrow menu cannot keep a stale value")
    Store.shared.perform(.clearOverride("access"), session: s)
    check(s.choices.access == nil && SessionSettingsMenuModel(s).menus[2].title == "Permissions: CLI default", "CLI default clears the permissions override from either layout")
    let muse = SessionSettingsMenuModel.make(engine: "muse", model: "m", effort: "e", access: "a", modelChoices: [], efforts: [], accessChoices: [], probing: true, compactable: true, compactEnabled: false, busy: true)
    check(!muse.menus.contains { $0.rows.contains(.button("CLI default", .clearOverride("model"), enabled: true)) } && muse.menus[1].rows.first == .text("Loading supported effort levels…") && muse.compact == .button("Compact", .compact, enabled: false) && muse.compactHelp == "Compact after this turn", "Muse setting menus omit CLI default and expose a disabled Compact while busy")
}
