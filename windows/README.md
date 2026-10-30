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
| `main.swift`/`Workspace.swift`/`DeviceUI.swift` | `Converse.Windows` (WinUI 3, namespace `Converse.App`) | Dense sidebar, home sections with Park/Take/Close, single pane, pairing sheet, Settings. Return sends. |

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
- Groups (`converse-groups-v1`, additive on the v1 envelope): admission
  through any member joins the whole fabric; membership gossips as
  versioned records with removal tombstones (`fabric.members`).
  `group.review` carries the BARE join request; only `group.review.detail`
  and `group.approve` wrap it with the reviewed code. Session traffic
  never crosses a group boundary in either direction. Legacy stores
  migrate deterministically with the shared vector in `docs/groups.md`;
  a revoked self never migrates and only a reviewed join readmits.

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
   (locked schema 1: `{schemaVersion, title, appVersion, appBuild,
   sourceCommit (full hash, -dirty in development), sourceURL,
   sourceSHA256, topics[{id, title, markdown, plainText}]}`; version from
   the authoritative root `VERSION.json`; code fences never create
   topics; relative links become absolute GitHub links; unknown metadata
   is ignored on load). The script's default output is repo-root
   `Help/Content.json`; the Windows build passes `--out
   Assets/help.json`, which is generated and never checked in.
   `Converse.Core/Help.cs` loads either name and searches case-insensitively
   with title hits ranked first.
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


## Agents (0.5.22)

Windows can create and host paused agents, store its Meta API key in Windows Credential Manager, run bounded loops, search the web, generate sentiment art, and show scoreboards. Agent Setup accepts fixed intervals or supported text schedules and previews upcoming runs. Session scope is explicit and group-bound; remote controls use durable IDs and revision-checked settings without acquiring display leases. Mac and iPad can create/configure/run a Windows-hosted agent; Windows can do the same on a Mac home.

Voice, Discord alerts, and file triggers remain Mac-home features in this release. Windows rejects enabling those unsupported options rather than silently accepting them. Jolly remains routed through the existing Mac bridge. A local or group session must be taught switchboard messaging before accepting messages; the sidebar context menu provides that action. Commands execute only from a complete authoritative final response consisting of one `converse` fenced JSON block.

Offline devices show only a dimmed device name. Every session row reserves the same P/1/2/3/X columns; remote X is disabled. Sidebar collapse/restore uses the native pushpin icon. Quit warnings count agents with enabled loops, not every saved agent.

For isolated UI validation, set `CONVERSE_DATA_DIR` to a disposable directory before launching. This prevents test sessions from touching the normal archive.

## Session names and pane headers

Right-click a session in the sidebar and choose **Rename…**. Local sessions rename immediately. For a remote session, first take it into a pane; the home applies the rename through the existing acknowledged command flow. Rename preserves the conversation and draft. Pane headers show the provider mark beside the title. Submitted prompts omit outer blank lines for display while retaining their original stored and copied text.

Pane titles refresh in place when a session is renamed, including on a remote viewer. Renaming preserves the draft and editor position. Device update sequences, boot generations, and lease epochs persist in `device-sync-counters.json`; keep this file with the device identity when backing up the profile. Older Windows builds did not persist these counters. Do not downgrade and run the old build against the updated live profile.

## Windows update and clipboard checks

The Windows VM uses `C:\dev\converse-production\` as its fixed production
app directory. Build into a separate versioned directory first. After a
coordinated normal quit, back up and hash-verify the real profile, mirror the
complete new app into the fixed directory, and hash-verify the result. Keep
versioned folders as rollback sources; do not overwrite a running app or
change the taskbar target on each update. Preserve the scoped firewall rules
Richard approved for the fixed executable (TCP 48721 and UDP 5353, local
subnet). Test executables do not need firewall rules: every device-service
test uses `enableDiscovery: false, loopbackOnly: true`.

Clipboard images enter the normal attachment path, not RichEdit embedded
objects. Clipboard text is inserted as plain text. The draft's default,
existing text, and insertion format all use the same normal blue 16-DIP
font (12 points in RichEdit). Check typing into an empty draft, copying an
italic transcript passage into the draft, pasting a screenshot, continuing
to type, and clearing images. A screenshot must create an actual PNG in
Attachments and leave no object-placeholder character in the draft.
