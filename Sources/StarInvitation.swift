import Foundation

/// Local, per-profile state. Never sent to a provider, GitHub, or another device.
/// A shown release stays consumed even if the app quits before the banner expires.
struct StarInvitationState: Codable {
    static let qualifyingSeconds: TimeInterval = 30 * 60
    static let qualifyingTurns = 5
    static let bannerSeconds: TimeInterval = 5 * 60
    var release: String
    var activeSeconds: TimeInterval = 0
    var completedTurns = 0
    var askedReleases: Set<String> = []

    mutating func useRelease(_ value: String) {
        guard value != release else { return }
        release = value; activeSeconds = 0; completedTurns = 0
    }
    mutating func addActiveSeconds(_ seconds: TimeInterval) {
        guard seconds.isFinite, seconds > 0, !askedReleases.contains(release) else { return }
        activeSeconds = min(Self.qualifyingSeconds, activeSeconds + seconds)
    }
    mutating func completedTurn(success: Bool, interrupted: Bool, humanDirected: Bool) {
        guard success, !interrupted, humanDirected, !askedReleases.contains(release) else { return }
        completedTurns = min(Self.qualifyingTurns, completedTurns + 1)
    }
    var eligible: Bool {
        !askedReleases.contains(release) && activeSeconds >= Self.qualifyingSeconds && completedTurns >= Self.qualifyingTurns
    }
    @discardableResult mutating func markShown() -> Bool {
        guard eligible else { return false }
        askedReleases.insert(release); return true
    }
}

func starInvitationSelfTests(_ check: (Bool, String) -> Void) {
    var state = StarInvitationState(release: "0.7.16/151")
    check(!state.eligible && state.askedReleases.isEmpty, "Star invitation starts off on a new profile")
    for _ in 0..<5 { state.completedTurn(success: true, interrupted: false, humanDirected: true) }
    state.addActiveSeconds(1799)
    check(!state.eligible, "Completed turns alone cannot prompt before thirty active minutes")
    state.addActiveSeconds(1)
    check(state.eligible && state.markShown(), "Five completed human turns and thirty active minutes qualify")
    check(!state.eligible && !state.markShown(), "Showing consumes this release without tracking a star click")
    let copy = try! JSONDecoder().decode(StarInvitationState.self, from: JSONEncoder().encode(state))
    check(!copy.eligible && copy.askedReleases.contains("0.7.16/151"), "Relaunch preserves the consumed release")
    state.useRelease("0.7.17/152")
    check(state.completedTurns == 0 && state.activeSeconds == 0 && !state.eligible, "A new installed release must earn its own invitation")
    state.addActiveSeconds(.nan); state.addActiveSeconds(-1)
    check(state.activeSeconds == 0, "Invalid elapsed samples never count as active use")
    state.addActiveSeconds(1800)
    for _ in 0..<8 {
        state.completedTurn(success: false, interrupted: false, humanDirected: true)
        state.completedTurn(success: true, interrupted: true, humanDirected: true)
        state.completedTurn(success: true, interrupted: false, humanDirected: false)
    }
    check(state.completedTurns == 0 && !state.eligible, "Failures, interruptions and autonomous traffic cannot earn an invitation")
    for _ in 0..<5 { state.completedTurn(success: true, interrupted: false, humanDirected: true) }
    check(state.eligible, "A later release can qualify after meaningful use")
    state.useRelease("0.7.16/151"); state.addActiveSeconds(1800)
    check(!state.eligible, "Downgrading never repeats an already shown release")
    check(!StarInvitationState(release: "0.7.16/151").askedReleases.contains("0.7.16/151"), "Separate profiles have separate invitation history")
}
