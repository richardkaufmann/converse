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
    // "interrupted": a reply already in the receiving transcript whose turn did
    // not finish. Replies carry no obligation, so this is never a failure.
    var terminal: Bool { ["resolved", "completed", "failed", "interrupted", "escalated", "cancelled"].contains(state) }
    var displayState: String {
        switch state {
        case "queued": return intervenedAt == nil ? "Queued" : "Recovery queued"
        case "submitted": return finishedAt == nil ? "Processing" : "Awaiting reply"
        case "completed": return "Completed"
        case "resolved": return kind == "request" ? "Answered" : "Delivered"
        case "awaitingReceipt": return "Reply sent · awaiting receipt"
        case "interrupted": return "Reply delivered · turn interrupted"
        case "failed", "deliveryFailed": return "Failed"
        case "escalated": return "Needs attention"
        case "cancelled": return "Cancelled"
        default: return state
        }
    }
}
struct SwitchboardExpectation: Codable, Identifiable {
    var id: UUID
    var target: String
    var answered: Bool = false
}

extension Store {
    // Update the original receipt rather than leaving a permanent "Queued" label.
    // Only the receiving home can advance delivery state. Remote homes retain
    // their transport receipt until they supply a richer protocol in a later release.
    func refreshSwitchboardReceipts(_ target: Session) {
        target.objectWillChange.send()
        for item in target.switchboardObligations {
            guard let sender = sessions.first(where: { switchboardAddress($0.id.uuidString) == item.source }) else { continue }
            let marker = " · " + item.id.uuidString
            guard let index = sender.messages.lastIndex(where: { $0.role == "notice" && $0.text.hasPrefix("Switchboard:") && ($0.text.components(separatedBy: "\n").first?.contains(marker + " [") == true) && $0.text.contains("→") }),
                  let arrow = sender.messages[index].text.range(of: "→") else { continue }
            let updated = "Switchboard: " + item.displayState.lowercased() + " " + sender.messages[index].text[arrow.lowerBound...]
            if updated != sender.messages[index].text { sender.messages[index].text = updated }
        }
    }

    func switchboardRecoveryBlocker(_ session: Session, item: SwitchboardObligation, now: Date) -> String? {
        guard !applicationQuitting, session.switchboardEnabled, !session.queuePaused, !session.changingSetting,
              !session.compacting, !session.interrupted, session.requests.isEmpty,
              !session.status.localizedCaseInsensitiveContains("approval"),
              !session.status.localizedCaseInsensitiveContains("sign in") else { return "Session is paused, signing in, awaiting approval, or changing state." }
        if session.agent != nil && MainActor.assumeIsolated({ AgentConversation.shared.owns(session) }) { return "A spoken conversation owns this session." }
        guard !item.terminal, item.intervenedAt == nil else { return "Delivery is finished or its one recovery has already been used." }
        guard session.switchboardLastRecoveryAt.map({ now.timeIntervalSince($0) >= 120 }) ?? true else { return "Recovery cooldown is active." }
        if let group = item.groupID, let home = item.originHomeID {
            guard participantService.acceptsParticipant(home: home, groupID: group), participantService.participantOnline(home) else { return "The sender is no longer an online member of this group." }
        }
        if item.state == "queued", let home = DeviceGlobalID(item.source)?.home, home != participantService.localDeviceID {
            guard let report = participantService.switchboardQueueReports[home],
                  participantService.acceptsParticipant(home: home, groupID: report.report.groupID),
                  now.timeIntervalSince(report.at) >= 0, now.timeIntervalSince(report.at) <= 15 else { return "Waiting for fresh authenticated peer state." }
            if report.report.entries.contains(where: { $0.target == item.source && $0.source == switchboardAddress(session.id.uuidString) }) {
                return "Mutual remote queues use the elected-home recovery protocol."
            }
        }
        let queued = session.pending.contains { $0.id == item.promptID || ($0.components ?? []).contains { $0.id == item.promptID } }
        let quiet = !session.busy || session.switchboardProgress.map { $0.revision == session.messagesRevision && now.timeIntervalSince($0.at) >= 120 } == true
        if item.state == "queued", queued, now.timeIntervalSince(item.createdAt) >= 120, quiet { return nil }
        if item.kind == "request", item.state == "submitted", !session.busy,
           item.finishedAt.map({ now.timeIntervalSince($0) >= 30 }) == true { return nil }
        return "Delivery is progressing or has not reached its recovery deadline."
    }

