import CryptoKit
import Foundation

enum DeviceCryptoError: LocalizedError {
    case invalidMessage, decryptFailed, wrongOrder
    var errorDescription: String? { "Secure device handshake failed." }
}

private func noiseHMAC(key: Data, data: Data) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
}

private func noiseHKDF(salt: Data, ikm: Data, count: Int) -> [Data] {
    let temp = noiseHMAC(key: salt, data: ikm)
    var outputs: [Data] = []
    var previous = Data()
    for index in 1...count {
        let value = noiseHMAC(key: temp, data: previous + Data([UInt8(index)]))
        outputs.append(value); previous = value
    }
    return outputs
}

private func noiseDH(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pub: Curve25519.KeyAgreement.PublicKey) throws -> Data {
    let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
    return secret.withUnsafeBytes { Data($0) }
}

struct DeviceCipher {
    fileprivate var key: SymmetricKey?
    fileprivate var nonce: UInt64 = 0
    mutating func encrypt(ad: Data = Data(), _ plaintext: Data) throws -> Data {
        guard nonce < UInt64.max else { throw DeviceCryptoError.decryptFailed }
        guard let key else { return plaintext }
        var nonceData = Data(count: 4)
        nonceData.append(withUnsafeBytes(of: nonce.littleEndian) { Data($0) })
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: try ChaChaPoly.Nonce(data: nonceData), authenticating: ad)
        nonce += 1
        return sealed.ciphertext + sealed.tag
    }
    mutating func decrypt(ad: Data = Data(), _ ciphertext: Data) throws -> Data {
        guard nonce < UInt64.max else { throw DeviceCryptoError.decryptFailed }
        guard let key else { return ciphertext }
        guard ciphertext.count >= 16 else { throw DeviceCryptoError.decryptFailed }
        var nonceData = Data(count: 4)
        nonceData.append(withUnsafeBytes(of: nonce.littleEndian) { Data($0) })
        let box = try ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: nonceData), ciphertext: Data(ciphertext.dropLast(16)), tag: Data(ciphertext.suffix(16)))
        do { let opened = try ChaChaPoly.open(box, using: key, authenticating: ad); nonce += 1; return opened }
        catch { throw DeviceCryptoError.decryptFailed }
    }
    // Public transport API uses empty associated data after Split.
    mutating func encrypt(_ plaintext: Data) throws -> Data { try encrypt(ad: Data(), plaintext) }
    mutating func decrypt(_ ciphertext: Data) throws -> Data { try decrypt(ad: Data(), ciphertext) }
}

private struct NoiseSymmetric {
    var chainKey: Data
    var hash: Data
    var cipher = DeviceCipher()
    init(prologue: Data = Data("Converse/1".utf8)) {
        // Noise 5.2 Initialize: protocol name is exactly HASHLEN (32) bytes,
        // so h is the name itself, not its hash. Names longer than HASHLEN hash.
        let name = Data("Noise_XX_25519_ChaChaPoly_SHA256".utf8)
        hash = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        chainKey = hash
        mixHash(prologue)
    }
    mutating func mixHash(_ data: Data) { hash = Data(SHA256.hash(data: hash + data)) }
    mutating func mixKey(_ ikm: Data) {
        let out = noiseHKDF(salt: chainKey, ikm: ikm, count: 2)
        chainKey = out[0]; cipher = DeviceCipher(key: SymmetricKey(data: out[1]))
    }
    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        let value = try cipher.encrypt(ad: hash, plaintext); mixHash(value); return value
    }
    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        let value = try cipher.decrypt(ad: hash, ciphertext); mixHash(ciphertext); return value
    }
}

struct DeviceTransportKeys {
    var sender: DeviceCipher
    var receiver: DeviceCipher
    let handshakeHash: Data
    let remoteStatic: Data
}

