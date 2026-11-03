import AppKit
import CryptoKit
import Foundation
import Network
import Security

func deviceSyncSelfTests(_ check: (Bool, String) -> Void) {
    remoteMarkerSelfTests(check)
    let restoreRecord = DeviceOutboxRecord(commandID: UUID(), sessionID: "fixture", payload: DeviceCommandPayload(action: "submit", text: "old send", blobHashes: ["old-image"]), payloadHash: "fixture", outcome: "failed")
    let composer = RemoteComposer(); composer.draft = "new typing"; composer.blobHashes = ["new-image"]; composer.sentCommandID = restoreRecord.commandID
    composer.restoreFailedSend(restoreRecord)
    check(composer.draft == "new typing" && composer.blobHashes == ["new-image"] && composer.sentCommandID == nil, "Mac failed-send restore preserves newer text and images")
    composer.draft = ""; composer.blobHashes = []; composer.restoreFailedSend(restoreRecord)
    check(composer.draft == "old send" && composer.blobHashes == ["old-image"], "Mac failed-send restore fills an empty composer")
    let hydrating = RemoteComposer()
    check(hydrating.hydrate(text: "home draft", hashes: ["home-image"], key: "home@1", origin: "QA home (version 1)") && hydrating.draftOrigin.contains("QA home"), "Initial remote draft hydration names its home and version")
    hydrating.draft = "new local typing"
    let adoptedDirty = hydrating.hydrate(text: "stale home draft", hashes: [], key: "home@2", origin: "QA home (version 2)")
    check(!adoptedDirty && hydrating.hydrationConflict && hydrating.draft == "new local typing" && hydrating.blobHashes == ["home-image"], "Lease refresh cannot clobber a dirty remote composer or its images")
    hydrating.keepLocalDraft()
    check(!hydrating.hydrationConflict && hydrating.draft == "new local typing", "Keep my draft resolves hydration conflict without changing local input")
    hydrating.blobHashes = ["new local image"]
    check(!hydrating.hydrate(text: "new local typing", hashes: [], key: "home@3", origin: "QA home") && hydrating.blobHashes == ["new local image"], "Attachment-only edits are dirty during remote hydration")
    hydrating.useHomeDraft()
    check(!hydrating.hydrationConflict && hydrating.draft == "new local typing" && hydrating.blobHashes.isEmpty, "Use home draft explicitly adopts the offered text and attachment set")
    let cleanHydration = hydrating.hydrate(text: "new authoritative draft", hashes: [], key: "home@4", origin: "QA home")
    check(cleanHydration && hydrating.draft == "new authoritative draft", "Unedited remote composers adopt a fresh home draft normally")
    let outgoingPrompt = PairingPrompt(connectionID: UUID(), peerName: "Other Mac", fingerprint: "fingerprint", code: "code", keyChanged: false, isInitiator: true)
    let incomingPrompt = PairingPrompt(connectionID: UUID(), peerName: "Other Mac", fingerprint: "fingerprint", code: "code", keyChanged: false, isInitiator: false)
    check(outgoingPrompt.actionLabel == "Pair" && incomingPrompt.actionLabel == "Pair", "Group admission uses Pair on both the requesting and reviewing device")
    check(outgoingPrompt.instruction.contains("Pair on both devices") && incomingPrompt.instruction.contains("Pair on both devices"), "Pairing instructions require matching codes and Pair on both devices")
    // Framing: length-prefixed envelopes round-trip and reject oversize input.
    let commandID = UUID()
    let envelope = DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: "home/session", commandID: commandID, epoch: 3, payload: Data("hello".utf8))
    do {
        var decoder = DeviceFrameDecoder()
        var framed = try DeviceFrame.encode(envelope)
        framed.append(try DeviceFrame.encode(envelope))
        let decoded = try decoder.append(framed)
        check(decoded.count == 2 && decoded[0].commandID == commandID && decoded[0].epoch == 3 && decoded[0].payload == Data("hello".utf8), "Device frames round-trip two envelopes in one chunk")
        var partial = DeviceFrameDecoder()
        let single = try DeviceFrame.encode(envelope)
        check(try partial.append(Data(single.prefix(3))).isEmpty && partial.append(Data(single.dropFirst(3))).count == 1, "Device frames reassemble across chunk boundaries")
    } catch { check(false, "Device framing failed: " + error.localizedDescription) }
    check((try? DeviceFrame.encode(DeviceEnvelope(kind: "x", payload: Data(count: DeviceFrame.maxPayload + 1)))) == nil, "Oversize device frames are rejected before send")

    // Noise XX: fixed keys interop, equal SAS, encrypted payloads, tamper fails.
    func fixedKey(_ byte: UInt8) -> Curve25519.KeyAgreement.PrivateKey {
        try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
    }
    do {
        let initStatic = fixedKey(0x11), respStatic = fixedKey(0x22)
        var initiator = DeviceHandshake(isInitiator: true, staticKey: initStatic, ephemeralKey: fixedKey(0x33))
        var responder = DeviceHandshake(isInitiator: false, staticKey: respStatic, ephemeralKey: fixedKey(0x44))
        let m1 = try initiator.writeMessage(payload: Data("hello-a".utf8))
        check(m1.count == 32 + 7, "Noise XX first message is ephemeral key plus clear payload")
        check(try responder.readMessage(m1) == Data("hello-a".utf8), "Noise XX first payload reaches responder")
        let m2 = try responder.writeMessage(payload: Data("hello-b".utf8))
        check(m2.count == 32 + 48 + 7 + 16, "Noise XX second message carries encrypted static key and payload tag")
        check(try initiator.readMessage(m2) == Data("hello-b".utf8), "Noise XX second payload reaches initiator")
        let m3 = try initiator.writeMessage(payload: Data("hello-c".utf8))
        check(m3.count == 48 + 7 + 16, "Noise XX third message carries encrypted static key and payload tag")
        check(try responder.readMessage(m3) == Data("hello-c".utf8), "Noise XX third payload reaches responder")
        let a = try initiator.finish(), b = try responder.finish()
        check(a.remoteStatic == respStatic.publicKey.rawRepresentation && b.remoteStatic == initStatic.publicKey.rawRepresentation, "Noise XX authenticates both static keys")
        check(a.handshakeHash == b.handshakeHash && DeviceSAS.code(a.handshakeHash) == DeviceSAS.code(b.handshakeHash) && DeviceSAS.code(a.handshakeHash).filter { $0 != " " }.count == 32, "Both devices derive the same 128-bit pairing code")
        var aSend = a.sender, bRecv = b.receiver
        let sealed = try aSend.encrypt(Data("secret frame".utf8))
        check(!sealed.contains { $0 == 0x73 } || sealed != Data("secret frame".utf8), "Transport ciphertext is not plaintext")
        check(try bRecv.decrypt(sealed) == Data("secret frame".utf8), "Transport keys decrypt in order after handshake")
        var bRecv2 = b.receiver
        var tampered = sealed; tampered[tampered.startIndex] ^= 0xFF
        check((try? bRecv2.decrypt(tampered)) == nil, "Tampered transport ciphertext is rejected")
    } catch { check(false, "Noise XX failed: " + error.localizedDescription) }

    // External cacophony vector Noise_XX_25519_ChaChaPoly_SHA256 (snow test
    // vectors, prologue John Galt). Independent bytes catch init divergence.
    func hex(_ string: String) -> Data {
        var data = Data(); var index = string.startIndex
        while index < string.endIndex { let next = string.index(index, offsetBy: 2); data.append(UInt8(string[index..<next], radix: 16)!); index = next }
        return data
    }
    do {
        let prologue = hex("4a6f686e2047616c74")
        var vi = DeviceHandshake(isInitiator: true, staticKey: try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("e61ef9919cde45dd5f82166404bd08e38bceb5dfdfded0a34c8df7ed542214d1")), ephemeralKey: try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("893e28b9dc6ca8d611ab664754b8ceb7bac5117349a4439a6b0569da977c464a")), prologue: prologue)
        var vr = DeviceHandshake(isInitiator: false, staticKey: try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("4a3acbfdb163dec651dfa3194dece676d437029c62a408b4c5ea9114246e4893")), ephemeralKey: try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("bbdb4cdbd309f1a1f2e1456967fe288cadd6f712d65dc7b7793d5e63da6b375b")), prologue: prologue)
        let v1 = try vi.writeMessage(payload: hex("4c756477696720766f6e204d69736573"))
        check(v1 == hex("ca35def5ae56cec33dc2036731ab14896bc4c75dbb07a61f879f8e3afa4c79444c756477696720766f6e204d69736573"), "External Noise vector message one matches byte for byte")
        _ = try vr.readMessage(v1)
        let v2 = try vr.writeMessage(payload: hex("4d757272617920526f746862617264"))
        check(v2 == hex("95ebc60d2b1fa672c1f46a8aa265ef51bfe38e7ccb39ec5be34069f14480884381cbad1f276e038c48378ffce2b65285e08d6b68aaa3629a5a8639392490e5b9bd5269c2f1e4f488ed8831161f19b7815528f8982ffe09be9b5c412f8a0db50f8814c7194e83f23dbd8d162c9326ad"), "External Noise vector message two matches byte for byte")
        _ = try vi.readMessage(v2)
        let v3 = try vi.writeMessage(payload: hex("462e20412e20486179656b"))
        check(v3 == hex("c7195ffacac1307ff99046f219750fc47693e23c3cb08b89c2af808b444850a80ae475b9df0f169ae80a89be0865b57f58c9fea0d4ec82a286427402f113e4b6ae769a1d95941d49b25030"), "External Noise vector message three matches byte for byte")
        _ = try vr.readMessage(v3)
        var ka = try vi.finish(), kb = try vr.finish()
        check(ka.handshakeHash == hex("c8e5f64e846193be2a834104c2a009868d6c9f3bd3c186299888b488b2f1f58e"), "External Noise vector handshake hash matches")
        check(try kb.sender.encrypt(hex("4361726c204d656e676572")) == hex("96763ed773f8e47bb3712f0e29b3060ffc956ffc146cee53d5e1df"), "External Noise vector transport message matches")
        _ = ka
    } catch { check(false, "External Noise vector failed: " + error.localizedDescription) }

    // Lease fencing: steal increments epoch and invalidates the old holder.
    var clock = Date(timeIntervalSinceReferenceDate: 1_000)
    let leases = DeviceLeaseManager(now: { clock }, ttl: 15)
    let sessionID = UUID()
    let first = leases.acquire(session: sessionID, device: "device-a")
    check(first.granted && leases.validate(session: sessionID, device: "device-a", epoch: first.epoch), "First lease holder can act with its epoch")
    let second = leases.acquire(session: sessionID, device: "device-b")
    check(second.granted && second.epoch == first.epoch + 1 && !leases.validate(session: sessionID, device: "device-a", epoch: first.epoch) && leases.validate(session: sessionID, device: "device-b", epoch: second.epoch), "Takeover fences the stale holder with a new epoch")
    check(!leases.validate(session: sessionID, device: "device-b", epoch: first.epoch), "Correct device with stale epoch is still rejected")
    clock = clock.addingTimeInterval(16)
    check(!leases.validate(session: sessionID, device: "device-b", epoch: second.epoch), "Expired lease cannot act after its TTL")

    // Command durability: dedup by ID and uncertain recovery, never re-execute.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-device-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let commands = try DeviceCommandStore(folder: root)
        let id = UUID()
        check(try commands.begin(id: id, origin: "device-a"), "First command ID is accepted once")
        check(try commands.begin(id: id, origin: "device-a") == false, "Duplicate command ID is deduplicated")
        try commands.markRunning(id: id)
        let reloaded = try DeviceCommandStore(folder: root)
        check(reloaded.outcome(id: id) == .uncertain, "Running command without terminal record recovers as uncertain")
        check(try reloaded.begin(id: id, origin: "device-a") == false, "Uncertain command is never automatically resubmitted")
        let doneID = UUID()
        _ = try reloaded.begin(id: doneID, origin: "device-a"); try reloaded.markRunning(id: doneID); try reloaded.markCompleted(id: doneID)
        check(try DeviceCommandStore(folder: root).outcome(id: doneID) == .completed, "Completed command outcome survives reload")
    } catch { check(false, "Command store failed: " + error.localizedDescription) }

    // Draft versions, blob hashes, trust pinning, and global session identity.
    var drafts = DeviceDraftTracker()
    check(drafts.apply(session: sessionID.uuidString, version: 2, text: "new") && !drafts.apply(session: sessionID.uuidString, version: 1, text: "old") && drafts.text(session: sessionID.uuidString) == "new", "Stale draft patches cannot overwrite newer home drafts")
    let blob = Data("image-bytes".utf8)
    check(DeviceBlob.verify(blob, sha256Hex: DeviceBlob.sha256Hex(blob)) && !DeviceBlob.verify(blob, sha256Hex: DeviceBlob.sha256Hex(Data("other".utf8))), "Attachment blobs verify by SHA-256 before use")
    do {
        let trust = try DeviceTrustStore(folder: root)
        let keyA = fixedKey(0x55).publicKey.rawRepresentation, keyB = fixedKey(0x66).publicKey.rawRepresentation
        try trust.pin(deviceID: "peer-1", name: "Studio Mac", publicKey: keyA)
        check(trust.check(deviceID: "peer-1", publicKey: keyA) == .trusted && trust.check(deviceID: "peer-1", publicKey: keyB) == .keyChanged && trust.check(deviceID: "peer-2", publicKey: keyA) == .unknown, "Pinned device keys detect trust, key change, and unknown peers")
        try trust.forget(deviceID: "peer-1")
        check(trust.check(deviceID: "peer-1", publicKey: keyA) == .unknown, "Forgotten devices must pair again")
    } catch { check(false, "Trust store failed: " + error.localizedDescription) }
    // Review repros: persisted epochs, draft adoption, outbox identity.
    do {
        let stateStore = try DeviceSyncStateStore(folder: root)
        _ = stateStore.beginBoot()
        let storeRef = stateStore
        let before = DeviceLeaseManager(initialEpochs: storeRef.loadedEpochs) { storeRef.saveEpochs($0) }
        let oldEpoch = before.acquire(session: sessionID, device: "viewer").epoch
        let restartedStore = try DeviceSyncStateStore(folder: root)
        let restarted = DeviceLeaseManager(initialEpochs: restartedStore.loadedEpochs) { restartedStore.saveEpochs($0) }
        let freshEpoch = restarted.acquire(session: sessionID, device: "viewer").epoch
        check(freshEpoch > oldEpoch && !restarted.validate(session: sessionID, device: "viewer", epoch: oldEpoch), "Persisted epochs never reuse a pre-restart token")
        var homeDraft = DeviceDraftTracker(); var viewerDraft = DeviceDraftTracker()
        _ = homeDraft.apply(session: sessionID.uuidString, version: 5, text: "preserved draft")
        viewerDraft.adopt(session: sessionID.uuidString, version: 5, text: "preserved draft")
        let adopted = viewerDraft.bump(session: sessionID.uuidString, text: "new holder edit")
        check(adopted == 6 && homeDraft.apply(session: sessionID.uuidString, version: adopted, text: "new holder edit"), "New holder adopts home draft version before editing")
        let outboxStore = try DeviceOutboxStore(folder: root)
        let payload = DeviceCommandPayload(action: "submit", text: "keep me")
        let record = DeviceOutboxRecord(commandID: UUID(), sessionID: "home/session", payload: payload, payloadHash: "hash")
        try outboxStore.add(record)
        try outboxStore.markUncertain(sessionID: "home/session")
        let reloadedOutbox = try DeviceOutboxStore(folder: root)
        check(reloadedOutbox.records.first?.commandID == record.commandID && reloadedOutbox.records.first?.outcome == "uncertain" && reloadedOutbox.records.first?.payload.text == "keep me", "Viewer outbox retains text and same command ID as uncertain")
        let bound = try DeviceCommandStore(folder: root.appendingPathComponent("bound"))
        let boundID = UUID()
        _ = try bound.begin(id: boundID, origin: "a", sessionID: "s1", payloadHash: "h1")
        check(bound.bindingMatches(id: boundID, origin: "a", sessionID: "s1", payloadHash: "h1") && !bound.bindingMatches(id: boundID, origin: "a", sessionID: "s2", payloadHash: "h1"), "Dedup binds origin, session and payload hash")
        check(DeviceIdentity.keychainDecision(status: errSecItemNotFound) && !DeviceIdentity.keychainDecision(status: errSecAuthFailed), "Only missing Keychain item may create a new identity")
        var sweepClock = Date(timeIntervalSinceReferenceDate: 5_000)
        let sweeping = DeviceLeaseManager(now: { sweepClock }, ttl: 10)
        _ = sweeping.acquire(session: sessionID, device: "old-holder")
        sweepClock = sweepClock.addingTimeInterval(11)
        check(sweeping.sweepExpired().first?.device == "old-holder" && sweeping.holder(session: sessionID) == nil, "Expired leases sweep so streaming stops for former holders")
    } catch { check(false, "Review repro regressions failed: " + error.localizedDescription) }
    // Loopback integration: real NWListener/NWConnection carry the Noise
    // handshake and an encrypted frame on 127.0.0.1 with an ephemeral port.
    do {
        final class Side {
            var connection: NWConnection?
            var buffer = Data()
            var messages: [Data] = []
            var handshake: DeviceHandshake?
            var keys: DeviceTransportKeys?
            var plain = ""
            func frame(_ data: Data) -> Data { var f = Data(count: 2); f.withUnsafeMutableBytes { $0.storeBytes(of: UInt16(data.count).bigEndian, as: UInt16.self) }; return f + data }
            func drain() {
                while buffer.count >= 2 {
                    let len = buffer.prefix(2).reduce(0) { ($0 << 8) | Int($1) }
                    guard buffer.count >= 2 + len else { return }
                    messages.append(Data(buffer.dropFirst(2).prefix(len))); buffer.removeFirst(2 + len)
                }
            }
            func receive() {
                connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, _ in
                    guard let self else { return }
                    if let data, !data.isEmpty { self.buffer.append(data); self.drain() }
                    if !done { self.receive() }
                }
            }
            func send(_ data: Data) { connection?.send(content: frame(data), completion: .idempotent) }
        }
        let listener = try NWListener(using: .tcp)
        let responder = Side(), initiator = Side()
        responder.handshake = DeviceHandshake(isInitiator: false, staticKey: fixedKey(0x22), ephemeralKey: fixedKey(0x44))
        initiator.handshake = DeviceHandshake(isInitiator: true, staticKey: fixedKey(0x11), ephemeralKey: fixedKey(0x33))
        var listenPort: NWEndpoint.Port?
        listener.stateUpdateHandler = { if case .ready = $0 { listenPort = listener.port } }
        listener.newConnectionHandler = { connection in responder.connection = connection; connection.start(queue: .main); responder.receive() }
        listener.start(queue: .main)
        func pump(_ done: () -> Bool) { let deadline = Date().addingTimeInterval(10); while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) } }
        pump { listenPort != nil }
        check(listenPort != nil, "Loopback listener binds an ephemeral port")
        let outgoing = NWConnection(host: "127.0.0.1", port: listenPort!, using: .tcp)
        initiator.connection = outgoing; outgoing.start(queue: .main); initiator.receive()
        initiator.send(try initiator.handshake!.writeMessage(payload: Data("loop-a".utf8)))
        pump { !responder.messages.isEmpty }
        _ = try responder.handshake!.readMessage(responder.messages.removeFirst())
        responder.send(try responder.handshake!.writeMessage(payload: Data("loop-b".utf8)))
        pump { !initiator.messages.isEmpty }
        _ = try initiator.handshake!.readMessage(initiator.messages.removeFirst())
        initiator.send(try initiator.handshake!.writeMessage(payload: Data("loop-c".utf8)))
        pump { !responder.messages.isEmpty }
        _ = try responder.handshake!.readMessage(responder.messages.removeFirst())
        initiator.keys = try initiator.handshake!.finish(); responder.keys = try responder.handshake!.finish()
        initiator.send(try initiator.keys!.sender.encrypt(Data("loopback secret".utf8)))
        pump { !responder.messages.isEmpty }
        responder.plain = String(decoding: try responder.keys!.receiver.decrypt(responder.messages.removeFirst()), as: UTF8.self)
        check(responder.plain == "loopback secret", "Loopback Network transport carries Noise handshake and encrypted frame")
        outgoing.cancel(); responder.connection?.cancel(); listener.cancel()
    } catch { check(false, "Loopback integration failed: " + error.localizedDescription) }
    // MITM grinding regression (review reproduction): two attacker legs
    // with different keys must not share the 128-bit verification code.
    do {
        func codeForLeg(attackerStatic: Curve25519.KeyAgreement.PrivateKey, victimStatic: Curve25519.KeyAgreement.PrivateKey, victimInitiator: Bool) throws -> String {
            var victim = DeviceHandshake(isInitiator: victimInitiator, staticKey: victimStatic, ephemeralKey: fixedKey(0x51))
            var attacker = DeviceHandshake(isInitiator: !victimInitiator, staticKey: attackerStatic, ephemeralKey: fixedKey(0x52))
            if victimInitiator {
                _ = try attacker.readMessage(try victim.writeMessage(payload: Data("hello-victim".utf8)))
                _ = try victim.readMessage(try attacker.writeMessage(payload: Data("hello-attacker".utf8)))
                _ = try attacker.readMessage(try victim.writeMessage(payload: Data("hello-victim".utf8)))
            } else {
                _ = try victim.readMessage(try attacker.writeMessage(payload: Data("hello-attacker".utf8)))
                _ = try attacker.readMessage(try victim.writeMessage(payload: Data("hello-victim".utf8)))
                _ = try victim.readMessage(try attacker.writeMessage(payload: Data("hello-attacker".utf8)))
            }
            return DeviceSAS.code(try victim.finish().handshakeHash)
        }
        let legA = try codeForLeg(attackerStatic: fixedKey(0x61), victimStatic: fixedKey(0x11), victimInitiator: true)
        let legB = try codeForLeg(attackerStatic: fixedKey(0x62), victimStatic: fixedKey(0x22), victimInitiator: false)
        check(legA != legB && legA.filter { $0 != " " }.count == 32, "MITM legs with different keys show different 128-bit codes")
        var h1 = Data(count: 32), h2 = Data(count: 32); h2[10] = 9
        check(DeviceSAS.code(h1) != DeviceSAS.code(h2), "Verification code covers bits beyond the old four-byte truncation")
    } catch { check(false, "MITM SAS regression failed: " + error.localizedDescription) }

    // Service-level harness: isolated home service, fake authenticated peer.
    do {
        let home = DeviceSyncService()
        try home.configureForTesting(folder: root.appendingPathComponent("harness"))
        guard let entry = Store.shared.entries.first, let homeIdentity = home.identity else {
            check(false, "Harness needs a catalog entry and identity")
            throw NSError(domain: "harness", code: 1)
        }
        let session = Store.shared.create(entry)
        session.title = "Harness session"; session.draft = "home draft"
        let originalEngine = session.entry.engine
        session.entry.engine = "codex"; session.remoteID = "compact-fixture"
        session.toolStatus.accountUsage = AccountUsage(context: ContextUsage(tokens: 85, capacity: 100, observedAt: Date()))
        session.messages = (0..<10).map { Message(role: $0 < 3 ? "user" : "activity", text: "prefix \($0)") } + (0..<200).map { Message(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "message \($0)\nsecond line") }
        session.messages[10].createdAt = Date(timeIntervalSince1970: 1793389200.125)
        let draftImage = root.appendingPathComponent("draft-image.png")
        let draftBytes = Data("isolated image transfer fixture".utf8)
        try draftBytes.write(to: draftImage); session.attachments = [draftImage.path]
        var viewerHS = DeviceHandshake(isInitiator: true, staticKey: fixedKey(0x77), ephemeralKey: fixedKey(0x33))
        var homeHS = DeviceHandshake(isInitiator: false, staticKey: homeIdentity.privateKey, ephemeralKey: fixedKey(0x44))
        _ = try homeHS.readMessage(try viewerHS.writeMessage(payload: Data("v".utf8)))
        _ = try viewerHS.readMessage(try homeHS.writeMessage(payload: Data("h".utf8)))
        _ = try homeHS.readMessage(try viewerHS.writeMessage(payload: Data("v".utf8)))
        var viewerKeys = try viewerHS.finish()
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: false, displayName: "Viewer")
        peer.hello = DeviceHello(deviceID: DeviceBlob.sha256Hex(fixedKey(0x77).publicKey.rawRepresentation), deviceName: "Viewer", converseVersion: "test")
        peer.keys = try homeHS.finish(); peer.trustedReady = true
        var captured: [Data] = []
        peer.testSink = { captured.append($0) }
        home.adoptPeerForTesting(peer)
        func capturedEnvelopes() throws -> [DeviceEnvelope] {
            var decoder = DeviceFrameDecoder(); var out: [DeviceEnvelope] = []
            for chunk in captured { out.append(contentsOf: try decoder.append(try viewerKeys.receiver.decrypt(chunk))) }
            return out
        }
        // Remote sidebar markers: the home populates them and a pause,
        // unpause or new response republishes the sidebar.
        func publishedRow(_ id: UUID) throws -> DeviceSidebarRow? {
            captured = []; home.publishSidebarForTesting()
            return try capturedEnvelopes().filter { $0.kind == DeviceMessageKind.sidebarSnapshot.rawValue }
                .compactMap { $0.payload.flatMap { try? JSONDecoder().decode(DeviceSidebarPayload.self, from: $0) } }.last?.rows.first { $0.sessionID == id }
        }
        let firstMarkerRow = try publishedRow(session.id)
        let homeResponse = session.messages.last { $0.role == "assistant" }?.createdAt
        check(homeResponse != nil && firstMarkerRow?.lastResponseAt == homeResponse && firstMarkerRow?.loopPaused == nil && firstMarkerRow?.pausedReason == nil, "Mac home sidebar carries lastResponseAt and no loop marker for ordinary sessions")
        let markerMessages = session.messages
        let freshAt = (homeResponse ?? Date()).addingTimeInterval(60)
        session.messages.append(Message(role: "assistant", text: "fresh answer", createdAt: freshAt))
        check(try publishedRow(session.id)?.lastResponseAt == freshAt, "A new home response republishes the sidebar with a newer lastResponseAt")
        session.messages = markerMessages
        let markerAgent = Session(entry: Entry(name: "Steward", command: "", directory: NSTemporaryDirectory(), engine: "agent"))
        markerAgent.agent = AgentConfig(); markerAgent.agent?.attention = "Over budget."
        Store.shared.sessions.append(markerAgent)
        let pausedRow = try publishedRow(markerAgent.id)
        check(pausedRow?.loopPaused == true && pausedRow?.pausedReason == "Over budget." && pausedRow?.showsLoopPaused == true, "A paused home agent publishes loopPaused with its reason")
        markerAgent.agent?.enabled = true
        let resumedRow = try publishedRow(markerAgent.id)
        check(resumedRow?.loopPaused == false && resumedRow?.pausedReason == nil && resumedRow?.showsLoopPaused == false, "Re-enabling the loop republishes the row unpaused")
        markerAgent.agent?.enabled = false
        check(try publishedRow(markerAgent.id)?.loopPaused == true, "Pausing again republishes the paused marker")
        Store.shared.sessions.removeAll { $0.id == markerAgent.id }
        captured = []
        let lot = try home.parkingLibrary.create(name: "Shared ideas")
        let lotID = DeviceGlobalID(home: homeIdentity.deviceID, session: lot.id).string
        var lotRows = lot.document.rows; lotRows[1].images = [draftImage.path]
        try lot.replaceUserRows(lotRows, revision: lot.document.revision)
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseAcquire.rawValue, sessionID: lotID))
        let lotFrames = try capturedEnvelopes(); captured = []
        let lotSnapshot = lotFrames.compactMap { $0.payload.flatMap { try? JSONDecoder().decode(DeviceTranscriptPayload.self, from: $0) } }.first
        check(lotSnapshot?.engine == "parking" && lotSnapshot?.title == "Shared ideas" && lotSnapshot?.draft == "" && lotSnapshot?.epoch == 0, "Group viewers receive read-only named Parking Lot snapshots")
        let lotBlobRequest = DeviceEnvelope(kind: DeviceMessageKind.blobRequest.rawValue, sessionID: lotID, epoch: 0,
            payload: try JSONEncoder().encode(DeviceBlobPayload(sha256Hex: DeviceBlob.sha256Hex(draftBytes))))
        home.handleEnvelope(peer, lotBlobRequest)
        let lotBlobFrames = try capturedEnvelopes(); captured = []
        let lotBlob = lotBlobFrames.first { $0.kind == DeviceMessageKind.blobData.rawValue }?.payload.flatMap { try? JSONDecoder().decode(DeviceBlobPayload.self, from: $0) }
        check(lotBlob?.chunk == draftBytes && lotBlob?.done == true, "An authenticated lot subscriber downloads its item image without a session editing lease")
        var deniedBlob = lotBlobRequest; deniedBlob.epoch = 99
        home.handleEnvelope(peer, deniedBlob)
        check(captured.isEmpty, "Lot image requests reject a nonzero subscription epoch")
        let otherLot = try home.parkingLibrary.create(name: "Other images")
        deniedBlob = lotBlobRequest; deniedBlob.sessionID = DeviceGlobalID(home: homeIdentity.deviceID, session: otherLot.id).string
        peer.leasedSessions.insert(otherLot.id)
        home.handleEnvelope(peer, deniedBlob)
        check(captured.isEmpty, "A lot subscription cannot fetch an image belonging only to another lot")
        peer.leasedSessions.remove(otherLot.id); try home.parkingLibrary.delete(otherLot.id)
        peer.trustedReady = false; home.handleEnvelope(peer, lotBlobRequest); peer.trustedReady = true
        check(captured.isEmpty, "An untrusted peer cannot fetch a known lot image")
        let reader = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: false, displayName: "Second reader")
        reader.hello = DeviceHello(deviceID: "second-reader", deviceName: "Second reader", converseVersion: "test")
        reader.keys = peer.keys; reader.trustedReady = true; reader.testSink = { _ in }
        home.adoptPeerForTesting(reader)
        home.handleEnvelope(reader, DeviceEnvelope(kind: DeviceMessageKind.leaseAcquire.rawValue, sessionID: lotID))
        check(peer.leasedSessions.contains(lot.id) && reader.leasedSessions.contains(lot.id) && captured.isEmpty, "Two viewers can read a lot without displacing each other")
        let beforeRemoteEdit = lot.document
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: lotID, commandID: UUID(), epoch: 0,
            payload: try JSONEncoder().encode(DeviceCommandPayload(action: "submit", text: "overwrite"))))
        let rejectedLot = try capturedEnvelopes(); captured = []
        let lotAck = rejectedLot.compactMap { $0.payload.flatMap { try? JSONDecoder().decode(DeviceAckPayload.self, from: $0) } }.first
        check(lotAck?.outcome == "rejected" && lot.document == beforeRemoteEdit, "Home rejects commands that attempt to mutate a viewed Parking Lot")
        lot.update(lot.document.rows[1].id, text: "New shared idea")
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.transcriptRequest.rawValue, sessionID: lotID, epoch: 0))
        let updatedLot = try capturedEnvelopes(); captured = []
        check(updatedLot.compactMap { $0.payload.flatMap { try? JSONDecoder().decode(DeviceTranscriptPayload.self, from: $0) } }.first?.messages.contains { $0.text.contains("New shared idea") } == true, "A subscribed viewer receives current note edits")
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseRelease.rawValue, sessionID: lotID, epoch: 0))
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.transcriptRequest.rawValue, sessionID: lotID, epoch: 0))
        check(captured.isEmpty && !peer.leasedSessions.contains(lot.id) && reader.leasedSessions.contains(lot.id), "Parking one lot viewer leaves another reader subscribed and stops its own snapshots")
        home.handleEnvelope(peer, lotBlobRequest)
        check(captured.isEmpty, "A parked lot viewer cannot download its images without a current subscription")
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseResume.rawValue, sessionID: lotID, epoch: 0))
        _ = try capturedEnvelopes(); captured = []
        check(peer.leasedSessions.contains(lot.id), "A read-only lot subscription can resume after reconnect")
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseRelease.rawValue, sessionID: lotID, epoch: 0))
        home.handleEnvelope(reader, DeviceEnvelope(kind: DeviceMessageKind.leaseRelease.rawValue, sessionID: lotID, epoch: 0))
        reader.trustedReady = false
        home.handleEnvelope(reader, DeviceEnvelope(kind: DeviceMessageKind.leaseAcquire.rawValue, sessionID: lotID))
        check(!reader.leasedSessions.contains(lot.id), "An untrusted peer cannot subscribe to Parking Lot contents")
        try home.parkingLibrary.delete(lot.id)
        peer.leasedSessions.insert(lot.id); home.handleEnvelope(peer, lotBlobRequest); peer.leasedSessions.remove(lot.id)
        check(captured.isEmpty, "Deleting a lot revokes image access even for a stale reader subscription")
        let globalString = DeviceGlobalID(home: homeIdentity.deviceID, session: session.id).string
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.leaseAcquire.rawValue, sessionID: globalString))
        let grantFrames = try capturedEnvelopes()
        let granted = grantFrames.first { $0.kind == DeviceMessageKind.leaseGranted.rawValue }
        let snapshot = grantFrames.compactMap { $0.payload.flatMap { try? JSONDecoder().decode(DeviceTranscriptPayload.self, from: $0) } }.first
        check(granted != nil && snapshot?.draft == "home draft" && snapshot?.epoch == granted?.epoch, "Service harness grants lease and streams matching home snapshot")
        check(snapshot?.draftImageHashes == [DeviceBlob.sha256Hex(draftBytes)], "Home snapshot carries staged draft attachment hashes for takeover")
        check(snapshot?.messages.first?.createdAt == session.messages[10].createdAt, "Home snapshot preserves original message timestamp")
        let timestampViewer = RemoteComposer()
        timestampViewer.updateEditor(transcript: snapshot, cache: [:])
        check(timestampViewer.editor.messages.first?.createdAt == session.messages[10].createdAt, "Remote editor preserves home timestamp for native message-number tooltip")
        let legacyMessage = try JSONDecoder().decode(DeviceWireMessage.self, from: Data("{\"id\":\"00000000-0000-4000-8000-000000000001\",\"role\":\"user\",\"text\":\"Old history\",\"imageHashes\":[]}".utf8))
        check(legacyMessage.createdAt == nil, "Older remote history never invents timestamps")
        let interopMessage = try JSONDecoder().decode(DeviceWireMessage.self, from: Data("{\"id\":\"00000000-0000-4000-8000-000000000001\",\"role\":\"user\",\"text\":\"Interop\",\"imageHashes\":[],\"createdAtUnixSeconds\":1793389200.125}".utf8))
        check(interopMessage.createdAt?.timeIntervalSince1970 == 1793389200.125, "Remote timestamps use Unix seconds including fractional precision across platforms")

        check(snapshot?.offset == 10 && snapshot?.messages.first?.messageNumber == 4 && snapshot?.messages.last?.messageNumber == 203, "Home paged snapshot numbers visible messages across hidden prefix activity")
        check(snapshot?.compaction?.recommended == true && snapshot?.compaction?.percent == 85, "Home advertises measured compaction state to a leased viewer")
        session.busy = true // Exercise remote queueing without starting any provider.
        let compactID = UUID(), compactPayload = try JSONEncoder().encode(DeviceCommandPayload(action: "compact"))
        captured = []
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalString, commandID: UUID(), epoch: (granted?.epoch ?? 0) + 1, payload: compactPayload))
        check(!session.compactionRequested, "Remote compaction rejects a stale display lease")
        _ = try capturedEnvelopes(); captured = []
        let compactEnvelope = DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalString, commandID: compactID, epoch: granted?.epoch, payload: compactPayload)
        home.handleEnvelope(peer, compactEnvelope)
        _ = try capturedEnvelopes(); captured = []
        home.handleEnvelope(peer, compactEnvelope)
        check(session.compactionRequested && !session.compacting && session.draft == "home draft", "Remote duplicate compaction queues one intent and preserves the home draft")
        _ = try capturedEnvelopes(); captured = []
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalString, commandID: UUID(), epoch: granted?.epoch, payload: try JSONEncoder().encode(DeviceCommandPayload(action: "cancelCompact"))))
        check(!session.compactionRequested && session.busy, "Remote cancel removes only the waiting compaction, leaving the turn running")
        _ = try capturedEnvelopes()
        session.busy = false; session.entry.engine = originalEngine; session.remoteID = nil
        captured = []
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.transcriptRequest.rawValue, sessionID: globalString, epoch: granted?.epoch, payload: try JSONEncoder().encode(DeviceTranscriptRequest(beforeOffset: 10))))
        let earlier = try capturedEnvelopes().compactMap { frame in frame.kind == DeviceMessageKind.transcriptSnapshot.rawValue ? frame.payload.flatMap { try? JSONDecoder().decode(DeviceTranscriptPayload.self, from: $0) } : nil }.first
        check(earlier?.prepend == true && earlier?.offset == 0 && earlier?.messages.compactMap(\.messageNumber) == [1, 2, 3], "Earlier home page keeps original message ordinals and omits hidden activity ordinals")
        captured = []
        let renameID = UUID()
        let renamePayload = try JSONEncoder().encode(DeviceCommandPayload(action: "rename", text: "Renamed remotely"))
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalString, commandID: renameID, epoch: (granted?.epoch ?? 0) + 99, payload: renamePayload))
        check(session.title == "Harness session", "Service harness rejects stale-epoch commands without applying them")
        _ = try capturedEnvelopes()
        captured = []
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalString, commandID: renameID, epoch: granted?.epoch, payload: renamePayload))
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalString, commandID: renameID, epoch: granted?.epoch, payload: renamePayload))
        let ackCount = try capturedEnvelopes().filter { $0.kind == DeviceMessageKind.commandAck.rawValue }.count
        check(session.title == "Renamed remotely" && ackCount >= 2, "Service harness applies valid command once and acks duplicate without reapplying")
        captured = []
        let patch = DeviceDraftPayload(version: (snapshot?.draftVersion ?? 0) + 1, text: "transferred draft", imageHashes: [DeviceBlob.sha256Hex(draftBytes)])
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.draftPatch.rawValue, sessionID: globalString, epoch: granted?.epoch, payload: try JSONEncoder().encode(patch)))
        check(session.draft == "transferred draft" && session.attachments == [draftImage.path], "Home persists remote draft text and verified attachments together")
        _ = try capturedEnvelopes(); captured = []
        let settingID = UUID(); session.busy = true
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalString, commandID: settingID, epoch: granted?.epoch, payload: try JSONEncoder().encode(DeviceCommandPayload(action: "effort", effort: "high"))))
        let settingAck = try capturedEnvelopes().first { $0.commandID == settingID }.flatMap { $0.payload }.flatMap { try? JSONDecoder().decode(DeviceAckPayload.self, from: $0) }
        check(session.choices.effort == "high" && settingAck?.outcome == "completed", "Busy home accepts next-turn settings and acknowledges saved selection")
        let queuedA = PendingPrompt(text: "first queued", images: [])
        let queuedB = PendingPrompt(text: "second queued", images: [])
        session.pending = [queuedA, queuedB]
        let independentDraft = session.draft
        func injectAck(_ command: DeviceCommandPayload) throws -> DeviceAckPayload? {
            captured = []
            let id = UUID()
            home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalString, commandID: id, epoch: granted?.epoch, payload: try JSONEncoder().encode(command)))
            return try capturedEnvelopes().first { $0.commandID == id && $0.kind == DeviceMessageKind.commandAck.rawValue }?.payload.flatMap { try? JSONDecoder().decode(DeviceAckPayload.self, from: $0) }
        }
        let staleInject = try injectAck(DeviceCommandPayload(action: "inject", pendingID: UUID()))
        check(staleInject?.outcome == "failed" && staleInject?.detail?.contains("no longer available") == true && session.pending.map(\.id) == [queuedA.id, queuedB.id], "Stale Inject now reports failure and leaves other queued items untouched")
        session.changingSetting = true
        let settingInject = try injectAck(DeviceCommandPayload(action: "inject", pendingID: queuedB.id))
        session.changingSetting = false
        check(settingInject?.outcome == "failed" && settingInject?.detail?.contains("setting") == true && session.pending.first?.id == queuedA.id, "Inject while settings change receives an explicit failure instead of false completion")
        let missingInject = try injectAck(DeviceCommandPayload(action: "inject"))
        check(missingInject?.outcome == "failed" && session.pending.count == 2, "Malformed single-item injection cannot silently inject the whole queue")
        let validInject = try injectAck(DeviceCommandPayload(action: "inject", pendingID: queuedB.id))
        check(validInject?.outcome == "completed" && session.pending.first?.id == queuedB.id && session.resumeAfterInterrupt && session.draft == independentDraft, "Accepted injection moves the intended item first and preserves the independent draft")
        let otherInject = try injectAck(DeviceCommandPayload(action: "inject", pendingID: queuedA.id))
        check(otherInject?.outcome == "failed" && otherInject?.detail?.contains("already being injected") == true && session.pending.first?.id == queuedB.id, "A different injection during interruption cannot be falsely acknowledged or displace the first intent")
        let repeatedInject = try injectAck(DeviceCommandPayload(action: "inject", pendingID: queuedB.id))
        check(repeatedInject?.outcome == "completed" && session.pending.map(\.id) == [queuedB.id, queuedA.id], "Repeated injection of the same queued item is idempotent while stopping")
        session.pending = []; session.interrupted = false; session.resumeAfterInterrupt = false
        let emptyInject = try injectAck(DeviceCommandPayload(action: "injectAll"))
        check(emptyInject?.outcome == "failed" && emptyInject?.detail?.contains("already empty") == true, "Empty queue injection returns an honest failure with nothing submitted")
        captured = []
        let retryBytes = Data("partial upload recovery fixture".utf8)
        let retryHash = DeviceBlob.sha256Hex(retryBytes)
        func homeBlob(_ kind: DeviceMessageKind, _ bytes: Data?, done: Bool = false) throws {
            let payload = try JSONEncoder().encode(DeviceBlobPayload(sha256Hex: retryHash, size: retryBytes.count, chunk: bytes, done: done))
            home.handleEnvelope(peer, DeviceEnvelope(kind: kind.rawValue, sessionID: globalString, epoch: granted?.epoch, payload: payload))
        }
        try homeBlob(.blobChunk, Data(retryBytes.prefix(5)))
        try homeBlob(.blobOffer, nil)
        try homeBlob(.blobChunk, retryBytes, done: true)
        let recoveredBlobAcks = try capturedEnvelopes().filter { $0.kind == DeviceMessageKind.blobAck.rawValue }.compactMap { $0.payload.flatMap { try? JSONDecoder().decode(DeviceAckPayload.self, from: $0) } }
        check(recoveredBlobAcks.last?.outcome == "stored", "Home abandons interrupted image prefixes before a negotiated full resend")
        captured = []
        session.queuePaused = true
        let teachingID = UUID(), previousQueueCount = session.pending.count
        let teachingPayload = try JSONEncoder().encode(DeviceCommandPayload(action: "teachSwitchboard"))
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalString, commandID: teachingID, epoch: 0, payload: teachingPayload))
        home.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.command.rawValue, sessionID: globalString, commandID: teachingID, epoch: 0, payload: teachingPayload))
        check(session.switchboardEnabled && session.pending.count == previousQueueCount + 1 && session.queuePaused, "Remote teaching queues instructions exactly once without taking a display lease or resuming a paused queue")
        _ = try capturedEnvelopes()
        session.busy = false
        Store.shared.deleteSession(session)
        captured = []
        home.homeSessionClosed(session.id)
        let closedFrames = try capturedEnvelopes()
        check(closedFrames.contains { $0.kind == DeviceMessageKind.leaseStolen.rawValue && $0.sessionID == globalString } && !peer.leasedSessions.contains(session.id), "Closing a home session immediately displaces its remote viewer using existing wire semantics")
    } catch { check(false, "Service harness failed: " + error.localizedDescription) }
    // Viewer-service harness: grant, snapshot adoption, stale seq, ack binding.
    do {
        let viewer = DeviceSyncService()
        try viewer.configureForTesting(folder: root.appendingPathComponent("viewer"))
        let homeStatic = fixedKey(0x22)
        let homeID = DeviceBlob.sha256Hex(homeStatic.publicKey.rawRepresentation)
        let gid = DeviceGlobalID(home: homeID, session: sessionID).string
        viewer.homes[homeID] = RemoteHomeState(deviceID: homeID, deviceName: "Home", online: true, rows: [
            DeviceSidebarRow(globalID: gid, sessionID: sessionID, title: "T", assistant: "Muse", engine: "muse", model: "m", effort: "e", access: "a", status: "Ready", busy: false, queued: 0, queuePaused: false)
        ], lastSeen: Date())
        var viewerHS2 = DeviceHandshake(isInitiator: true, staticKey: try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: (try Data(contentsOf: root.appendingPathComponent("viewer/device-key.bin")))), ephemeralKey: fixedKey(0x33))
        var homeHS2 = DeviceHandshake(isInitiator: false, staticKey: homeStatic, ephemeralKey: fixedKey(0x44))
        _ = try homeHS2.readMessage(try viewerHS2.writeMessage(payload: Data("v".utf8)))
        _ = try viewerHS2.readMessage(try homeHS2.writeMessage(payload: Data("h".utf8)))
        _ = try homeHS2.readMessage(try viewerHS2.writeMessage(payload: Data("v".utf8)))
        var homeKeys2 = try homeHS2.finish()
        let fakeHome = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
        fakeHome.hello = DeviceHello(deviceID: homeID, deviceName: "Home", converseVersion: "test")
        fakeHome.keys = try viewerHS2.finish(); fakeHome.trustedReady = true
        var viewerSent: [Data] = []
        fakeHome.testSink = { viewerSent.append($0) }
        viewer.adoptPeerForTesting(fakeHome)
        viewer.acquireRemote(globalID: gid)
        viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.leaseGranted.rawValue, boot: 7, sessionID: gid, epoch: 4))
        check(viewer.remoteLeases[gid] == 4, "Viewer harness installs correlated lease grant")
        let snap = DeviceTranscriptPayload(globalID: gid, homeSeq: 10, epoch: 4, boot: 7, messages: [DeviceWireMessage(id: UUID(), role: "assistant", text: "hi")], offset: 0, total: 1, draft: "home words", draftVersion: 5, busy: false, status: "Ready", title: "T2")
        viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.transcriptSnapshot.rawValue, homeSeq: 10, boot: 7, sessionID: gid, epoch: 4, payload: try JSONEncoder().encode(snap)))
        check(viewer.remoteTranscripts[gid]?.draft == "home words" && viewer.remoteTranscripts[gid]?.title == "T2", "Viewer harness stores first snapshot for hydration")
        var stale = snap; stale.homeSeq = 9; stale.title = "STALE"
        viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.transcriptSnapshot.rawValue, homeSeq: 9, boot: 7, sessionID: gid, epoch: 4, payload: try JSONEncoder().encode(stale)))
        check(viewer.remoteTranscripts[gid]?.title == "T2", "Viewer harness drops stale-sequence snapshots")
        var running = snap; running.homeSeq = 11; running.busy = true; running.status = "Working"
        viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.transcriptSnapshot.rawValue, homeSeq: 11, boot: 7, sessionID: gid, epoch: 4, payload: try JSONEncoder().encode(running)))
        check(viewer.remoteTranscripts[gid]?.busy == true, "Viewer accepts higher-sequence turn-start push")
        var completed = running; completed.homeSeq = 12; completed.busy = false; completed.status = "Ready"
        completed.messages[0].text = "Finished answer"
        viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.transcriptSnapshot.rawValue, homeSeq: 12, boot: 7, sessionID: gid, epoch: 4, payload: try JSONEncoder().encode(completed)))
        let composer = RemoteComposer()
        composer.updateEditor(transcript: viewer.remoteTranscripts[gid], cache: [:])
        check(viewer.remoteTranscripts[gid]?.homeSeq == 12 && viewer.remoteTranscripts[gid]?.status == "Ready" && !composer.editor.busy && composer.editor.messages.last?.text == "Finished answer", "Completion push updates Mac viewer messages/status/busy before lease expiry")
        viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.transcriptSnapshot.rawValue, homeSeq: 11, boot: 7, sessionID: gid, epoch: 4, payload: try JSONEncoder().encode(running)))
        check(viewer.remoteTranscripts[gid]?.busy == false && viewer.remoteTranscripts[gid]?.messages.last?.text == "Finished answer", "Delayed turn-start cannot overwrite completion snapshot")
        viewer.sendRemoteDraft(globalID: gid, text: "first edit")
        let firstVersion: UInt64 = 6
        viewer.sendRemoteDraft(globalID: gid, text: "second edit")
        let secondVersion: UInt64 = 7
        func draftAck(_ version: UInt64, _ text: String) throws {
            viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.draftAck.rawValue, sessionID: gid, epoch: 4, payload: try JSONEncoder().encode(DeviceDraftPayload(version: version, text: text))))
        }
        try draftAck(firstVersion, "first edit")
        check(viewer.draftConflicts[gid] == nil, "An earlier successful draft acknowledgment is not a conflict with newer typing")
        try draftAck(secondVersion, "second edit")
        check(viewer.draftConflicts[gid] == nil, "Current matching draft acknowledgment clears conflict state")
        try draftAck(secondVersion, "different home text")
        check(viewer.draftConflicts[gid] != nil, "Same-version divergent draft acknowledgment reports a real conflict")
        try draftAck(secondVersion + 1, "newer home text")
        check(viewer.draftConflicts[gid] != nil && viewer.storedDraft(globalID: gid) == "second edit", "A newer conflicting home acknowledgment preserves the local draft")
        let sentBeforeHints = viewerSent.count
        viewer.saveDraftAttachments(globalID: gid, hashes: [])
        check(viewerSent.count == sentBeforeHints, "Unchanged attachment lists never resend an old draft")
        viewer.remoteLeases.removeValue(forKey: gid)
        let teachingID = viewer.sendRemoteCommand(globalID: gid, command: DeviceCommandPayload(action: "teachSwitchboard"))
        check(teachingID != nil && viewer.remoteLeases[gid] == nil && viewer.outbox.first(where: { $0.commandID == teachingID })?.epoch == 0, "Viewer can teach a parked session without acquiring its display lease")
        if let teachingID {
            viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.commandAck.rawValue, sessionID: gid, commandID: teachingID, epoch: 0, payload: try JSONEncoder().encode(DeviceAckPayload(outcome: "completed"))))
            check(viewer.completedCommands.contains(teachingID) && viewer.unresolved(globalID: gid).isEmpty, "Lease-free teaching acknowledges through its bound durable outbox record")
        }
        viewer.remoteLeases[gid] = 4
        let sentID = viewer.sendRemoteCommand(globalID: gid, command: DeviceCommandPayload(action: "rename", text: "New"))
        check(sentID != nil && viewer.unresolved(globalID: gid).count == 1, "Viewer harness persists outgoing command in outbox")
        if let record = viewer.unresolved(globalID: gid).first { viewer.queryOutbox(record) }
        var queryFrames: [DeviceEnvelope] = []; var queryDecoder = DeviceFrameDecoder()
        for frame in viewerSent { queryFrames += try queryDecoder.append(homeKeys2.receiver.decrypt(frame)) }
        check(queryFrames.contains(where: { $0.kind == DeviceMessageKind.commandQuery.rawValue && $0.epoch == 4 && $0.commandID == sentID }), "Viewer reconciliation query retains persisted command epoch")
        // Wrong-home ack must not complete it.
        let rogue = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Rogue")
        rogue.hello = DeviceHello(deviceID: DeviceBlob.sha256Hex(fixedKey(0x99).publicKey.rawRepresentation), deviceName: "Rogue", converseVersion: "test")
        rogue.keys = fakeHome.keys; rogue.trustedReady = true; rogue.testSink = { _ in }
        viewer.adoptPeerForTesting(rogue)
        let ackPayload = try JSONEncoder().encode(DeviceAckPayload(outcome: "completed", epoch: 4))
        viewer.handleEnvelope(rogue, DeviceEnvelope(kind: DeviceMessageKind.commandAck.rawValue, sessionID: gid, commandID: sentID, epoch: 4, payload: ackPayload))
        check(viewer.unresolved(globalID: gid).count == 1 && !viewer.completedCommands.contains(sentID!), "Viewer harness ignores ack from wrong authenticated home")
        viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.commandAck.rawValue, sessionID: gid, commandID: sentID, epoch: 4, payload: ackPayload))
        check(viewer.unresolved(globalID: gid).isEmpty && viewer.completedCommands.contains(sentID!), "Viewer harness completes only on bound home ack")
        viewerSent = []
        let queuedID = UUID()
        let injectID = viewer.sendRemoteCommand(globalID: gid, command: DeviceCommandPayload(action: "inject", pendingID: queuedID))
        let sentFrames = viewerSent.count
        let doubleClick = viewer.sendRemoteCommand(globalID: gid, command: DeviceCommandPayload(action: "inject", pendingID: queuedID))
        let differentQueueCommand = viewer.sendRemoteCommand(globalID: gid, command: DeviceCommandPayload(action: "injectAll"))
        check(injectID != nil && doubleClick == injectID && differentQueueCommand == nil && viewerSent.count == sentFrames && viewer.queueCommand(globalID: gid)?.outcome == "pending", "Repeated queue clicks share one durable intent and cannot send another interrupt while awaiting home")
        if let injectID {
            let failed = try JSONEncoder().encode(DeviceAckPayload(outcome: "failed", detail: "Queued item no longer available.", epoch: 4))
            viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.commandAck.rawValue, sessionID: gid, commandID: injectID, epoch: 4, payload: failed))
            check(viewer.queueCommand(globalID: gid)?.detail == "Queued item no longer available." && viewer.remoteLeases[gid] == 4, "Queue failure remains visible in the outbox without revoking the valid display lease")
            let retryID = viewer.sendRemoteCommand(globalID: gid, command: DeviceCommandPayload(action: "inject", pendingID: queuedID))
            check(retryID != nil && retryID != injectID, "A definitively failed injection permits a new explicit attempt")
            if let retryID {
                viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.commandAck.rawValue, sessionID: gid, commandID: retryID, epoch: 4, payload: ackPayload))
            }
            if let failedRecord = viewer.outbox.first(where: { $0.commandID == injectID }) { viewer.discardOutbox(failedRecord) }
        }
        var queueDecoder = DeviceFrameDecoder()
        for frame in viewerSent { _ = try queueDecoder.append(homeKeys2.receiver.decrypt(frame)) }
        viewerSent = []
        let retryBytes = Data("verified cached image fixture".utf8)
        let retryHash = DeviceBlob.sha256Hex(retryBytes)
        let cache = viewer.storageFolder.appendingPathComponent("RemoteCache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let cacheFile = cache.appendingPathComponent(retryHash + ".png")
        try Data("corrupted cache".utf8).write(to: cacheFile)
        viewer.queryBlob(globalID: gid, hash: retryHash)
        func notStored(_ epoch: UInt64) throws {
            let payload = try JSONEncoder().encode(DeviceAckPayload(outcome: "failed", detail: retryHash + "|Not stored on home."))
            viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.blobAck.rawValue, sessionID: gid, epoch: epoch, payload: payload))
        }
        func newViewerFrames() throws -> [DeviceEnvelope] {
            var frames: [DeviceEnvelope] = []; var decoder = DeviceFrameDecoder()
            for frame in viewerSent { frames += try decoder.append(homeKeys2.receiver.decrypt(frame)) }
            viewerSent = []; return frames
        }
        try notStored(4)
        let corruptFrames = try newViewerFrames()
        check(!corruptFrames.contains { $0.kind == DeviceMessageKind.blobChunk.rawValue }, "Image recovery refuses cached bytes with the wrong checksum")
        try retryBytes.write(to: cacheFile)
        try notStored(4); try notStored(4)
        let retryFrames = try newViewerFrames()
        check(retryFrames.filter { $0.kind == DeviceMessageKind.blobChunk.rawValue }.count == 1 && viewer.blobCache[retryHash] == cacheFile, "Image recovery rediscovers its cache and resends at most once per lease")
        viewer.releaseRemote(globalID: gid); viewer.acquireRemote(globalID: gid)
        viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.leaseGranted.rawValue, boot: 7, sessionID: gid, epoch: 5))
        viewer.queryBlob(globalID: gid, hash: retryHash)
        try notStored(4)
        let staleFrames = try newViewerFrames()
        check(!staleFrames.contains { $0.kind == DeviceMessageKind.blobChunk.rawValue }, "Stale-epoch image acknowledgments cannot trigger a resend")
        try notStored(5)
        let freshFrames = try newViewerFrames()
        check(freshFrames.filter { $0.kind == DeviceMessageKind.blobChunk.rawValue }.count == 1, "A fresh display lease permits a new cached-image recovery attempt")
        viewer.isPlaced = { $0 == gid }
        viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: DeviceMessageKind.leaseExpired.rawValue, sessionID: gid, epoch: 5))
        viewer.restoreAvailableDisplays()
        let resumeFrames = try newViewerFrames()
        check(viewer.remoteLeases[gid] == nil && resumeFrames.contains { $0.kind == "lease.resume" && $0.epoch == 5 }, "Lease expiry retains the pane and requests a conditional resume, never a take")
        viewer.handleEnvelope(fakeHome, DeviceEnvelope(kind: "lease.granted", boot: 7, sessionID: gid, epoch: 6))
        let savedDisplay = try JSONDecoder().decode([String: UInt64].self, from: Data(contentsOf: viewer.storageFolder.appendingPathComponent("display-resume.json")))
        check(savedDisplay[gid] == 6 && viewer.remoteLeases[gid] == 6, "Resume grant persists the new display fence")
        viewer.releaseRemote(globalID: gid)
        _ = try newViewerFrames()
        viewer.restoreAvailableDisplays()
        check(try newViewerFrames().isEmpty, "Explicit Park cancels automatic display restoration")

    } catch { check(false, "Viewer harness failed: " + error.localizedDescription) }
    do {
        var clock = Date()
        var saved: [UUID: UInt64] = [:]
        let manager = DeviceLeaseManager(now: { clock }, persistEpochs: { saved = $0; return true })
        let original = manager.acquire(session: sessionID, device: "iPad")
        clock = clock.addingTimeInterval(20)
        _ = manager.sweepExpired()
        let resumed = manager.resume(session: sessionID, device: "iPad", expectedEpoch: original.epoch)
        check(resumed.granted && resumed.epoch > original.epoch, "Idle viewer resumes with a fresh fence when nobody took it")
        let other = manager.acquire(session: sessionID, device: "Windows")
        manager.release(session: sessionID, device: "Windows", epoch: other.epoch)
        check(!manager.resume(session: sessionID, device: "iPad", expectedEpoch: resumed.epoch).granted, "Resume refuses a newer take even after that viewer parks")
        let restarted = DeviceLeaseManager(initialEpochs: saved)
        check(!restarted.resume(session: sessionID, device: "iPad", expectedEpoch: resumed.epoch).granted && restarted.resume(session: sessionID, device: "Windows", expectedEpoch: other.epoch).granted, "Home restart preserves who may resume and fences old owners")
    }
    let global = DeviceGlobalID(home: "home-abc", session: sessionID)
    check(DeviceGlobalID(global.string) == global && DeviceGlobalID(home: "home-xyz", session: sessionID) != global, "Global session IDs stay unique per home and parse exactly")
}


