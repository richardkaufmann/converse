# Converse for Windows — design

Full symmetric peer of the Mac app: the Windows 11 PC is **home** for its
own sessions (runs Claude Code, Codex, and Muse locally) and a **viewer**
for Mac sessions, paired with the same protocol. No cloud account.
Execution, credentials, working folders, and transcripts stay on the home
device. One active display per session, home-arbitrated.

Decisions (Richard, 2026-10-27): full home + viewer; WinUI 3 + C# on
.NET 8; code lives in this repo under `windows/` so the wire protocol
cannot drift from `Sources/Device*.swift`.

## Architecture

| Mac (Swift) | Windows (C#) | Notes |
|---|---|---|
| `DeviceProtocol.swift` | `Converse.Core/Protocol.cs` | Same JSON keys, kinds, limits. Swift `Data` ↔ base64 `byte[]`. |
| `DeviceCrypto.swift` | `Converse.Core/Noise.cs` + `X25519.cs` | Noise `XX_25519_ChaChaPoly_SHA256`, prologue `Converse/1`, 128-bit verification code (8 groups). |
| `DeviceIdentity.swift` (Keychain) | `Converse.Core` identity + DPAPI (app layer) | Core stores via file for tests; app protects key with DPAPI `CurrentUser`. Only *missing* key may create identity. |
| `DeviceSync.swift` | `Converse.Core/Stores.cs` | Lease epochs persisted fail-closed, command store `accepted→running→completed`, `uncertain` recovery, viewer outbox, draft versions keyed by global ID. |
| `DeviceTransport.swift` (Network.framework) | `Converse.Core` service over `TcpListener/TcpClient` (app milestone) | TCP port 48721, manual address for VPN. mDNS `_converse._tcp` via Windows `Dnssd` APIs later behind the same interface. |
| `Store`/`Session` + providers | `Converse.Core` session engine (milestone 2) | Spawn `claude`, `codex`, `muse` from PATH; parse the same JSONL/MSP events; `%LocalAppData%\Converse` data folder (was `~/.converse`). |
| `main.swift`/`Workspace.swift`/`DeviceUI.swift` | `Converse.App` (WinUI 3) | Dense sidebar, home sections with P/1/2/3, up to 3 panes, pairing sheet, Settings. Return sends. |

## Wire compatibility (must not drift)

- Transport: 2-byte big-endian Noise messages over TCP; plaintext stream
  inside Noise is 4-byte big-endian framed JSON envelopes (`version: 1`).
- Handshake payloads carry `DeviceHello` JSON; `deviceID` is the lowercase
  hex SHA-256 of the static X25519 public key; hello ID must equal the
  authenticated key hash or the peer disconnects.
- Pairing completes Noise first, both users compare **all 8 groups** of
  the 128-bit code, both send `pair.confirm`; pin only after durable save.
- Commands bind `origin device + global session + payload hash + epoch`.
  Only `completed` clears the outbox. `uncertain` is never auto-resent.
- Attachments cross as SHA-256 hashes; blobs verify before use; home file
  paths never cross the wire.

## Milestones

1. **Core (this commit):** protocol DTOs + framing, X25519 + Noise XX,
   lease/draft/command/outbox stores, vector + harness tests. Runs with
   plain `dotnet` — no NuGet packages beyond the BCL.
2. **App shell:** WinUI 3 window, sidebar/panes, local echo/test provider,
   pairing by manual address, viewer take/send against a Mac home.
3. **Windows home:** real `claude`/`codex` JSONL + `muse` MSP adapters,
   approvals/questions, queue/inject parity, attachments.
4. **Discovery + hardening:** mDNS advertise/browse, sleep/wake,
   firewall prompt guidance, signed MSIX packaging.

## Build and test (on the Windows box)

```powershell
dotnet run --project windows/src/Converse.Core.Tests
dotnet build windows/src/Converse.Windows -c Release
```

The core test runner is a console app with `PASS:`/`FAIL:` lines mirroring
`Sources/DeviceSyncTests.swift`, including the external cacophony Noise
vector (byte-for-byte) and the MITM different-codes regression. It has no
NuGet dependencies. `ChaCha20Poly1305` requires Windows or Linux; the
runner prints platform support and fails loudly if unavailable.

The WinUI app is **unpackaged** WinUI 3 (`Microsoft.WindowsAppSDK` NuGet,
restored on first build on Windows). It cannot be built on macOS; the
skeleton in `src/Converse.Windows` is authored for first compile on the PC.

## Data locations (Windows)

- `%LocalAppData%\Converse\sessions.json`, `Attachments\`, `devices.json`,
  `device-commands.json`, `device-outbox.json`, `device-drafts.json`,
  `device-sync.json` — same filenames and semantics as macOS.
- Device private key: DPAPI-protected blob in the same folder (app layer);
  test/core file storage is plain and must never ship as the app default.