struct DeviceHandshake {
    let isInitiator: Bool
    private let staticKey: Curve25519.KeyAgreement.PrivateKey
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var remoteEphemeral: Curve25519.KeyAgreement.PublicKey?
    private(set) var remoteStatic: Data?
    private var state: NoiseSymmetric
    private var step = 0
    init(isInitiator: Bool, staticKey: Curve25519.KeyAgreement.PrivateKey, ephemeralKey: Curve25519.KeyAgreement.PrivateKey? = nil, prologue: Data = Data("Converse/1".utf8)) {
        self.isInitiator = isInitiator; self.staticKey = staticKey; ephemeral = ephemeralKey
        state = NoiseSymmetric(prologue: prologue)
    }
    private mutating func makeEphemeral() -> Curve25519.KeyAgreement.PrivateKey {
        if let ephemeral { return ephemeral }
        let key = Curve25519.KeyAgreement.PrivateKey(); ephemeral = key; return key
    }
    mutating func writeMessage(payload: Data) throws -> Data {
        if isInitiator && step == 0 {
            let e = makeEphemeral(); state.mixHash(e.publicKey.rawRepresentation)
            step = 1; return e.publicKey.rawRepresentation + (try state.encryptAndHash(payload))
        }
        if !isInitiator && step == 1 {
            guard let remoteEphemeral else { throw DeviceCryptoError.wrongOrder }
            let e = makeEphemeral(); state.mixHash(e.publicKey.rawRepresentation)
            state.mixKey(try noiseDH(e, remoteEphemeral))
            let sealedStatic = try state.encryptAndHash(staticKey.publicKey.rawRepresentation)
            state.mixKey(try noiseDH(staticKey, remoteEphemeral))
            step = 2; return e.publicKey.rawRepresentation + sealedStatic + (try state.encryptAndHash(payload))
        }
        if isInitiator && step == 2 {
            guard let remoteEphemeral else { throw DeviceCryptoError.wrongOrder }
            let sealedStatic = try state.encryptAndHash(staticKey.publicKey.rawRepresentation)
            state.mixKey(try noiseDH(staticKey, remoteEphemeral))
            step = 3; return sealedStatic + (try state.encryptAndHash(payload))
        }
        throw DeviceCryptoError.wrongOrder
    }
    mutating func readMessage(_ message: Data) throws -> Data {
        if !isInitiator && step == 0 {
            guard message.count >= 32 else { throw DeviceCryptoError.invalidMessage }
            let keyData = Data(message.prefix(32))
            remoteEphemeral = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
            state.mixHash(keyData); step = 1
            return try state.decryptAndHash(Data(message.dropFirst(32)))
        }
        if isInitiator && step == 1 {
            guard message.count >= 80, let ephemeral else { throw DeviceCryptoError.invalidMessage }
            let keyData = Data(message.prefix(32))
            let remoteE = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
            remoteEphemeral = remoteE; state.mixHash(keyData)
            state.mixKey(try noiseDH(ephemeral, remoteE))
            let staticData = try state.decryptAndHash(Data(message.dropFirst(32).prefix(48)))
            remoteStatic = staticData
            state.mixKey(try noiseDH(ephemeral, try Curve25519.KeyAgreement.PublicKey(rawRepresentation: staticData)))
            step = 2
            return try state.decryptAndHash(Data(message.dropFirst(80)))
        }
        if !isInitiator && step == 2 {
            guard message.count >= 48, let ephemeral else { throw DeviceCryptoError.invalidMessage }
            let staticData = try state.decryptAndHash(Data(message.prefix(48)))
            remoteStatic = staticData
            state.mixKey(try noiseDH(ephemeral, try Curve25519.KeyAgreement.PublicKey(rawRepresentation: staticData)))
            step = 3
            return try state.decryptAndHash(Data(message.dropFirst(48)))
        }
        throw DeviceCryptoError.wrongOrder
    }
    mutating func finish() throws -> DeviceTransportKeys {
        guard step == 3, let remoteStatic else { throw DeviceCryptoError.wrongOrder }
        let out = noiseHKDF(salt: state.chainKey, ikm: Data(), count: 2)
        let first = DeviceCipher(key: SymmetricKey(data: out[0]))
        let second = DeviceCipher(key: SymmetricKey(data: out[1]))
        return isInitiator
            ? DeviceTransportKeys(sender: first, receiver: second, handshakeHash: state.hash, remoteStatic: remoteStatic)
            : DeviceTransportKeys(sender: second, receiver: first, handshakeHash: state.hash, remoteStatic: remoteStatic)
    }
}

