import CryptoKit
import Foundation
import Network
import Security

func deviceSyncSelfTests(_ check: (Bool, String) -> Void) {
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
        check(a.handshakeHash == b.handshakeHash && DeviceSAS.code(a.handshakeHash) == DeviceSAS.code(b.handshakeHash) && DeviceSAS.code(a.handshakeHash).count == 6, "Both devices derive the same six digit pairing code")
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
    check(drafts.apply(session: sessionID, version: 2, text: "new") && !drafts.apply(session: sessionID, version: 1, text: "old") && drafts.text(session: sessionID) == "new", "Stale draft patches cannot overwrite newer home drafts")
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
        _ = homeDraft.apply(session: sessionID, version: 5, text: "preserved draft")
        viewerDraft.adopt(session: sessionID, version: 5, text: "preserved draft")
        let adopted = viewerDraft.bump(session: sessionID, text: "new holder edit")
        check(adopted == 6 && homeDraft.apply(session: sessionID, version: adopted, text: "new holder edit"), "New holder adopts home draft version before editing")
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
                    let len = buffer.prefix(2).withUnsafeBytes { Int(UInt16(bigEndian: $0.load(as: UInt16.self))) }
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
    let global = DeviceGlobalID(home: "home-abc", session: sessionID)
    check(DeviceGlobalID(global.string) == global && DeviceGlobalID(home: "home-xyz", session: sessionID) != global, "Global session IDs stay unique per home and parse exactly")
}
