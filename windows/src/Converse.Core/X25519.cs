using Org.BouncyCastle.Crypto.Agreement;
using Org.BouncyCastle.Crypto.Generators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;

namespace Converse.Core;

// X25519 via BouncyCastle (vetted, maintained). Production code must never
// return to hand-rolled field arithmetic: functional vectors do not prove
// timing resistance (RFC 7748 section 5.1). All-zero outputs (low-order /
// small-subgroup public keys) are rejected per RFC 7748 section 6.1.
public static class X25519
{
    public static (byte[] PrivateKey, byte[] PublicKey) GenerateKeyPair()
    {
        var generator = new X25519KeyPairGenerator();
        generator.Init(new Org.BouncyCastle.Crypto.KeyGenerationParameters(new SecureRandom(), 255));
        var pair = generator.GenerateKeyPair();
        var priv = ((X25519PrivateKeyParameters)pair.Private).GetEncoded();
        var pub = ((X25519PublicKeyParameters)pair.Public).GetEncoded();
        return (priv, pub);
    }

    public static byte[] PublicKeyFromPrivate(ReadOnlySpan<byte> privateKey)
    {
        if (privateKey.Length != 32) throw new ArgumentException("X25519 private keys are 32 bytes.");
        return new X25519PrivateKeyParameters(privateKey.ToArray(), 0).GeneratePublicKey().GetEncoded();
    }

    public static byte[] SharedSecret(ReadOnlySpan<byte> privateKey, ReadOnlySpan<byte> publicKey)
    {
        if (privateKey.Length != 32 || publicKey.Length != 32)
            throw new ArgumentException("X25519 keys are 32 bytes.");
        var agreement = new X25519Agreement();
        agreement.Init(new X25519PrivateKeyParameters(privateKey.ToArray(), 0));
        var secret = new byte[32]; // X25519 agreement output is always 32 bytes.
        agreement.CalculateAgreement(new X25519PublicKeyParameters(publicKey.ToArray(), 0), secret, 0);
        if (secret.All(b => b == 0))
            throw new NoiseException("Low-order X25519 public key rejected.");
        return secret;
    }
}
