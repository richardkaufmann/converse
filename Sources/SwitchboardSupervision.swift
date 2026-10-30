import Foundation

// The receiving home owns each obligation. Reply IDs are matched against
// authenticated sender identities, never inferred from prose or acknowledgments.
struct SwitchboardObligation: Codable, Identifiable {
    var id: UUID
    var source: String
    var sourceName: String
    var promptID: UUID
    var kind: String = "request"
    var state: String = "queued"
    var createdAt: Date = Date()
    var finishedAt: Date?
    var intervenedAt: Date?
    var replyDeliveryID: UUID?
    var groupID: String?
    var originHomeID: String?
    var terminal: Bool { state == "resolved" || state == "escalated" || state == "cancelled" }
}
struct SwitchboardExpectation: Codable, Identifiable {
    var id: UUID
    var target: String
    var answered: Bool = false
}

extension Store {
    func switchboardAddress(_ raw: String) -> String {
        if let id = UUID(uuidString: raw) {
            return participantService.localDeviceID.map { DeviceGlobalID(home: $0, session: id).string } ?? id.uuidString
        }
        return DeviceGlobalID(raw)?.string ?? raw
    }
    func switchboardReplyError(_ source: Session, to: String, reply: UUID?) -> String? {
        guard let reply else { return nil }
        guard source.switchboardObligations.contains(where: {
            $0.id == reply && $0.kind == "request" && $0.source == switchboardAddress(to)
        }) else { return "Reply does not match a request from that session. Nothing was sent." }
        return nil
    }
    func switchboardSent(_ source: Session, to: String, id: UUID, replyExpected: Bool, inReplyTo: UUID?, remote: Bool) {
        if replyExpected {
            source.switchboardExpectations.removeAll { $0.answered }
            source.switchboardExpectations.append(SwitchboardExpectation(id: id, target: switchboardAddress(to)))
        }
        if let index = source.switchboardObligations.firstIndex(where: { $0.id == inReplyTo && $0.kind == "request" }) {
            source.switchboardObligations[index].state = remote ? "awaitingReceipt" : "resolved"
            source.switchboardObligations[index].replyDeliveryID = id
            source.switchboardObligations[index].finishedAt = Date()
        }
    }
    func switchboardReceipt(_ source: Session, delivery: UUID, accepted: Bool) {
        if !accepted, let index = source.switchboardExpectations.firstIndex(where: { $0.id == delivery }) { source.switchboardExpectations[index].answered = true }
        for index in source.switchboardObligations.indices where source.switchboardObligations[index].replyDeliveryID == delivery {
            source.switchboardObligations[index].state = accepted ? "resolved" : "deliveryFailed"
        }
    }
    func switchboardReceived(_ target: Session, source: String, name: String, id: UUID, prompt: PendingPrompt,
                             replyExpected: Bool, inReplyTo: UUID?, group: String? = nil, home: String? = nil) {
        target.switchboardObligations.removeAll { $0.terminal && $0.intervenedAt == nil }
        if inReplyTo == nil || replyExpected {
            target.switchboardObligations.append(SwitchboardObligation(id: id, source: switchboardAddress(source), sourceName: name,
                promptID: prompt.id, kind: replyExpected ? "request" : "delivery", groupID: group, originHomeID: home))
        }
        if let index = target.switchboardExpectations.firstIndex(where: {
            $0.id == inReplyTo && !$0.answered && $0.target == switchboardAddress(source)
        }) {
            target.switchboardExpectations[index].answered = true
            target.switchboardObligations.append(SwitchboardObligation(id: id, source: switchboardAddress(source), sourceName: name,
                promptID: prompt.id, kind: "reply", groupID: group, originHomeID: home))
        }
    }
    func switchboardStarted(_ session: Session, prompt: PendingPrompt) {
        let ids = Set([prompt.id] + (prompt.components ?? []).map(\.id))
        for index in session.switchboardObligations.indices where ids.contains(session.switchboardObligations[index].promptID) {
            session.switchboardObligations[index].state = session.switchboardObligations[index].kind != "request" ? "resolved" : "submitted"
            session.switchboardObligations[index].finishedAt = nil
        }
    }
    func switchboardTurnFinished(_ session: Session, now: Date = Date()) {
        for index in session.switchboardObligations.indices where session.switchboardObligations[index].state == "submitted" {
            session.switchboardObligations[index].finishedAt = now
        }
    }
    static func replyInstruction(id: UUID, expected: Bool, inReplyTo: UUID?) -> String {
        var result = inReplyTo.map { "\n[Reply to request \($0.uuidString)]" } ?? ""
        if expected { result += "\n[Reply expected · request \(id.uuidString). Reply with tell to the sender and inReplyTo: \"\(id.uuidString)\". Answer, report a blocker, or decline explicitly; an unrelated tell does not close this request.]" }
        return result
    }
    // Only authenticated delivery records participate. Never interpret a user's
    // pasted transcript as a request to interrupt another session.
    func recoverMutualSwitchboardQueues(now: Date) {
        func eligible(_ s: Session) -> Bool {
            s.switchboardEnabled && !s.queuePaused && !s.changingSetting && s.requests.isEmpty &&
            !s.status.localizedCaseInsensitiveContains("approval") && !s.status.localizedCaseInsensitiveContains("sign in") &&
            (s.switchboardProgress.map { now.timeIntervalSince($0.at) >= 120 } == true) &&
            (s.switchboardLastRecoveryAt.map { now.timeIntervalSince($0) >= 120 } ?? true)
        }
        func queued(_ s: Session, _ item: SwitchboardObligation) -> Bool {
            item.state == "queued" && item.intervenedAt == nil && now.timeIntervalSince(item.createdAt) >= 120 &&
            s.pending.contains { $0.id == item.promptID || ($0.components ?? []).contains { $0.id == item.promptID } }
        }
        var advertised: [DeviceQueueWatch] = []
        for a in sessions where eligible(a) {
            let local = switchboardAddress(a.id.uuidString)
            for item in a.switchboardObligations where queued(a, item) {
                advertised.append(DeviceQueueWatch(target: local, source: item.source, delivery: item.id))
            }
        }
        participantService.publishQueueWatch(advertised)
        // Exactly one home is elected by canonical address. An absent, paused,
        // recently active, disconnected or stale peer cannot authorize recovery.
        for a in sessions where eligible(a) {
            let local = switchboardAddress(a.id.uuidString)
            for index in a.switchboardObligations.indices where queued(a, a.switchboardObligations[index]) {
                let item = a.switchboardObligations[index]
                guard local < item.source, let peer = DeviceGlobalID(item.source), peer.home != participantService.localDeviceID,
                      participantService.participantOnline(peer.home),
                      let snapshot = participantService.switchboardQueueReports[peer.home],
                      now.timeIntervalSince(snapshot.at) >= 0, now.timeIntervalSince(snapshot.at) <= 15,
                      participantService.acceptsParticipant(home: peer.home, groupID: snapshot.report.groupID),
                      snapshot.report.entries.contains(where: { $0.target == item.source && $0.source == local }) else { continue }
                a.switchboardObligations[index].intervenedAt = now; a.switchboardLastRecoveryAt = now
                a.messages.append(Message(role: "notice", text: "[Converse switchboard recovery] Mutual queued messages with \(item.sourceName). Injecting the existing message once."))
                do { try saveChecked() } catch { return }
                if let prompt = a.pending.first(where: { $0.id == item.promptID || ($0.components ?? []).contains { $0.id == item.promptID } }) {
                    _ = injectPending(a, id: prompt.id)
                }
                break
            }
        }
        for a in sessions.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where eligible(a) {
            for ai in a.switchboardObligations.indices where queued(a, a.switchboardObligations[ai]) {
                let incoming = a.switchboardObligations[ai]
                guard let b = sessions.first(where: { switchboardAddress($0.id.uuidString) == incoming.source }),
                      a.id.uuidString < b.id.uuidString, eligible(b),
                      let bi = b.switchboardObligations.firstIndex(where: { $0.source == switchboardAddress(a.id.uuidString) && queued(b, $0) }) else { continue }
                // Consume BOTH sides' recovery budget before promoting either item.
                a.switchboardObligations[ai].intervenedAt = now
                b.switchboardObligations[bi].intervenedAt = now
                a.switchboardLastRecoveryAt = now; b.switchboardLastRecoveryAt = now
                a.messages.append(Message(role: "notice", text: "[Converse switchboard recovery] Mutual queued messages with \(b.title). Injecting the existing message once."))
                do { try saveChecked() } catch { return }
                let prompt = a.pending.first { $0.id == incoming.promptID || ($0.components ?? []).contains { $0.id == incoming.promptID } }
                if let prompt { _ = injectPending(a, id: prompt.id) }
                break
            }
        }
    }
    // Recovery uses the existing queue item, or one host-generated corrective
    // prompt. It never fabricates a second copy of the original delivery.
    func superviseSwitchboard(now: Date = Date()) {
        guard !applicationQuitting else { return }
        for session in sessions {
            if session.switchboardProgress?.revision != session.messagesRevision { session.switchboardProgress = (session.messagesRevision, now) }
        }
        recoverMutualSwitchboardQueues(now: now)
        for session in sessions {
            guard session.switchboardEnabled, !session.queuePaused, !session.changingSetting,
                  session.requests.isEmpty, !session.status.localizedCaseInsensitiveContains("approval"),
                  !session.status.localizedCaseInsensitiveContains("sign in") else { continue }
            for index in session.switchboardObligations.indices {
                var item = session.switchboardObligations[index]
                guard !item.terminal else { continue }
                if item.kind == "delivery" {
                    if !session.pending.contains(where: { $0.id == item.promptID || ($0.components ?? []).contains { $0.id == item.promptID } }) {
                        session.switchboardObligations[index].state = "cancelled"; save()
                    }
                    continue
                }
                if let group = item.groupID, let home = item.originHomeID {
                    guard participantService.acceptsParticipant(home: home, groupID: group) else {
                        session.switchboardObligations[index].state = "cancelled"; save(); continue
                    }
                    guard participantService.participantOnline(home) else { continue }
                }
                let queued = session.pending.contains { $0.id == item.promptID || ($0.components ?? []).contains { $0.id == item.promptID } }
                let graceElapsed = item.finishedAt.map { now.timeIntervalSince($0) >= 30 } ?? false
                let quiet = !session.busy || session.switchboardProgress.map { now.timeIntervalSince($0.at) >= 120 } == true
                let waitingOnPeer = session.switchboardExpectations.contains { !$0.answered && $0.target == item.source }
                let remotePairReady: Bool = {
                    guard let home = DeviceGlobalID(item.source)?.home, home != participantService.localDeviceID,
                          let report = participantService.switchboardQueueReports[home],
                          participantService.acceptsParticipant(home: home, groupID: report.report.groupID),
                          now.timeIntervalSince(report.at) >= 0, now.timeIntervalSince(report.at) <= 15 else { return false }
                    return report.report.entries.contains { $0.target == item.source && $0.source == switchboardAddress(session.id.uuidString) }
                }()
                let remoteHome = DeviceGlobalID(item.source)?.home
                let hasFreshPeer = remoteHome == nil || remoteHome == participantService.localDeviceID ||
                    remoteHome.flatMap { participantService.switchboardQueueReports[$0] }.map { now.timeIntervalSince($0.at) >= 0 && now.timeIntervalSince($0.at) <= 15 } == true
                let stuckQueue = hasFreshPeer && !remotePairReady && queued && now.timeIntervalSince(item.createdAt) >= 120 && quiet && (item.kind == "reply" || waitingOnPeer)
                if item.state == "queued" && !queued { item.state = "cancelled"; session.switchboardObligations[index] = item; save(); continue }
                let cooledDown = session.switchboardLastRecoveryAt.map { now.timeIntervalSince($0) >= 120 } ?? true
                if item.intervenedAt == nil && cooledDown && (stuckQueue || (item.state == "submitted" && graceElapsed && !session.busy)) {
                    // Reserve durably before interrupting; a crash cannot grant another attempt.
                    item.intervenedAt = now; session.switchboardLastRecoveryAt = now
                    if !queued {
                        let prompt = PendingPrompt(switchboardHop: 0, originGroupID: item.groupID, originHomeID: item.originHomeID,
                            autonomous: true, text: "[Converse switchboard recovery · request \(item.id.uuidString)]\nYour turn finished without the requested reply to \(item.sourceName) (\(item.source)). Send the answer, a blocker, or an explicit decline using tell with inReplyTo: \"\(item.id.uuidString)\". This is the only automatic reminder; do not request a reply to this recovery notice.", images: [])
                        item.promptID = prompt.id; item.state = "queued"; item.finishedAt = nil
                        session.pending.insert(prompt, at: 0)
                    }
                    session.switchboardObligations[index] = item
                    do { try saveChecked() } catch { session.queuePaused = true; continue }
                    if let pending = session.pending.first(where: { $0.id == item.promptID || ($0.components ?? []).contains { $0.id == item.promptID } }) {
                        _ = injectPending(session, id: pending.id)
                    }
                } else if (item.intervenedAt.map { now.timeIntervalSince($0) >= 120 } == true &&
                           (graceElapsed || (queued && quiet))) ||
                          (["awaitingReceipt", "deliveryFailed"].contains(item.state) && graceElapsed) {
                    let unresolvedState = item.state
                    item.state = "escalated"; session.switchboardObligations[index] = item
                    let text = "[Converse switchboard supervision · needs attention · \(item.id.uuidString)]\n\(session.title) ↔ \(item.sourceName): reply expected but unresolved. State: \(unresolvedState); delivery \(item.replyDeliveryID?.uuidString ?? "not confirmed"). One automatic recovery at most; no further retries. Inspect the sessions and pending queues. This notice does not request a reply."
                    session.messages.append(Message(role: "notice", text: text))
                    for watcher in sessions where watcher.id != session.id && watcher.agent.map({
                        $0.allows(local: session.id, home: participantService.localDeviceID) || $0.allows(global: item.source, home: participantService.localDeviceID)
                    }) == true {
                        // Preserve user pauses; enqueue once, never create a supervisory reply chain.
                        watcher.pending.append(PendingPrompt(switchboardHop: 0, autonomous: true, text: text, images: []))
                    }
                    do { try saveChecked() } catch { continue }
                    for watcher in sessions where !watcher.queuePaused && watcher.agent != nil && watcher.requests.isEmpty && !watcher.changingSetting {
                        guard let alert = watcher.pending.first(where: { $0.text == text }) else { continue }
                        let cooledDown = watcher.switchboardLastRecoveryAt.map { now.timeIntervalSince($0) >= 120 } ?? true
                        if cooledDown {
                            watcher.switchboardLastRecoveryAt = now
                            do { try saveChecked() } catch { continue }
                            _ = injectPending(watcher, id: alert.id)
                        }
                    }
                }
            }
        }
    }
}
