using System.Numerics;
using System.Security.Cryptography;

namespace Converse.Core;

// RFC 7748 X25519 via BigInteger Montgomery ladder. Chosen for auditability
// over speed: handshakes perform only a few scalar multiplications.
// Validated by the external Noise vector in Converse.Core.Tests.
public static class X25519
{
    private static readonly BigInteger P = (BigInteger.One << 255) - 19;
    private const int A24 = 121665;

    public static (byte[] PrivateKey, byte[] PublicKey) GenerateKeyPair()
    {
        var priv = RandomNumberGenerator.GetBytes(32);
        return (priv, PublicKeyFromPrivate(priv));
    }

    public static byte[] PublicKeyFromPrivate(ReadOnlySpan<byte> privateKey)
    {
        Span<byte> basePoint = stackalloc byte[32];
        basePoint[0] = 9;
        return ScalarMultiply(privateKey, basePoint);
    }

    public static byte[] SharedSecret(ReadOnlySpan<byte> privateKey, ReadOnlySpan<byte> publicKey) =>
        ScalarMultiply(privateKey, publicKey);

    private static byte[] ScalarMultiply(ReadOnlySpan<byte> scalarBytes, ReadOnlySpan<byte> uBytes)
    {
        if (scalarBytes.Length != 32 || uBytes.Length != 32)
            throw new ArgumentException("X25519 keys are 32 bytes.");
        var k = scalarBytes.ToArray();
        k[0] &= 248; k[31] &= 127; k[31] |= 64;
        var scalar = DecodeLittleEndian(k);
        var u = uBytes.ToArray();
        u[31] &= 127;
        var x1 = DecodeLittleEndian(u);
        BigInteger x2 = 1, z2 = 0, x3 = x1, z3 = 1;
        var swap = 0;
        for (var t = 254; t >= 0; t--)
        {
            var bit = (int)((scalar >> t) & 1);
            swap ^= bit;
            if (swap == 1) (x2, x3) = (x3, x2);
            if (swap == 1) (z2, z3) = (z3, z2);
            swap = bit;
            var a = Mod(x2 + z2); var aa = Mod(a * a);
            var b = Mod(x2 - z2); var bb = Mod(b * b);
            var e = Mod(aa - bb);
            var c = Mod(x3 + z3); var d = Mod(x3 - z3);
            var da = Mod(d * a); var cb = Mod(c * b);
            x3 = Mod((da + cb) * (da + cb));
            z3 = Mod(x1 * Mod((da - cb) * (da - cb)));
            x2 = Mod(aa * bb);
            z2 = Mod(e * Mod(aa + A24 * e));
        }
        if (swap == 1) (x2, x3) = (x3, x2);
        if (swap == 1) (z2, z3) = (z3, z2);
        var result = Mod(x2 * BigInteger.ModPow(Mod(z2), P - 2, P));
        return EncodeLittleEndian(result);
    }

    private static BigInteger Mod(BigInteger value)
    {
        var r = value % P;
        return r.Sign < 0 ? r + P : r;
    }

    private static BigInteger DecodeLittleEndian(ReadOnlySpan<byte> bytes)
    {
        var little = new byte[bytes.Length + 1];
        bytes.CopyTo(little);
        return new BigInteger(little, isUnsigned: false, isBigEndian: false);
    }

    private static byte[] EncodeLittleEndian(BigInteger value)
    {
        var raw = value.ToByteArray(isUnsigned: true, isBigEndian: false);
        var output = new byte[32];
        Array.Copy(raw, output, Math.Min(32, raw.Length));
        return output;
    }
}