    // Both agents and the automatic supervisor consume the SAME durable allowance.
    // No arbitrary injected text, invented delivery IDs, or overrides of human pauses.
    @discardableResult func recoverSwitchboard(_ target: Session, delivery: UUID, by supervisor: Session? = nil, now: Date = Date()) -> String? {
        if let supervisor {
            guard supervisor !== target, let config = supervisor.agent,
                  config.allows(local: target.id, home: participantService.localDeviceID) else { return "Recovery target is outside this agent's selected sessions." }
        }
        guard let index = target.switchboardObligations.firstIndex(where: { $0.id == delivery }) else { return "No authenticated delivery with that ID exists." }
        var item = target.switchboardObligations[index]
        if let blocker = switchboardRecoveryBlocker(target, item: item, now: now) { return blocker }
        let previous = item, previousPending = target.pending, previousRecovery = target.switchboardLastRecoveryAt
        item.intervenedAt = now; target.switchboardLastRecoveryAt = now
        if item.state == "submitted" {
            let prompt = PendingPrompt(switchboardHop: 0, originGroupID: item.groupID, originHomeID: item.originHomeID,
                autonomous: true, text: "[Converse switchboard recovery · request \(item.id.uuidString)]\nYour turn finished without the requested reply to \(item.sourceName) (\(item.source)). Send the answer, a blocker, or an explicit decline using tell with inReplyTo set to this full request UUID, copied exactly:\n\(item.id.uuidString)\nThis is the only automatic reminder; do not request a reply to this recovery notice.", images: [])
            item.promptID = prompt.id; item.state = "queued"; item.finishedAt = nil
            target.pending.insert(prompt, at: 0)
        }
        target.switchboardObligations[index] = item
        do { try saveChecked() } catch {
            target.switchboardObligations[index] = previous; target.pending = previousPending; target.switchboardLastRecoveryAt = previousRecovery
            return "Could not persist the recovery allowance. Nothing was injected."
        }
        target.messages.append(Message(role: "notice", text: "[Converse switchboard recovery] \(supervisor?.title ?? "Automatic supervisor") is injecting delivery \(delivery.uuidString) once. Draft preserved."))
        refreshSwitchboardReceipts(target)
        guard let pending = target.pending.first(where: { $0.id == item.promptID || ($0.components ?? []).contains { $0.id == item.promptID } }) else { return "Delivery is no longer queued." }
        return injectPending(target, id: pending.id)
    }

