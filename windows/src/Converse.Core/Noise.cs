using System.Security.Cryptography;

namespace Converse.Core;

// Noise_XX_25519_ChaChaPoly_SHA256, transliteration of the Swift reference
// in Sources/DeviceCrypto.swift. Protocol name is exactly HASHLEN bytes, so
// h starts as the name itself (Noise 5.2), then MixHash(prologue).
public sealed class NoiseException(string message) : Exception(message);

public sealed class DeviceCipher
{
    private byte[]? _key;
    private ulong _nonce;
    internal DeviceCipher(byte[]? key = null) => _key = key;

    public byte[] Encrypt(ReadOnlySpan<byte> plaintext) => Encrypt(ReadOnlySpan<byte>.Empty, plaintext);
    public byte[] Decrypt(ReadOnlySpan<byte> ciphertext) => Decrypt(ReadOnlySpan<byte>.Empty, ciphertext);

    internal byte[] Encrypt(ReadOnlySpan<byte> ad, ReadOnlySpan<byte> plaintext)
    {
        if (_nonce == ulong.MaxValue) throw new NoiseException("Nonce exhausted; rekey required.");
        if (_key is null) return plaintext.ToArray();
        using var cipher = new ChaCha20Poly1305(_key);
        var nonce = NonceBytes();
        var output = new byte[plaintext.Length + 16];
        var tag = new byte[16];
        cipher.Encrypt(nonce, plaintext, output.AsSpan(0, plaintext.Length), tag, ad);
        tag.CopyTo(output.AsSpan(plaintext.Length));
        _nonce++;
        return output;
    }

    internal byte[] Decrypt(ReadOnlySpan<byte> ad, ReadOnlySpan<byte> ciphertext)
    {
        if (_nonce == ulong.MaxValue) throw new NoiseException("Nonce exhausted; rekey required.");
        if (_key is null) return ciphertext.ToArray();
        if (ciphertext.Length < 16) throw new NoiseException("Ciphertext too short.");
        using var cipher = new ChaCha20Poly1305(_key);
        var output = new byte[ciphertext.Length - 16];
        try { cipher.Decrypt(NonceBytes(), ciphertext[..^16], ciphertext[^16..], output, ad); }
        catch (CryptographicException) { throw new NoiseException("Decrypt failed."); }
        _nonce++;
        return output;
    }

    private byte[] NonceBytes()
    {
        var nonce = new byte[12];
        BitConverter.TryWriteBytes(nonce.AsSpan(4), BitConverter.IsLittleEndian ? _nonce : Swap(_nonce));
        if (!BitConverter.IsLittleEndian) { /* nonce counter is little-endian per Noise */ }
        return nonce;
    }
    private static ulong Swap(ulong v) =>
        (v >> 56) | ((v >> 40) & 0xFF00) | ((v >> 24) & 0xFF0000) | ((v >> 8) & 0xFF000000) |
        ((v << 8) & 0xFF00000000) | ((v << 24) & 0xFF0000000000) | ((v << 40) & 0xFF000000000000) | (v << 56);
}

internal static class NoiseKdf
{
    public static byte[] Hmac(byte[] key, ReadOnlySpan<byte> data)
    {
        using var hmac = new HMACSHA256(key);
        return hmac.ComputeHash(data.ToArray());
    }
    public static List<byte[]> Hkdf(byte[] salt, ReadOnlySpan<byte> ikm, int count)
    {
        var temp = Hmac(salt, ikm);
        var outputs = new List<byte[]>();
        var previous = Array.Empty<byte>();
        for (var i = 1; i <= count; i++)
        {
            var input = new byte[previous.Length + 1];
            previous.CopyTo(input, 0);
            input[^1] = (byte)i;
            previous = Hmac(temp, input);
            outputs.Add(previous);
        }
        return outputs;
    }
    public static byte[] Hash(ReadOnlySpan<byte> data) => SHA256.HashData(data);
    public static byte[] Concat(ReadOnlySpan<byte> a, ReadOnlySpan<byte> b)
    {
        var output = new byte[a.Length + b.Length];
        a.CopyTo(output); b.CopyTo(output.AsSpan(a.Length));
        return output;
    }
}

internal sealed class NoiseSymmetric
{
    public byte[] ChainKey;
    public byte[] HashValue;
    public DeviceCipher Cipher = new();
    public NoiseSymmetric(byte[] prologue)
    {
        var name = Hex.Utf8("Noise_XX_25519_ChaChaPoly_SHA256");
        HashValue = name.Length <= 32
            ? NoiseKdf.Concat(name, new byte[32 - name.Length])
            : NoiseKdf.Hash(name);
        ChainKey = HashValue;
        MixHash(prologue);
    }
    public void MixHash(ReadOnlySpan<byte> data) => HashValue = NoiseKdf.Hash(NoiseKdf.Concat(HashValue, data));
    public void MixKey(ReadOnlySpan<byte> ikm)
    {
        var outputs = NoiseKdf.Hkdf(ChainKey, ikm, 2);
        ChainKey = outputs[0];
        Cipher = new DeviceCipher(outputs[1]);
    }
    public byte[] EncryptAndHash(ReadOnlySpan<byte> plaintext)
    {
        var value = Cipher.Encrypt(HashValue, plaintext);
        MixHash(value);
        return value;
    }
    public byte[] DecryptAndHash(ReadOnlySpan<byte> ciphertext)
    {
        var value = Cipher.Decrypt(HashValue, ciphertext);
        MixHash(ciphertext);
        return value;
    }
}