// Short-lived, opt-in Mac home for simulator interoperability. No CLI process
// runs: the fixture is deliberately busy so submitted text enters its queue.
func runIPadHomeFixture() {
    guard ProcessInfo.processInfo.environment["CONVERSE_TEST_COMMAND"] != nil,
          let folderPath = ProcessInfo.processInfo.environment["CONVERSE_DATA_DIR"], folderPath.contains("converse-ipad-interop.") else { exit(2) }
    let folder = URL(fileURLWithPath: folderPath)
    let service = DeviceSyncService.shared
    do {
        try service.configureForTesting(folder: folder)
        service.deviceNameOverride = "Isolated Mac home"
        let session = Store.shared.create(Entry(name: "Fixture", command: "/usr/bin/false", directory: folderPath, engine: "codex"))
        session.title = "iPad interop fixture"; session.draft = "home draft"
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let imageFile = folder.appendingPathComponent("reply.jpg")
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: imageFile)
        session.messages = [Message(role: "assistant", text: "Mac home fixture\n![Reply image](" + imageFile.absoluteString + ")")]
        Store.shared.importResponseImages(session)
        session.busy = true; session.status = "Working in isolated fixture"
        try service.startNetworkForTesting()
        let groupService = DeviceSyncService()
        try groupService.configureForTesting(folder: folder.appendingPathComponent("groups"))
        try groupService.enableGroupsForTesting(); groupService.createGroup(name: "Simulator Group")
        // Real read-only Parking Lot viewer fixture, isolated from the user's lots.
        let parking = try groupService.parkingLibrary.create(name: "Mobile Parking Lot fixture")
        let parkingImage = try parking.saveImage(NSImage(contentsOf: imageFile)!)
        let liveRow = ParkingLotRow(heading: false, text: "Live update 0")
        try parking.replaceUserRows([ParkingLotRow(heading: true, text: "Mobile ideas"),
            ParkingLotRow(heading: false, text: "Image belongs to this item", images: [parkingImage]), liveRow], revision: parking.document.revision)
        var lastParkingUpdate = Date(), parkingUpdate = 0
        groupService.imageAssistKey = { "synthetic-test-key" }
        var imageCalls = 0
        groupService.imageAssistAPI.request = { request in
            imageCalls += 1
            let data = try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["type": "message", "content": [["type": "output_text", "text": "Synthetic image result #" + String(imageCalls)]]]]])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        try groupService.startNetworkForTesting()
        defer { groupService.suspendViewer() }
        let deadline = Date().addingTimeInterval(180)
        var announced = false
        while Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if Date().timeIntervalSince(lastParkingUpdate) >= 1 {
                parkingUpdate += 1
                parking.update(liveRow.id, text: "Live update \(parkingUpdate)")
                lastParkingUpdate = Date()
            }
            if !announced, let port = service.testingPort, let groupPort = groupService.testingPort {
                try Data(String(groupPort).utf8).write(to: folder.appendingPathComponent("group-port"), options: .atomic)
                try Data(String(port).utf8).write(to: folder.appendingPathComponent("port"), options: .atomic); announced = true
            }
            for request in groupService.groupRequests where !request.approved {
                groupService.reviewGroupRequest(request)
                if let review = groupService.groupReview {
                    session.messages[0].text = "Mac group fixture · verified code " + review.code
                    groupService.approveGroupReview()
                }
            }
            if let prompt = service.pairingPrompt {
                session.messages[0].text = "Mac home fixture · verified code " + prompt.code
                service.confirmPairing()
            }
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("stop").path) { break }
        }
        service.suspendViewer()
    } catch { fputs("iPad interop fixture failed: " + error.localizedDescription + "\n", stderr); exit(1) }
}

