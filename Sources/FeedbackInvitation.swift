import Foundation

/// Local, per-profile state. Never sent to a provider, GitHub, or another device.
/// A shown release stays consumed even if the app quits before the banner expires.
struct FeedbackInvitationState: Codable {
    static func allowed(info: [String: Any], environment: [String: String], arguments: [String]) -> Bool {
        guard info["ConverseDemo"] as? Bool != true, info["ConverseTestProvider"] == nil,
              info["ConverseNUXPreview"] as? Bool != true else { return false }
        guard environment["CONVERSE_TEST_COMMAND"] == nil, environment["CONVERSE_DATA_DIR"] == nil,
              !environment.keys.contains(where: { $0.hasPrefix("CONVERSE_QA_") || $0.hasPrefix("CONVERSE_AUTOMATION") }) else { return false }
        return !arguments.contains(where: { $0.hasPrefix("--") && ($0.contains("test") || $0.contains("preview")) })
    }
    static let qualifyingTurns = 20
    static let bannerSeconds: TimeInterval = 5 * 60
    var release: String
    var completedTurns = 0
    var askedReleases: Set<String> = []
    // Optional for archives written before permanent suppression was added.
    var feedbackGiven: Bool? = nil
    var suppressed: Bool { feedbackGiven == true }
    mutating func markFeedbackGiven() { feedbackGiven = true }

    mutating func useRelease(_ value: String) {
        guard value != release else { return }
        release = value; completedTurns = 0
    }
    mutating func completedTurn(success: Bool, interrupted: Bool, humanDirected: Bool) {
        guard !suppressed, success, !interrupted, humanDirected, !feedbackAsk else { return }
        completedTurns = min(Self.qualifyingTurns, completedTurns + 1)
    }
    /// Richard's feedback_ask: false on each install of a release, true once
    /// this release's banner has been seen.
    var feedbackAsk: Bool { askedReleases.contains(release) }
    var eligible: Bool {
        !suppressed && !feedbackAsk && completedTurns >= Self.qualifyingTurns
    }
    @discardableResult mutating func markShown() -> Bool {
        guard eligible else { return false }
        askedReleases.insert(release); return true
    }
}

func feedbackInvitationSelfTests(_ check: (Bool, String) -> Void) {
    var state = FeedbackInvitationState(release: "0.7.16/151")
    check(!state.eligible && !state.feedbackAsk && state.askedReleases.isEmpty, "Feedback invitation starts off on a new profile with feedback_ask false")
    for _ in 0..<19 { state.completedTurn(success: true, interrupted: false, humanDirected: true) }
    check(!state.eligible && state.completedTurns == 19, "Feedback invitation waits through nineteen human turns")
    state.completedTurn(success: true, interrupted: false, humanDirected: true)
    check(state.eligible && state.markShown(), "Twentieth completed human turn qualifies without an elapsed-time threshold")
    check(state.feedbackAsk && !state.eligible && !state.markShown(), "Showing sets feedback_ask for this release without tracking a button or star")
    let copy = try! JSONDecoder().decode(FeedbackInvitationState.self, from: JSONEncoder().encode(state))
    check(!copy.eligible && copy.askedReleases.contains("0.7.16/151"), "Relaunch preserves the consumed release")
    state.useRelease("0.7.17/152")
    check(state.completedTurns == 0 && !state.eligible && !state.feedbackAsk, "A new installed release resets feedback_ask and starts a new twenty-turn count")
    for _ in 0..<25 {
        state.completedTurn(success: false, interrupted: false, humanDirected: true)
        state.completedTurn(success: true, interrupted: true, humanDirected: true)
        state.completedTurn(success: true, interrupted: false, humanDirected: false)
    }
    check(state.completedTurns == 0 && !state.eligible, "Failures, interruptions and autonomous traffic cannot earn an invitation")
    for _ in 0..<20 { state.completedTurn(success: true, interrupted: false, humanDirected: true) }
    check(state.eligible, "A later release qualifies after twenty human turns")
    state.useRelease("0.7.16/151")
    check(!state.eligible, "Downgrading never repeats an already shown release")
    check(!FeedbackInvitationState(release: "0.7.16/151").askedReleases.contains("0.7.16/151"), "Separate profiles have separate invitation history")
    state.markFeedbackGiven()
    let suppressed = try! JSONDecoder().decode(FeedbackInvitationState.self, from: JSONEncoder().encode(state))
    state = suppressed; state.useRelease("0.8.0/200")
    for _ in 0..<25 { state.completedTurn(success: true, interrupted: false, humanDirected: true) }
    check(state.suppressed && !state.eligible && state.completedTurns == 0 && !state.markShown(), "Feedback acknowledgement survives relaunch and upgrade and stops counting")
    state.useRelease("0.7.16/151")
    check(state.suppressed && !state.eligible, "Feedback acknowledgement also survives downgrades")
    let legacy = Data(#"{"release":"0.7.16/151","completedTurns":19,"askedReleases":[]}"#.utf8)
    var migrated = try! JSONDecoder().decode(FeedbackInvitationState.self, from: legacy)
    migrated.completedTurn(success: true, interrupted: false, humanDirected: true)
    check(!migrated.suppressed && migrated.eligible, "Older invitation records without feedbackGiven still qualify normally")

    check(FeedbackInvitationState.allowed(info: [:], environment: [:], arguments: []), "Normal interactive app allows feedback invitation")
    for info: [String: Any] in [["ConverseDemo": true], ["ConverseTestProvider": "Codex"], ["ConverseNUXPreview": true]] {
        check(!FeedbackInvitationState.allowed(info: info, environment: [:], arguments: []), "Demo, TEST and Setup Preview exclude feedback invitation")
    }
    check(!FeedbackInvitationState.allowed(info: [:], environment: ["CONVERSE_TEST_COMMAND": "/usr/bin/false"], arguments: []), "Test automation excludes feedback invitation")
    check(!FeedbackInvitationState.allowed(info: [:], environment: [:], arguments: ["--settings-preview"]), "Preview command excludes feedback invitation")

    let typed = PendingPrompt(typed: true, text: "typed", images: [])
    check(typed.humanTyped && typed.held(text: "typed", images: [], switchboardHop: 0).humanTyped,
          "A human prompt held after Muse reports the session in use still counts as human")
    let relayed = PendingPrompt(text: "[Requested by the human through Converse App Support]\nhello", images: [])
    let continuation = PendingPrompt(supportContinuation: true, text: "[Converse app-control result]", images: [])
    check(!relayed.humanTyped && !continuation.humanTyped && !PendingPrompt(switchboardHop: 0, text: "teach", images: []).humanTyped,
          "App Support relays, app-control continuations and app teaching never count; the typed App Support turn already did")
    check(PendingPrompt(components: [typed, typed], text: "typed\n\ntyped", images: []).humanTyped
          && !PendingPrompt(components: [typed, PendingPrompt(switchboardHop: 1, text: "relay", images: [])], text: "x", images: []).humanTyped,
          "Inject all counts only when every combined part was typed")

}