    func switchboardRecoveryEvidence(for supervisor: Session, now: Date = Date()) -> [[String: Any]] {
        sessions.filter { $0 !== supervisor && supervisor.agent?.allows(local: $0.id, home: participantService.localDeviceID) == true }.flatMap { target in
            target.switchboardObligations.suffix(32).map { item in
                ["target": switchboardAddress(target.id.uuidString), "delivery": item.id.uuidString,
                 "kind": item.kind, "state": item.displayState, "queued": target.pending.contains { $0.id == item.promptID },
                 "recoveryUsed": item.intervenedAt != nil, "canRecover": switchboardRecoveryBlocker(target, item: item, now: now) == nil,
                 "blocker": switchboardRecoveryBlocker(target, item: item, now: now) ?? "",
                 "observedAt": ISO8601DateFormatter().string(from: now)] as [String: Any]
            }
        }
    }
    func switchboardAddress(_ raw: String) -> String {
        if let id = UUID(uuidString: raw) {
            return participantService.localDeviceID.map { DeviceGlobalID(home: $0, session: id).string } ?? id.uuidString
        }
        return DeviceGlobalID(raw)?.string ?? raw
    }
    // Models sometimes garble a request UUID. Never drop the message: correct it
    // to the sender's own open request from that exact target, else send plainly.
    func switchboardResolveReply(_ source: Session, to: String, supplied: String?) -> (reply: UUID?, corrected: Bool) {
        guard let raw = supplied?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return (nil, false) }
        let address = switchboardAddress(to)
        let requests = source.switchboardObligations.filter { $0.kind == "request" && $0.source == address }
        if let exact = UUID(uuidString: raw), requests.contains(where: { $0.id == exact }) { return (exact, false) }
        let open = requests.filter { !["resolved", "cancelled"].contains($0.state) && ($0.replyDeliveryID == nil || $0.state == "deliveryFailed") }
        let head = String(raw.uppercased().prefix(8))
        let byPrefix = head.count == 8 && head.allSatisfy(\.isHexDigit) ? open.filter { $0.id.uuidString.hasPrefix(head) } : []
        if byPrefix.count == 1 { return (byPrefix[0].id, true) }
        if byPrefix.isEmpty, open.count == 1 { return (open[0].id, true) }
        return (nil, false)
    }
    func switchboardReplyNotice(supplied: String?, resolved: UUID?, corrected: Bool, targetName: String) -> String? {
        guard let raw = supplied?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if let resolved { return corrected ? "Switchboard: reply ID corrected to " + resolved.uuidString + " (supplied " + raw + ")" : nil }
        return "Switchboard: reply ID " + raw + " matched no open request from " + targetName + "; delivered as a plain tell."
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
            refreshSwitchboardReceipts(source)
        }
    }
    func switchboardReceipt(_ source: Session, delivery: UUID, accepted: Bool) {
        if !accepted, let index = source.switchboardExpectations.firstIndex(where: { $0.id == delivery }) { source.switchboardExpectations[index].answered = true }
        for index in source.switchboardObligations.indices where source.switchboardObligations[index].replyDeliveryID == delivery {
            source.switchboardObligations[index].state = accepted ? "resolved" : "deliveryFailed"
        }
        refreshSwitchboardReceipts(source)
    }
    func switchboardReceived(_ target: Session, source: String, name: String, id: UUID, prompt: PendingPrompt,
                             replyExpected: Bool, inReplyTo: UUID?, group: String? = nil, home: String? = nil) {
        // Retain recent terminal records for a visible last-delivery result.
        let retired = Set(target.switchboardObligations.filter { $0.terminal }.dropLast(63).map(\.id))
        target.switchboardObligations.removeAll { retired.contains($0.id) }
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
            session.switchboardObligations[index].state = "submitted"
            session.switchboardObligations[index].finishedAt = nil
        }
        refreshSwitchboardReceipts(session)
    }
    func switchboardTurnFinished(_ session: Session, now: Date = Date(), success: Bool = true) {
        for index in session.switchboardObligations.indices where session.switchboardObligations[index].state == "submitted" && session.switchboardObligations[index].finishedAt == nil {
            session.switchboardObligations[index].finishedAt = now
            if !success { session.switchboardObligations[index].state = session.switchboardObligations[index].kind == "reply" ? "interrupted" : "failed" }
            else if session.switchboardObligations[index].kind != "request" { session.switchboardObligations[index].state = "completed" }
        }
        refreshSwitchboardReceipts(session)
    }
    static func replyInstruction(id: UUID, expected: Bool, inReplyTo: UUID?) -> String {
        var result = inReplyTo.map { "\n[Reply to request \($0.uuidString)]" } ?? ""
        if expected { result += "\n[Reply expected · request ID:\n\(id.uuidString)\nReply with tell to the sender and set inReplyTo to that full request UUID, copied exactly (all 36 characters). Answer, report a blocker, or decline explicitly; an unrelated tell does not close this request.]" }
        return result
    }
    // Only authenticated delivery records participate. Never interpret a user's
    // pasted transcript as a request to interrupt another session.
    func recoverMutualSwitchboardQueues(now: Date) {
        func eligible(_ s: Session) -> Bool {
            if s.agent != nil && MainActor.assumeIsolated({ AgentConversation.shared.owns(s) }) { return false }
            return s.switchboardEnabled && !s.queuePaused && !s.changingSetting && !s.compacting && !s.interrupted && s.requests.isEmpty &&
            !s.status.localizedCaseInsensitiveContains("approval") && !s.status.localizedCaseInsensitiveContains("sign in") &&
            (s.switchboardProgress.map { $0.revision == s.messagesRevision && now.timeIntervalSince($0.at) >= 120 } == true) &&
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
            var changed = false
            for index in session.switchboardObligations.indices where session.switchboardObligations[index].state == "queued" {
                let id = session.switchboardObligations[index].promptID
                if !session.pending.contains(where: { $0.id == id || ($0.components ?? []).contains { $0.id == id } }) {
                    session.switchboardObligations[index].state = "cancelled"; changed = true
                }
            }
            if changed { refreshSwitchboardReceipts(session); save() }
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
                if let group = item.groupID, let home = item.originHomeID {
                    guard participantService.acceptsParticipant(home: home, groupID: group) else {
                        session.switchboardObligations[index].state = "cancelled"; save(); continue
                    }
                    guard participantService.participantOnline(home) else { continue }
                }
                let queued = session.pending.contains { $0.id == item.promptID || ($0.components ?? []).contains { $0.id == item.promptID } }
                let graceElapsed = item.finishedAt.map { now.timeIntervalSince($0) >= 30 } ?? false
                let quiet = !session.busy || session.switchboardProgress.map { now.timeIntervalSince($0.at) >= 120 } == true
                if item.state == "queued" && !queued { item.state = "cancelled"; session.switchboardObligations[index] = item; refreshSwitchboardReceipts(session); save(); continue }
                if switchboardRecoveryBlocker(session, item: item, now: now) == nil {
                    _ = recoverSwitchboard(session, delivery: item.id, now: now)
                } else if (item.intervenedAt.map { now.timeIntervalSince($0) >= 120 } == true &&
                           (graceElapsed || (queued && quiet))) ||
                          (["awaitingReceipt", "deliveryFailed"].contains(item.state) && graceElapsed) {
                    let unresolvedState = item.state
                    item.state = "escalated"; session.switchboardObligations[index] = item; refreshSwitchboardReceipts(session)
                    let text = "[Converse switchboard supervision · needs attention · \(item.id.uuidString)]\n\(session.title) ↔ \(item.sourceName): \(item.kind == "request" ? "reply expected but unresolved" : "delivery has not been processed"). State: \(unresolvedState); delivery \(item.replyDeliveryID?.uuidString ?? "not confirmed"). One automatic recovery at most; no further retries. Inspect the sessions and pending queues. This notice does not request a reply."
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
                        if cooledDown && (!watcher.busy || watcher.switchboardProgress.map({ $0.revision == watcher.messagesRevision && now.timeIntervalSince($0.at) >= 120 }) == true) {
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