// Real sockets, independent keys and concurrent approval requests. Platform
// labels exercise identities, not a claim of Windows/iPad binary coverage.
func deviceFabricSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-fabric-" + UUID().uuidString)
    var services: [DeviceSyncService] = []
    defer { services.forEach { $0.suspendViewer() }; try? FileManager.default.removeItem(at: root) }
    func pump(_ done: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(12)
        while !done() && Date() < until {
            for service in services where service.pairingPrompt != nil { service.confirmPairing() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return done()
    }
    do {
        for index in 0..<12 {
            let service = DeviceSyncService()
            try service.configureForTesting(folder: root.appendingPathComponent(String(index)))
            service.deviceNameOverride = index < 3 ? "Home \(index)" : "Viewer \(index)"
            service.isPlaced = { _ in true }
            try service.startNetworkForTesting(); services.append(service)
        }
        guard pump({ services.allSatisfy { $0.testingPort != nil } }) else { check(false, "Fabric listeners become ready"); return }
        let homes = Array(services.prefix(3)), viewers = Array(services.dropFirst(3))
        // Admit each new device through a different existing member. Only
        // the admission link is approved; all other links must auto-trust.
        var humanAdmissions = 0
        for index in 1..<services.count {
            let sponsor = services[(index - 1) / 2]
            services[index].connectManual(host: "127.0.0.1", port: Int(sponsor.testingPort!))
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline && services[index].trusted.count < index {
                for service in services {
                    if let prompt = service.pairingPrompt {
                        humanAdmissions += 1
                        service.confirmPairing()
                        _ = prompt
                    }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        // Do not approve anything else: remaining mesh connections must
        // authenticate with the membership learned from the sponsor.
        let until = Date().addingTimeInterval(12)
        while services.contains(where: { $0.homes.values.filter(\.online).count != 11 }) && Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        check(services.allSatisfy { $0.homes.values.filter(\.online).count == 11 && $0.pairingPrompt == nil } && humanAdmissions == 22, "Twelve devices form one fabric with only eleven mutual admissions")
        let session = Store.shared.create(Entry(name: "Fabric fixture", command: "unused", directory: NSTemporaryDirectory(), engine: "codex"))
        defer { Store.shared.sessions.removeAll { $0.id == session.id }; Store.shared.save() }
        session.title = "Fabric live session"
        check(pump { viewers.allSatisfy { viewer in viewer.homes.values.filter { $0.rows.contains { $0.sessionID == session.id } }.count == 11 } }, "Every fabric member sees sessions from every other home")
        let gid = DeviceGlobalID(home: homes[0].identity!.deviceID, session: session.id).string
        for viewer in viewers {
            viewer.acquireRemote(globalID: gid)
            if !pump({ viewer.remoteLeases[gid] != nil && viewer.remoteTranscripts[gid] != nil }) { check(false, "Fabric takeover acquires authoritative snapshot"); return }
        }
        check(pump { viewers.filter { $0.remoteLeases[gid] != nil }.count == 1 } && viewers.last?.remoteLeases[gid] != nil, "Nine-way takeover retains exactly one display lease")
        viewers[0].suspendViewer()
        check(pump { viewers.dropFirst().allSatisfy { $0.homes.values.filter(\.online).count == 10 } }, "Disconnecting one viewer leaves all other fabric connections online")
    } catch { check(false, "Fabric integration: " + error.localizedDescription) }
}

func fabricTrustSelfTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-membership-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let a = try DeviceTrustStore(folder: root.appendingPathComponent("a"))
        let b = try DeviceTrustStore(folder: root.appendingPathComponent("b"))
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let id = DeviceBlob.sha256Hex(key)
        try a.pin(deviceID: id, name: "New entrant", publicKey: key, issuer: "admin-a")
        check(try b.merge(a.records) && b.check(deviceID: id, publicKey: key) == .trusted, "Fabric member introductions become durable trust")
        let stale = a.records
        try b.forget(deviceID: id, issuer: "admin-b")
        _ = try a.merge(b.records); _ = try b.merge(stale)
        check(a.devices.isEmpty && b.devices.isEmpty, "Stale fabric rosters cannot resurrect a removed member")
        try a.pin(deviceID: id, name: "Readmitted", publicKey: key, issuer: "admin-a")
        _ = try b.merge(a.records)
        check(b.devices.first?.name == "Readmitted" && (b.devices.first?.generation ?? 0) > (stale.first?.generation ?? 0), "Explicit fresh admission supersedes a removal")
        check(try DeviceTrustStore(folder: root.appendingPathComponent("b")).records == b.records, "Fabric admission and removal versions survive restart")
        let membership = a.records.first { $0.deviceID == id }!
        try a.pin(deviceID: id, name: "New endpoint", publicKey: key, host: "192.0.2.5", port: 49000, issuer: "admin-a", allowAdmission: false)
        let refreshed = a.records.first { $0.deviceID == id }!
        check(refreshed.generation == membership.generation && refreshed.changedBy == membership.changedBy && (refreshed.metadataGeneration ?? 0) > (membership.metadataGeneration ?? 0), "Endpoint refresh never creates a new membership generation")
        _ = try b.merge(a.records)
        check(b.devices.first?.lastHost == "192.0.2.5" && b.devices.first?.generation == membership.generation, "Equal-admission-rank metadata refresh converges independently")
        check(DeviceTrustStore.boundedName(String(repeating: "🙂", count: 60)) == String(repeating: "🙂", count: 50), "Fabric names truncate at the same 200 UTF-8 byte boundary on all platforms")

        let aliases = try DeviceTrustStore(folder: root.appendingPathComponent("aliases"))
        let replica = try DeviceTrustStore(folder: root.appendingPathComponent("replica"))
        let group = UUID().uuidString.lowercased()
        try aliases.pin(deviceID: id, name: "Reported OS name", publicKey: key, issuer: "a", groupID: group)
        _ = try replica.merge(aliases.records)
        let original = aliases.records[0]
        try aliases.renameDisplay(deviceID: id, groupID: group, name: "Studio Mac", issuer: "a")
        _ = try replica.merge(aliases.records)
        check(replica.records[0].displayName == "Studio Mac" && replica.records[0].name == original.name && replica.records[0].publicKey == original.publicKey && replica.records[0].generation == original.generation,
              "Group display rename syncs without changing hostname, keys or admission")
        try replica.pin(deviceID: id, name: "OS renamed itself", publicKey: key, host: "192.0.2.10", issuer: "b", allowAdmission: false, groupID: group)
        _ = try aliases.merge(replica.records)
        check(aliases.records[0].displayName == "Studio Mac", "Reconnect endpoint and hostname refresh preserves group display name")
        var legacy = aliases.records[0]; legacy.displayName = nil; legacy.displayNameGeneration = nil; legacy.displayNameBy = nil; legacy.metadataGeneration = 50
        _ = try aliases.merge([legacy])
        check(aliases.records[0].displayName == "Studio Mac", "Older metadata without display fields cannot erase a group label")
        try aliases.renameDisplay(deviceID: id, groupID: group, name: "Alpha", issuer: "a")
        try replica.renameDisplay(deviceID: id, groupID: group, name: "Zulu", issuer: "z")
        let concurrentA = aliases.records, concurrentB = replica.records
        _ = try aliases.merge(concurrentB); _ = try replica.merge(concurrentA)
        check(aliases.records[0].displayName == "Zulu" && replica.records[0].displayName == "Zulu", "Concurrent display renames converge deterministically")
        check(try DeviceTrustStore(folder: root.appendingPathComponent("aliases")).records[0].displayName == "Zulu", "Group display name survives restart")
        let beforeInvalidName = aliases.records
        do { try aliases.renameDisplay(deviceID: id, groupID: group, name: " \n ", issuer: "a"); check(false, "Blank device display name rejected") }
        catch { check(aliases.records == beforeInvalidName, "Blank device display name rejected without changes") }
        try replica.forget(deviceID: id, issuer: "z"); _ = try replica.merge(concurrentA)
        check(replica.devices.isEmpty, "A stale display rename cannot resurrect a removed device")
        try aliases.pin(deviceID: id, name: "Reported OS name", publicKey: key, issuer: "a", groupID: UUID().uuidString.lowercased())
        check(aliases.records[0].displayName == nil, "Display aliases do not leak into a different group")

        var invalid = a.records[0]; invalid.deviceID = String(repeating: "0", count: 64)
        let before = b.records
        do { _ = try b.merge([invalid]); check(false, "Fabric rejects identity/key mismatch") }
        catch { check(b.records == before, "Fabric rejects identity/key mismatch without mutating trust") }
        invalid = a.records[0]; invalid.generation = UInt64.max
        do { _ = try b.merge([invalid]); check(false, "Fabric rejects exhausted generation") }
        catch { check(b.records == before, "Fabric rejects exhausted generation without poisoning future admissions") }
        var attack = a.records[0]; attack.generation = UInt64.max - 2; attack.changedBy = "attacker"; attack.removed = false
        let beforeAttack = b.records
        _ = try b.merge([attack])
        check(b.records == beforeAttack, "A far-future membership is ignored instead of outranking local state")
        let poisonDir = root.appendingPathComponent("poisoned")
        try FileManager.default.createDirectory(at: poisonDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var seed = TrustedDevice(deviceID: id, name: "Victim", publicKey: key, pairedAt: Date())
        seed.generation = UInt64.max - 2; seed.changedBy = "attacker"
        try JSONEncoder().encode([seed]).write(to: poisonDir.appendingPathComponent("devices.json"))
        let poisonedStore = try DeviceTrustStore(folder: poisonDir)
        try poisonedStore.forget(deviceID: id, issuer: "owner")
        check(poisonedStore.devices.isEmpty, "Forget succeeds when membership counters are exhausted")
        try poisonedStore.pin(deviceID: id, name: "Rejoined", publicKey: key, issuer: "owner")
        check(poisonedStore.check(deviceID: id, publicKey: key) == .trusted && (poisonedStore.records.first?.generation ?? UInt64.max) < 1000, "Admission compacts exhausted counters and succeeds")
        _ = try poisonedStore.merge([attack])
        check(poisonedStore.check(deviceID: id, publicKey: key) == .trusted && (poisonedStore.records.first?.generation ?? UInt64.max) < 1000, "A far-future resuscitation cannot outrank the local member")
        try poisonedStore.forget(deviceID: id, issuer: "owner")
        _ = try poisonedStore.merge([attack])
        check(poisonedStore.devices.isEmpty, "A far-future resuscitation cannot resurrect a locally removed member")
        let untrusted = DeviceSyncService(); try untrusted.configureForTesting(folder: root.appendingPathComponent("untrusted"))
        let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp), isInitiator: false, displayName: "Untrusted")
        peer.hello = DeviceHello(deviceID: "unknown", deviceName: "Unknown", converseVersion: "test")
        untrusted.handleEnvelope(peer, DeviceEnvelope(kind: "fabric.members", payload: try JSONEncoder().encode(a.records)))
        check(untrusted.trusted.isEmpty, "Unauthenticated peers cannot introduce fabric members")
    } catch { check(false, "Fabric trust regression: " + error.localizedDescription) }
}

func fabricRevocationReconnectTests(_ check: (Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-revocation-" + UUID().uuidString)
    var live: [DeviceSyncService] = []
    defer { live.forEach { $0.suspendViewer() }; try? FileManager.default.removeItem(at: root) }
    func make(_ name: String, displayName: String? = nil) throws -> DeviceSyncService {
        let service = DeviceSyncService(); try service.configureForTesting(folder: root.appendingPathComponent(name))
        service.deviceNameOverride = displayName ?? name; service.isPlaced = { _ in true }; try service.startNetworkForTesting(); live.append(service); return service
    }
    func records(_ name: String) throws -> [TrustedDevice] { try DeviceTrustStore(folder: root.appendingPathComponent(name)).records }
    func pump(_ done: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(8)
        while !done() && Date() < until {
            for service in live where service.pairingPrompt != nil { service.confirmPairing() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return done()
    }
    do {
        var a = try make("A"), r = try make("R"), x = try make("X")
        guard pump({ live.allSatisfy { ($0.testingPort ?? 0) > 0 } }) else { check(false, "Revocation listeners ready"); return }
        let rid = r.identity!.deviceID, aid = a.identity!.deviceID, xid = x.identity!.deviceID
        r.connectManual(host: "127.0.0.1", port: Int(a.testingPort!))
        guard pump({ a.trusted.count == 1 && r.trusted.count == 1 }) else { check(false, "Initial revocation pair ready"); return }
        x.connectManual(host: "127.0.0.1", port: Int(a.testingPort!))
        guard pump({ live.allSatisfy { $0.homes.values.filter(\.online).count == 2 } }) else { check(false, "Initial revocation fabric ready"); return }
        x.suspendViewer(); r.suspendViewer()
        a.forgetDevice(a.trusted.first { $0.deviceID == rid }!)
        let removed = try records("A").first { $0.deviceID == rid }!
        let rStore = try DeviceTrustStore(folder: root.appendingPathComponent("R")); _ = try rStore.merge([removed])
        a.suspendViewer() // X remains stale and cannot learn the removal from A.
        r = try make("R", displayName: "R renamed"); x = try make("X", displayName: "X renamed")
        guard pump({ (r.testingPort ?? 0) > 0 && (x.testingPort ?? 0) > 0 }) else { check(false, "Reconnect listeners ready"); return }
        r.connectManual(host: "127.0.0.1", port: Int(x.testingPort!))
        _ = pump { (try? records("X").first { $0.deviceID == rid }?.removed) == true }
        let all = try records("A") + records("R") + records("X")
        if !all.filter({ $0.deviceID == rid }).allSatisfy({ $0.removed == true }) {
            print("Revocation reconnect diagnostics:", "R:", r.serviceStatus, r.lastOutcome, "pairing:", r.pairingPrompt?.peerName ?? "none", "port:", r.testingPort ?? 0, "X:", x.serviceStatus, x.lastOutcome, "pairing:", x.pairingPrompt?.peerName ?? "none", "port:", x.testingPort ?? 0)
        }
        check(all.filter { $0.deviceID == rid }.allSatisfy { $0.removed == true && ($0.generation ?? 0) == (removed.generation ?? 0) }, "Removed device cannot resurrect itself through a stale member during reconnect")
        check(pump { r.homes[xid]?.online != true && x.homes[rid]?.online != true }, "Stale reconnect converges to the tombstone and disconnects the removed member")
        a = try make("A", displayName: "A sponsor")
        guard pump({ (a.testingPort ?? 0) > 0 }) else { check(false, "Sponsor restart ready"); return }
        r.connectManual(host: "127.0.0.1", port: Int(a.testingPort!))
        check(pump { r.homes[aid]?.online == true && a.homes[rid]?.online == true && (try? records("R").first { $0.deviceID == rid }?.removed) != true }, "An up-to-date sponsor can explicitly readmit the removed device")
        let readmitted = try records("A").first { $0.deviceID == rid }!
        check(readmitted.removed != true && (readmitted.generation ?? 0) > (removed.generation ?? 0) && readmitted.changedBy == aid, "Fresh readmission is issued by the human-approving sponsor")
    } catch { check(false, "Reconnect revocation regression: " + error.localizedDescription) }
}

// Keep a real approval sheet open beyond the transport's 20-second timeout.
// Uses two isolated homes and real sockets, never production pairing or notes.
func parkingLotReviewConnectivitySelfTests(_ check: (Bool, String) -> Void) {
    _ = NSApplication.shared
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-review-network-" + UUID().uuidString)
    let home = DeviceSyncService(), viewer = DeviceSyncService()
    let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "Isolated Parking Lot approval test"; window.isReleasedWhenClosed = false
    defer { home.suspendViewer(); viewer.suspendViewer(); window.close(); try? FileManager.default.removeItem(at: root) }
    func pump(seconds: TimeInterval = 8, _ ready: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() && Date() < deadline {
            for service in [home, viewer] where service.pairingPrompt != nil { service.confirmPairing() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return ready()
    }
    do {
        try home.configureForTesting(folder: root.appendingPathComponent("home"))
        try viewer.configureForTesting(folder: root.appendingPathComponent("viewer"))
        home.deviceNameOverride = "Approval QA home"; viewer.deviceNameOverride = "Approval QA viewer"
        try home.startNetworkForTesting(); try viewer.startNetworkForTesting()
        guard pump({ home.testingPort != nil && viewer.testingPort != nil }) else { check(false, "Approval test listeners ready"); return }
        viewer.connectManual(host: "127.0.0.1", port: Int(home.testingPort!))
        guard pump({ home.homes[viewer.localDeviceID ?? ""]?.online == true && viewer.homes[home.localDeviceID ?? ""]?.online == true }) else { check(false, "Approval test peers connect"); return }
        let lot = ParkingLotStore(folder: root.appendingPathComponent("lot")); lot.open()
        let row = lot.document.rows[0].id
        let session = Session(entry: Entry(name: "Review fixture", command: "unused", directory: root.path, engine: "codex"))
        var outcome: String?, failure: Error?, allowed = true
        func startReview() -> Task<Void, Never> {
            outcome = nil; failure = nil
            let edits = ParkingLotEdits(revision: lot.document.revision, operations: [.init(action: "update", id: row, text: "Reviewed heading")])
            return Task { @MainActor in
                do { outcome = try await Store.shared.reviewParkingLotAsync(edits, session: session, lot: lot, window: window, allowed: { allowed }) }
                catch { failure = error }
            }
        }
        window.orderFront(nil)
        let first = startReview()
        guard pump({ window.attachedSheet != nil }) else { first.cancel(); check(false, "Approval sheet opens asynchronously"); return }
        var ticks = 0, callbacks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            ticks += 1; DispatchQueue.main.async { callbacks += 1 }
        }
        // A modal runloop would starve these to ~0; on a loaded machine timers
        // coalesce, so require clear progress (>80 of ~220) rather than 150.
        let until = Date().addingTimeInterval(22)
        _ = pump(seconds: 24) { Date() >= until }
        timer.invalidate()
        check(window.attachedSheet != nil && outcome == nil && failure == nil && ticks > 80 && callbacks > 80,
              "Pending native Parking Lot review keeps default timers and main-queue callbacks running for 22 seconds")
        check(home.homes[viewer.localDeviceID ?? ""]?.online == true && viewer.homes[home.localDeviceID ?? ""]?.online == true,
              "Two real connected homes stay online beyond the 20-second timeout while approval is pending")
        lot.update(row, text: "Human edited during review")
        window.endSheet(window.attachedSheet!, returnCode: .alertSecondButtonReturn)
        _ = pump { outcome != nil || failure != nil }
        check(failure?.localizedDescription.contains("changed during") == true && lot.document.rows[0].text == "Human edited during review",
              "Asynchronous Apply rejects a revision changed while its native sheet was open")
        _ = pump { window.attachedSheet == nil }
        let second = startReview()
        guard pump({ window.attachedSheet != nil }) else { second.cancel(); check(false, "Second approval opens"); return }
        window.endSheet(window.attachedSheet!, returnCode: .alertFirstButtonReturn)
        _ = pump { outcome != nil || failure != nil }
        check(outcome?.contains("declined") == true && lot.document.rows[0].text == "Human edited during review", "Native Cancel saves no Parking Lot changes")
        _ = pump { window.attachedSheet == nil }
        let third = startReview()
        guard pump({ window.attachedSheet != nil }) else { third.cancel(); check(false, "Third approval opens"); return }
        window.endSheet(window.attachedSheet!, returnCode: .alertSecondButtonReturn)
        _ = pump { outcome != nil || failure != nil }
        check(outcome?.contains("approved and saved") == true && lot.document.rows[0].text == "Reviewed heading", "Native asynchronous Apply saves a current reviewed edit")
        _ = pump { window.attachedSheet == nil }
        lot.update(row, text: "Keep on cancellation")
        let fourth = startReview()
        guard pump({ window.attachedSheet != nil }) else { fourth.cancel(); check(false, "Cancellation approval opens"); return }
        fourth.cancel()
        _ = pump { failure != nil && window.attachedSheet == nil }
        check(failure is CancellationError && window.attachedSheet == nil && lot.document.rows[0].text == "Keep on cancellation", "Cancelled agent review dismisses its sheet and cannot apply edits")
        let fifth = startReview()
        guard pump({ window.attachedSheet != nil }) else { fifth.cancel(); check(false, "Revocation approval opens"); return }
        allowed = false
        window.endSheet(window.attachedSheet!, returnCode: .alertSecondButtonReturn)
        _ = pump { outcome != nil || failure != nil }
        check(failure?.localizedDescription.contains("access changed") == true && lot.document.rows[0].text == "Keep on cancellation", "Revoked scope is rechecked after native approval")
    } catch { check(false, "Approval connectivity: " + error.localizedDescription) }
}

// Remote sidebar markers: wire compatibility, home response time, and the
// per-viewing-device paused and unseen-response logic.
func remoteMarkerSelfTests(_ check: (Bool, String) -> Void) {
    let home = "home-a", sid = UUID(), gid = DeviceGlobalID(home: "home-a", session: sid).string
    let older = #"{"globalID":"home-a/x","sessionID":"\#(sid.uuidString)","title":"Old","assistant":"Muse","engine":"muse","model":"","effort":"","access":"","status":"Ready","busy":false,"queued":0,"queuePaused":false}"#
    let decodedOld = try? JSONDecoder().decode(DeviceSidebarRow.self, from: Data(older.utf8))
    check(decodedOld?.title == "Old" && decodedOld?.loopPaused == nil && decodedOld?.pausedReason == nil && decodedOld?.lastResponseAt == nil, "Older sidebar rows without marker fields still decode")
    var row = DeviceSidebarRow(globalID: gid, sessionID: sid, title: "Work", assistant: "Muse", engine: "muse", model: "", effort: "", access: "", status: "Ready", busy: false, queued: 0, queuePaused: false)
    let plain = (try? JSONEncoder().encode(row)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check(!plain.contains("loopPaused") && !plain.contains("pausedReason") && !plain.contains("lastResponseAt"), "Rows without markers omit the new fields on the wire")
    var marked = row; marked.loopPaused = true; marked.pausedReason = "Over budget."; marked.lastResponseAt = Date(timeIntervalSinceReferenceDate: 815313600.25)
    let markedJSON = (try? JSONEncoder().encode(marked)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    check((try? JSONDecoder().decode(DeviceSidebarRow.self, from: Data(markedJSON.utf8))) == marked && markedJSON.contains(#""lastResponseAt":815313600.25"#), "Marker fields round-trip with Apple-epoch seconds, matching C# viewers")
    let csharp = #"{"globalID":"\#(gid)","sessionID":"\#(sid.uuidString)","title":"Steward","assistant":"Agent","engine":"agent","model":"","effort":"","access":"","status":"Ready","busy":false,"queued":0,"queuePaused":false,"participantKind":"agent","loopPaused":true,"pausedReason":"Over budget.","lastResponseAt":815313600.25}"#
    let fromCSharp = try? JSONDecoder().decode(DeviceSidebarRow.self, from: Data(csharp.utf8))
    check(fromCSharp?.showsLoopPaused == true && fromCSharp?.pausedHelp == "Over budget." && fromCSharp?.lastResponseAt == Date(timeIntervalSinceReferenceDate: 815313600.25), "C#-encoded marker rows decode and render paused on Swift viewers")

    // Home response time: newest assistant reply; a running turn's partial reply never counts.
    let t = { (s: Double) in Date(timeIntervalSinceReferenceDate: s) }
    var turn = [Message(role: "user", text: "q1", createdAt: t(5)), Message(role: "assistant", text: "a1", createdAt: t(10)),
                Message(role: "user", text: "q2", createdAt: t(20)), Message(role: "assistant", text: "partial", createdAt: t(30))]
    check(Session.lastResponseAt(turn, busy: false) == t(30) && Session.lastResponseAt(turn, busy: true) == t(10), "lastResponseAt excludes a running turn's partial reply")
    turn.append(Message(role: "assistant", text: "", createdAt: t(40)))
    turn.append(Message(role: "activity", text: "tool", createdAt: t(50)))
    check(Session.lastResponseAt(turn, busy: false) == t(30) && Session.lastResponseAt([], busy: false) == nil, "Empty replies, activity and empty sessions carry no newer response")

    // Paused marker inputs.
    var agent = row; agent.engine = "agent"; agent.participantKind = "agent"; agent.loopPaused = true
    check(agent.showsLoopPaused && agent.pausedHelp == "Loop paused. Re-enable it in Agent Setup / Loop.", "A paused remote agent shows the red marker with a default explanation")
    agent.pausedReason = "Never run — enable the loop in Agent Setup."
    check(agent.pausedHelp == "Never run — enable the loop in Agent Setup.", "The home's paused reason becomes the marker's help")
    var notAgent = row; notAgent.loopPaused = true
    agent.loopPaused = false
    check(!agent.showsLoopPaused && !notAgent.showsLoopPaused && !row.showsLoopPaused, "Running loops, ordinary sessions and older homes show no paused marker")

    // Unseen watermarks (pure).
    var marks = RemoteSeenWatermarks()
    row.lastResponseAt = t(100)
    check(marks.observe(home: home, rows: [row], displayed: { _ in false }) && !marks.isUnseen(row), "First observation of a session counts as seen")
    var newer = row; newer.lastResponseAt = t(200)
    _ = marks.observe(home: home, rows: [newer], displayed: { _ in false })
    check(marks.isUnseen(newer), "A newer response while not displayed here marks the session unseen")
    check(marks.observe(home: home, rows: [newer], displayed: { $0 == gid }) && !marks.isUnseen(newer), "Displaying the session here clears the marker")
    var newest = newer; newest.lastResponseAt = t(300)
    _ = marks.observe(home: home, rows: [newest], displayed: { _ in false })
    check(marks.isUnseen(newest) && marks.markSeen(newest) && !marks.isUnseen(newest), "Taking the session here clears the marker")
    var fresh = RemoteSeenWatermarks(); var noReply = row; noReply.lastResponseAt = nil
    _ = fresh.observe(home: home, rows: [noReply], displayed: { _ in false })
    _ = fresh.observe(home: home, rows: [newer], displayed: { _ in false })
    check(fresh.isUnseen(newer), "A session first seen with no reply gets the marker for its first reply")
    var agentRow = agent; agentRow.lastResponseAt = t(100)
    var lot = row; lot.engine = "parking"; lot.globalID = DeviceGlobalID(home: home, session: UUID()).string; lot.lastResponseAt = t(100)
    var agentMarks = RemoteSeenWatermarks()
    _ = agentMarks.observe(home: home, rows: [agentRow, lot], displayed: { _ in false })
    agentRow.lastResponseAt = t(900); lot.lastResponseAt = t(900)
    _ = agentMarks.observe(home: home, rows: [agentRow, lot], displayed: { _ in false })
    check(!agentMarks.isUnseen(agentRow) && !agentMarks.isUnseen(lot) && agentMarks.seen.isEmpty, "Agents and Parking Lots never carry the unseen marker")
    _ = marks.observe(home: "home-b", rows: [], displayed: { _ in false })
    check(marks.seen[gid] != nil, "Another home's snapshot leaves this home's watermarks alone")
    _ = marks.observe(home: home, rows: [], displayed: { _ in false })
    check(marks.seen[gid] == nil, "Sessions closed on their home are forgotten")

    // Viewer service: snapshot adoption, take, persistence across relaunch.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("converse-markers-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
        let homeID = "marker-home"
        let sessionID = UUID(), agentID = UUID()
        let sessionGID = DeviceGlobalID(home: homeID, session: sessionID).string, agentGID = DeviceGlobalID(home: homeID, session: agentID).string
        func makeViewer() throws -> (DeviceSyncService, DevicePeer) {
            let viewer = DeviceSyncService()
            try viewer.configureForTesting(folder: root)
            viewer.isPlaced = { _ in false }
            let peer = DevicePeer(connection: NWConnection(host: "127.0.0.1", port: 1, using: .tcp), isInitiator: true, displayName: "Home")
            peer.hello = DeviceHello(deviceID: homeID, deviceName: "Home", converseVersion: "test"); peer.trustedReady = true
            viewer.adoptPeerForTesting(peer)
            return (viewer, peer)
        }
        var seq: UInt64 = 100
        func sidebar(_ viewer: DeviceSyncService, _ peer: DevicePeer, response: Double?, paused: Bool) throws {
            seq += 1
            var chat = DeviceSidebarRow(globalID: sessionGID, sessionID: sessionID, title: "Chat", assistant: "Claude", engine: "claude", model: "", effort: "", access: "", status: "Ready", busy: false, queued: 0, queuePaused: false)
            chat.lastResponseAt = response.map(t)
            var steward = DeviceSidebarRow(globalID: agentGID, sessionID: agentID, title: "Converse Steward", assistant: "Agent", engine: "agent", model: "", effort: "", access: "", status: "Ready", busy: false, queued: 0, queuePaused: false, participantKind: "agent")
            steward.loopPaused = paused; steward.pausedReason = paused ? "Paused by Stop." : nil; steward.lastResponseAt = response.map(t)
            let payload = DeviceSidebarPayload(homeDeviceID: homeID, homeDeviceName: "Home", homeSeq: seq, rows: [chat, steward])
            viewer.handleEnvelope(peer, DeviceEnvelope(kind: DeviceMessageKind.sidebarSnapshot.rawValue, homeSeq: seq, payload: try JSONEncoder().encode(payload)))
        }
        func markers(_ viewer: DeviceSyncService, _ id: String) -> RemoteRowMarkers { viewer.remoteRow(globalID: id).map(viewer.remoteMarkers) ?? RemoteRowMarkers() }
        var (viewer, peer) = try makeViewer()
        try sidebar(viewer, peer, response: 100, paused: true)
        check(markers(viewer, agentGID) == RemoteRowMarkers(paused: true, pausedReason: "Paused by Stop.", unseen: false), "Viewer renders a remote paused agent with its reason and no eye")
        check(markers(viewer, sessionGID) == RemoteRowMarkers(), "First remote snapshot after install marks nothing unseen")
        try sidebar(viewer, peer, response: 200, paused: false)
        check(markers(viewer, sessionGID).unseen && !markers(viewer, agentGID).unseen && !markers(viewer, agentGID).paused, "A new remote response marks the session unseen; agents stay unmarked and unpause republishes")
        (viewer, peer) = try makeViewer()
        try sidebar(viewer, peer, response: 200, paused: false)
        check(markers(viewer, sessionGID).unseen, "Unseen markers persist across relaunch")
        viewer.homes[homeID]?.lastSeen = Date()
        viewer.acquireRemote(globalID: sessionGID)
        check(!markers(viewer, sessionGID).unseen, "Taking the session with 1, 2 or 3 here clears the eye")
        (viewer, peer) = try makeViewer()
        try sidebar(viewer, peer, response: 200, paused: false)
        check(!markers(viewer, sessionGID).unseen, "A cleared marker stays cleared after relaunch")
        try sidebar(viewer, peer, response: 300, paused: false)
        check(markers(viewer, sessionGID).unseen, "A later response marks it unseen again")
        viewer.isPlaced = { $0 == sessionGID }
        check(!markers(viewer, sessionGID).unseen, "A session displayed here never shows the eye")
        try sidebar(viewer, peer, response: 300, paused: false)
        viewer.isPlaced = { _ in false }
        check(!markers(viewer, sessionGID).unseen, "Displaying the session here advances its seen watermark")
    } catch { check(false, "Remote marker viewer harness failed: " + error.localizedDescription) }
}
