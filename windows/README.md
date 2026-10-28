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
| `main.swift`/`Workspace.swift`/`DeviceUI.swift` | `Converse.Windows` (WinUI 3, namespace `Converse.App`) | Dense sidebar, home sections with P/1/2/3, up to 3 panes, pairing sheet, Settings. Return sends. |

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

1. **Core (done, tested):** protocol DTOs + framing, Noise XX with
   BouncyCastle X25519 (vetted constant-time primitive; all-zero outputs
   rejected), lease/draft/command/outbox stores, vector + harness tests.
2. **Engine + service (done, tested):** `SessionEngine.cs` runs real
   `claude`/`codex` JSONL turns (Codex final-answer capture included) and
   Muse over MSP (`MuseMsp.cs`: initialize/load/submit/interrupt,
   approvals + questions with server-minted choice IDs);
   `DeviceService.cs` pairs over TCP, serves home leases/transcripts/
   commands/blobs, and views remote homes with a durable outbox.
   Loopback pair → take → rename and MSP approval → decide are covered.
3. **Discovery + app shell (wired, first compile on PC):** minimal mDNS
   advertise/browse for `_converse._tcp` (`Mdns.cs`, hints only); WinUI 3
   sidebar + pane + composer bound to the real store/service,
   manual-address connect, discovered-device rows, Pair/Approve dialog.
4. **Sidebar pin + Setup/Help (done, core tested):** pin immediately left
   of the Conversations header collapses the sidebar to zero width and
   restores the last user width (drag the divider; clamped to half the
   window; persisted in `window-layout.json`). Collapse is layout only —
   it never parks a session or releases a lease — and a restore pin stays
   with the transcript. Setup lives under the **Converse** menu (CLI
   presence + data folder); **Help > Converse Help** is searchable offline
   documentation rendered from the shared versioned artifact generated at
   build time by `scripts/build-help.py` from the tracked `README.md`
   (schema 1: `{schemaVersion, appVersion, sourceCommit, topics[{id,
   title, markdown, plainText}]}`; generated `Assets/help.json` is not
   checked in). `Converse.Core/Help.cs` loads/searches it identically for
   any future host.
5. **Next:** three-pane workspace placements, blue-draft native editor
   parity, DPAPI identity protection in the app layer, sleep/wake,
   signed MSIX packaging (`windows/packaging/Package.appxmanifest`).

## Build and test (on the Windows box)

```powershell
dotnet run --project windows/src/Converse.Core.Tests
dotnet build windows/src/Converse.Windows -c Release
```

The app build regenerates offline Help from `README.md` when Python is on
PATH (`python scripts/build-help.py --out
windows/src/Converse.Windows/Assets/help.json`); without Python the build
still succeeds and Help states plainly that content is not included.

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
  `window-layout.json` holds only sidebar pin/width intent.
- Device private key: DPAPI-protected blob in the same folder (app layer);
  test/core file storage is plain and must never ship as the app default.