public sealed record DeviceTransportKeys(DeviceCipher Sender, DeviceCipher Receiver, byte[] HandshakeHash, byte[] RemoteStatic);

public sealed class DeviceHandshake
{
    private readonly bool _isInitiator;
    private readonly byte[] _staticPrivate;
    private readonly byte[] _staticPublic;
    private byte[]? _ephemeralPrivate;
    private byte[]? _remoteEphemeral;
    private NoiseSymmetric _state;
    private int _step;
    public byte[]? RemoteStatic { get; private set; }

    public DeviceHandshake(bool isInitiator, byte[] staticPrivate, byte[]? ephemeralPrivate = null, byte[]? prologue = null)
    {
        _isInitiator = isInitiator;
        _staticPrivate = staticPrivate;
        _staticPublic = X25519.PublicKeyFromPrivate(staticPrivate);
        _ephemeralPrivate = ephemeralPrivate;
        _state = new NoiseSymmetric(prologue ?? Hex.Utf8("Converse/1"));
    }

    private byte[] MakeEphemeral()
    {
        if (_ephemeralPrivate is not null) return _ephemeralPrivate;
        var (priv, _) = X25519.GenerateKeyPair();
        _ephemeralPrivate = priv;
        return priv;
    }

    public byte[] WriteMessage(ReadOnlySpan<byte> payload)
    {
        if (_isInitiator && _step == 0)
        {
            var e = MakeEphemeral();
            var pub = X25519.PublicKeyFromPrivate(e);
            _state.MixHash(pub);
            _step = 1;
            return NoiseKdf.Concat(pub, _state.EncryptAndHash(payload));
        }
        if (!_isInitiator && _step == 1)
        {
            var remoteE = _remoteEphemeral ?? throw new NoiseException("Wrong handshake order.");
            var e = MakeEphemeral();
            var pub = X25519.PublicKeyFromPrivate(e);
            _state.MixHash(pub);
            _state.MixKey(X25519.SharedSecret(e, remoteE));
            var sealedStatic = _state.EncryptAndHash(_staticPublic);
            _state.MixKey(X25519.SharedSecret(_staticPrivate, remoteE));
            _step = 2;
            return NoiseKdf.Concat(NoiseKdf.Concat(pub, sealedStatic), _state.EncryptAndHash(payload));
        }
        if (_isInitiator && _step == 2)
        {
            var remoteE = _remoteEphemeral ?? throw new NoiseException("Wrong handshake order.");
            var sealedStatic = _state.EncryptAndHash(_staticPublic);
            _state.MixKey(X25519.SharedSecret(_staticPrivate, remoteE));
            _step = 3;
            return NoiseKdf.Concat(sealedStatic, _state.EncryptAndHash(payload));
        }
        throw new NoiseException("Wrong handshake order.");
    }

    public byte[] ReadMessage(ReadOnlySpan<byte> message)
    {
        if (!_isInitiator && _step == 0)
        {
            if (message.Length < 32) throw new NoiseException("Invalid handshake message.");
            _remoteEphemeral = message[..32].ToArray();
            _state.MixHash(_remoteEphemeral);
            _step = 1;
            return _state.DecryptAndHash(message[32..]);
        }
        if (_isInitiator && _step == 1)
        {
            if (message.Length < 80 || _ephemeralPrivate is null) throw new NoiseException("Invalid handshake message.");
            _remoteEphemeral = message[..32].ToArray();
            _state.MixHash(_remoteEphemeral);
            _state.MixKey(X25519.SharedSecret(_ephemeralPrivate, _remoteEphemeral));
            RemoteStatic = _state.DecryptAndHash(message[32..80]);
            _state.MixKey(X25519.SharedSecret(_ephemeralPrivate, RemoteStatic));
            _step = 2;
            return _state.DecryptAndHash(message[80..]);
        }
        if (!_isInitiator && _step == 2)
        {
            if (message.Length < 48 || _ephemeralPrivate is null) throw new NoiseException("Invalid handshake message.");
            RemoteStatic = _state.DecryptAndHash(message[..48]);
            _state.MixKey(X25519.SharedSecret(_ephemeralPrivate, RemoteStatic));
            _step = 3;
            return _state.DecryptAndHash(message[48..]);
        }
        throw new NoiseException("Wrong handshake order.");
    }

    public DeviceTransportKeys Finish()
    {
        if (_step != 3 || RemoteStatic is null) throw new NoiseException("Wrong handshake order.");
        var outputs = NoiseKdf.Hkdf(_state.ChainKey, ReadOnlySpan<byte>.Empty, 2);
        var first = new DeviceCipher(outputs[0]);
        var second = new DeviceCipher(outputs[1]);
        return _isInitiator
            ? new DeviceTransportKeys(first, second, _state.HashValue, RemoteStatic)
            : new DeviceTransportKeys(second, first, _state.HashValue, RemoteStatic);
    }
}
