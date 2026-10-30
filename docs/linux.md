# Linux headless home: frozen deployment contract v1

Status: approved implementation contract. This is not a release or acceptance
claim. The canonical base for the first implementation branch is
`f5de804` on `main`; Linux work is isolated on `feature/linux-home`.

## Scope and ownership

The Linux target is a headless Converse **home**. It runs provider CLIs and
Converse agents, owns its sessions and credentials, and participates in the
existing encrypted device fabric as a peer. It has no transcript GUI in v1.

The Mac and Windows apps gain a **Set up Linux** manager. The manager uses the
system OpenSSH client to provision and maintain the Linux home. The Windows
manager is the reference implementation; the Mac manager implements this same
contract after receiving the frozen schemas and base commit. The iPad remains a
viewer/controller and does not provision Linux in v1.

Implementation order is fixed:

1. Freeze these schemas and fake-SSH fixtures.
2. Add serialized Core seams and the Linux headless host.
3. Implement the Windows reference manager.
4. Implement the Mac manager against the same contract.
5. Run the VM and physical-device acceptance gates before any release claim.

Existing Mac/iPad/Windows local behavior and the current device wire protocol
remain unchanged. In particular, the Linux work does not change the current
`DeviceEnvelope` version or `DeviceHello.protocolVersion` value of `1`.
Typed attachments and a future device protocol version 2 are separate work.

## Non-negotiable invariants

1. **Home authority stays home.** Provider processes, working directories,
   provider logins, Converse identity keys, agent credentials, transcripts,
   drafts, queues, and side effects remain on the Linux machine.
2. **No credential copying.** A manager never copies a Mac/Windows provider
   login, SSH private key, passphrase, or Converse private identity to Linux.
   It may open an SSH terminal so the user can run each provider's own login
   flow on Linux.
3. **Three independent trust roots.** SSH host identity, Converse Noise
   identity, and release-signing identity are separate. Proof of one never
   substitutes for proof of another.
4. **No silent replay.** Every mutating admin, secret, service, pairing,
   session, and update request carries a durable operation ID. The daemon
   records a receipt bound to the operation kind, expected/actual device ID,
   and nonsecret payload before its side effect. An outcome that cannot be
   proven remains `uncertain`; a retry with the same operation ID returns the
   recorded operation and does not execute the side effect again.
5. **Rollback never rewinds authority.** Restoring application data or an old
   executable never rewinds Boot, HomeSeq, lease execution epochs, command
   receipts, membership generations, removal tombstones, or group-dissolution
   tombstones. The recovery ledger below is outside every application restore
   set.
6. **Fresh execution authority after restart.** A restart allocates fresh
   Boot and execution epochs before listening or admitting work. Commands
   bearing an old execution epoch are rejected without exception.
7. **Guarded display restoration is not command authority.** The ledger may
   remember the last authorized display owner and take generation so that the
   same viewer can be offered a fresh lease after a restart when nobody else
   took the display. That memory never revives the old epoch.
8. **No forced drain.** Update activation quiesces and drains. If work does
   not drain by the deadline, activation aborts and the old release resumes.
   Killing active work is a separate, explicit user action, never part of the
   ordinary Update button.
9. **Secrets never enter process arguments, logs, generic admin JSON,
   durable receipts, fixtures with real values, or status.** Secret values
   travel only as the raw tail of the dedicated `secret-stdin` stream over the
   already trusted SSH/local-socket path. Receipts and status expose backend,
   stored/effective version, pending-restart state, and timestamps only.
10. **No shell construction from user data.** Managers invoke OpenSSH with an
    argument array. Remote commands are fixed strings or the fixed bootstrap
    templates below. The only template substitution is a manager-generated
    bootstrap staging token matching `[A-Za-z0-9-]{32,64}`; it is validated
    before formatting and never comes from remote or free-form user input. No
    destination, path, name, or secret is otherwise interpolated into a local
    or remote shell command.

## Machine-readable contract

The schemas in `linux/contracts/schemas/` are normative for field names and
shapes. The examples in `linux/contracts/examples/` are valid instances.
Unknown JSON fields are ignored within admin API v1. Adding an optional field
is compatible; adding a required field, removing a field, or changing a
field's meaning requires a new version.

| Artifact | Version field | Purpose |
| --- | --- | --- |
| Admin request/response | `adminApiVersion: 1` | GUI-to-daemon control over SSH stdio or a local Unix socket |
| Status | inside admin response | Identity, release, supervisor, work, update, and secret metadata |
| Operation | inside admin response | Durable long-running or uncertain work |
| Pairing binding | `bindingVersion: 1` | Exact request/key/connection binding revalidated before any approval |
| Secret request/response | `secretApiVersion: 1` | Dedicated `secret-stdin` header/raw-value stream and metadata-only receipt |
| Release manifest | `manifestVersion: 1` | Signed Linux release description with readable/writable state range |
| Deployment registry | `registryVersion: 1` | Manager-local deployments plus provisional bootstrap recovery records |
| Recovery ledger | `ledgerVersion: 1` | Linux-local authority floor excluded from restore sets |

All timestamps in the new admin/deployment artifacts are RFC 3339 UTC strings.
Device IDs are lowercase SHA-256 hex of the 32-byte X25519 public key, exactly
as in `docs/fabric.md`; a “public-key fingerprint” in these schemas means that
same full 64-character value, never a short prefix. SHA-256 values are
lowercase hex. UUIDs use canonical hyphenated text. Recovery-ledger sequence,
Boot, HomeSeq, lease-epoch, membership-generation, and take-generation
high-water marks are bounded unsigned decimal **strings** from `0` through
`9007199254740992` (2^53), preserving exact cross-language JSON behavior.
Values above that bound fail closed. JSON text is UTF-8.

## Linux filesystem and releases

The installer uses the invoking Linux user's account; v1 does not require
`sudo` and does not create a system user.

- Executable link: `~/.local/bin/converse`
- Versioned releases: `~/.local/lib/converse/releases/<releaseID>/converse`
- Configuration: `${XDG_CONFIG_HOME:-~/.config}/converse`
- Application data: `${XDG_DATA_HOME:-~/.local/share}/converse`
- State: `${XDG_STATE_HOME:-~/.local/state}/converse`
- Incoming update bundles: `<state>/incoming/`
- Bootstrap staging: `~/.converse-bootstrap/<operationToken>/converse`
- Bootstrap receipts: `<state>/bootstrap-receipts/<operationToken>.json`
- Desired-running flag: `<state>/desired-running`
- Supervisor lock/PID: `<state>/supervisor.lock` and `<state>/supervisor.pid`
- Recovery ledger: `<state>/recovery-ledger/v1/ledger.json`
- Admin socket: `${XDG_RUNTIME_DIR}/converse/admin.sock`, falling back to
  `<state>/run/admin.sock` when `XDG_RUNTIME_DIR` is unavailable

Converse-owned directories are mode `0700`. Identity, secret, and ledger files
are mode `0600`. The admin socket is mode `0600` and is accepted only from the
same Unix user. There is no TCP admin listener.

Exactly one supervisor owns the daemon:

- **Primary:** a systemd **user** service. The installer may explain that
  `loginctl enable-linger` can require a separate privileged action by the
  user. The manager never runs `sudo` for the user.
- **Fallback:** a `@reboot` entry plus a periodic
  `* * * * *` guarded entry, both invoking `converse supervise`. The
  supervisor acquires its own lock, records its PID, and starts/restarts the
  daemon only while the persistent desired-running flag is true. A periodic
  tick that finds the supervisor lock held exits without starting a second
  copy.

The installer records the chosen supervisor and desired-running state in
status. It never installs both. A second daemon instance must fail closed on
the single-instance lock rather than share state. `service.stop` persists
desired-running false before stopping the supervisor/daemon; `service.start`
persists true before asking the chosen supervisor to start it.

### Release bundle

A Linux release bundle is a gzip-compressed tar archive containing only these
regular files at the archive root:

- `converse`
- `manifest.json`
- `manifest.json.sig`
- `LICENSE`
- `VERSION.json`

Absolute paths, parent traversal, links, devices, duplicate entries, extra
entries, and non-regular files are rejected. `manifest.json.sig` is a detached
Ed25519 signature over the exact bytes of `manifest.json`, encoded as standard
base64 in a single-line text file. Verifying exact bytes avoids inventing a
JSON canonicalization scheme. The manifest names a `signingKeyID`; only public
keys embedded in the manager and daemon are trusted. After signature
verification, the verifier checks the executable's architecture, byte size,
and SHA-256 against the manifest before staging it. The signed manifest also
states `minimumReadableStateSchemaVersion`,
`maximumReadableStateSchemaVersion`, and `writableStateSchemaVersion`.
Semantically, minimum ≤ writable ≤ maximum. Activation requires the currently
written state schema to lie in the new release's readable range. Probation
does not migrate or write a new state schema, so rollback remains possible;
after health commit, a later rollback is allowed only when the then-current
written schema lies in the previous release's signed readable range.

The manager verifies a downloaded bundle locally. The Linux daemon verifies it
again after upload. A valid SSH login is not a substitute for release
signature verification.

## OpenSSH manager contract

The managers use the system `ssh` and `scp` executables. They do not embed an
SSH library, ask for an SSH password, store a passphrase, or copy a private
key. Version 1 requires key or agent authentication that OpenSSH can complete
without manager-owned prompting. OpenSSH 9.0 or newer is required for
automated `scp`, whose SFTP-based protocol avoids legacy remote-shell path
interpretation. Managers never pass `scp -O`.

An SSH destination is one OpenSSH destination token or config alias. It is
passed as one argument, is at most 255 bytes, contains no whitespace or
control characters, and never begins with `-`. Host, user, port, identity
file, and `ProxyJump` may come from the user's OpenSSH configuration. The
manager records the alias and the approved host-key fingerprint, not private
key material.

### Phase A: first host-key trust

A fake process, piped stdin, `StrictHostKeyChecking=accept-new`, or a blind
`yes` cannot establish operating-system-specific trust behavior. First trust
therefore uses a real local pseudo-terminal: a POSIX PTY on macOS or ConPTY on
Windows. The automated alternative is **Open SSH Terminal**, which launches
the system terminal for the same purpose.

The trust-only process explicitly uses `BatchMode=no` and `RequestTTY=no`.
`RequestTTY=no` controls allocation of a remote tty; the local PTY/ConPTY or
system terminal is where OpenSSH presents its own host-key prompt.
**The user personally types the answer into that real terminal.** The GUI may
display/mirror the prompt, but it never synthesizes `yes`, sends keystrokes on
the user's behalf, or turns a GUI click into the terminal answer.
Authentication methods are deliberately disabled for this process, and its
fixed remote command is `true`. The manager:

1. Shows or mirrors the host-key fingerprint that OpenSSH itself presents, in
   full, for comparison with a trusted source.
2. Leaves approval/cancellation entirely to the user's own typed answer at
   OpenSSH's real prompt.
3. Treats the following expected authentication failure as **not** a failed
   trust decision. Because authentication is disabled, the trust-only process
   can legitimately exit unsuccessfully after installing the approved key.
4. Re-reads/verifies the installed fingerprint and records it in the
   deployment registry.
5. Runs a separate strict, authenticated preflight before provisioning.

If the prompt shape is unexpected, the fingerprint cannot be parsed in full,
or the key found afterward differs from the approved fingerprint, setup stops.
Real PTY/ConPTY tests on macOS and Windows, including a `ProxyJump` route, are
acceptance gates; fake-SSH transcripts cannot replace them.

### Phase B: automated SSH

Every later non-interactive `ssh` invocation uses this argument prefix in this
order, followed by `--`, the destination, and one fixed remote command:

```text
ssh
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o RequestTTY=no
  -o ForwardAgent=no
  -o ForwardX11=no
  -o ClearAllForwardings=yes
  -o ConnectTimeout=10
  -o ServerAliveInterval=5
  -o ServerAliveCountMax=2
  --
  <destination>
  <fixed-remote-command>
```

Automated `scp` uses the same `BatchMode`, strict host-key, no-agent-
forwarding, timeout, and keepalive options that `scp` accepts. The local file
is one argument. The remote target is one argument. Bootstrap upload uses the
operation-owned relative target `.converse-bootstrap/<operationToken>/converse`
after that token's directory has been created atomically. Update upload uses only a
daemon-returned absolute path that is exactly
`<status.filesystem.stateRoot>/incoming/<token>.tar.gz`, where the token
matches `[A-Za-z0-9-]{32,64}`. The manager rejects relative paths, traversal,
path separators inside the token, and every other remote path.

The complete fixed remote-command allowlist for bootstrap and administration
is below. `<operationToken>` is the only substitution and must match
`[A-Za-z0-9-]{32,64}` before formatting:

| Purpose | Exact remote command/template |
| --- | --- |
| Host-key trust probe | `true` |
| Create operation-owned bootstrap staging | `mkdir -p "$HOME/.converse-bootstrap" && mkdir "$HOME/.converse-bootstrap/<operationToken>"` |
| Bootstrap preflight | `chmod 700 "$HOME/.converse-bootstrap/<operationToken>/converse" && exec "$HOME/.converse-bootstrap/<operationToken>/converse" preflight` |
| Install uploaded binary | `exec "$HOME/.converse-bootstrap/<operationToken>/converse" install-self` |
| Read installation receipt | `exec "$HOME/.local/bin/converse" bootstrap-receipt` |
| Clean only this operation's staging | `rm -rf "$HOME/.converse-bootstrap/<operationToken>"` |
| Admin request (live socket) | `exec "$HOME/.local/bin/converse" admin-request` |
| Dedicated secret stream | `exec "$HOME/.local/bin/converse" secret-stdin` |
| Offline identity/status | `exec "$HOME/.local/bin/converse" offline-status` |
| Service start while stopped | `exec "$HOME/.local/bin/converse" service-start` |
| Service stop while stopped or running | `exec "$HOME/.local/bin/converse" service-stop` |

No other remote command is generated by the manager in v1. Every manager
persists a provisional registry record with its bootstrap operation ID,
staging token, and stage **before** creating the staging directory. Two
managers therefore use different staging directories and clean up only their
own token. `install-self` receives one nonsecret JSON line on stdin naming
the operation ID and staging token; it writes an idempotent installation
receipt under the state root before reporting success. Re-running the same
operation/token with the same executable hash returns that receipt/status
without resetting identity or reinstalling over a different release. After a
disconnect in `install_requested` or `uncertain`, the manager queries
`bootstrap-receipt` and offline/online status with the same provisional
record; it never starts a replacement operation merely to retry.

`preflight` and `offline-status` each print exactly one JSON status object.
Before installation it has `runtime.processState` `not_installed`; when an
installed daemon is stopped, offline status derives identity from the local
key/ledger and reports `stopped`, admission `closed_stopped`, and the
persistent desired-running value. It does not create an identity, allocate a
Boot, or start the daemon.

For provider login, **Open SSH Terminal** launches an interactive system
terminal running plain `ssh -- <destination>`. The manager does not inject
commands, capture output, or read credentials from that terminal.

### SSH result classification

Managers classify SSH transport failure before attempting to parse admin JSON:

| Observation | Manager classification |
| --- | --- |
| `ssh`/`scp` executable missing | `ssh_not_found` |
| Exit 255 with host-key verification failure | `ssh_host_key_changed` |
| Exit 255 with permission/authentication failure in an automated call | `ssh_auth_failed` |
| Exit 255 with name, route, refusal, or timeout failure | `ssh_unreachable` |
| Valid remote process output but no valid admin envelope | `ssh_protocol_error` |
| Connection loss after a mutating request may have been accepted | `ssh_disconnected_uncertain` |
| Trust-only process auth failure after the approved key was installed | `trust_captured_verify_then_strict_preflight` |

Stderr matching is used only to choose user-facing classification. It never
grants trust, changes identity, or marks an operation successful. Raw stderr
shown to the user is bounded and treated as untrusted text.

## Local admin API

One `converse` binary provides the daemon and local administration. The live
SSH entry point is `converse admin-request`. It reads exactly one UTF-8 JSON
request line from stdin, forwards that line to the daemon's Unix socket, and
writes exactly one JSON response line to stdout. The same newline-delimited
framing is used on the Unix socket. Pretty-printed JSON, multiple objects,
trailing non-whitespace, requests over 64 KiB, and responses over 1 MiB are
rejected.

Stopped-daemon maintenance does not use that socket. `offline-status` is
read-only. `service-start` and `service-stop` accept the same one-line admin
envelope with operations `service.start` / `service.stop`, validate the
offline identity and durable operation receipt locally, persist the
desired-running flag, and invoke only the recorded supervisor. They return
the same response envelope. When the daemon is already running, the manager
may use those fixed commands for start/stop so one code path owns the flag
and supervisor. Backup, restore, log collection, and uninstall are explicitly
deferred from admin v1 and remain SSH-terminal/support operations.

The request envelope is:

```json
{
  "adminApiVersion": 1,
  "requestID": "00000000-0000-4000-8000-000000000001",
  "operation": "status.get",
  "expectedDeviceID": null,
  "operationID": null,
  "payload": {}
}
```

`expectedDeviceID` is required for every operation after a deployment has a
recorded Converse identity. The daemon compares it with its own device ID
before performing work and returns `identity_mismatch` without side effects on
mismatch. This catches an SSH alias that now reaches the wrong Linux home; it
does not replace Noise authentication inside the fabric.

Every mutating request carries a client-generated `operationID`. Before any
side effect, the daemon durably records the operation ID, operation kind,
actual device ID, a request SHA-256, and an `accepted` state in the recovery
ledger. The hash input is the canonical JSON object
`{"expectedDeviceID": ..., "operation": ..., "payload": ...}`, encoded with
object keys sorted ordinally at every depth, array order preserved, strings
JSON-escaped, numbers kept in their received lexical form, and no
insignificant whitespace. For the dedicated secret stream, “payload” in that
tuple is only the nonsecret header metadata plus a device-local HMAC
commitment; neither the value nor a bare value hash is stored in the ledger.
A retry with the same operation ID, kind, expected device, and request hash
returns the recorded operation/result reference. Reusing the ID for any other
tuple is an `operation_conflict`. If SSH disconnects before a valid response,
the manager marks the local attempt uncertain, reconnects, and issues
`operation.get`; it never chooses a new operation ID merely to retry.

The response envelope contains `ok`, `result`, `operation`, and `error`.
Exactly one response line is produced for a well-formed request. Exit code `0`
means a valid envelope was produced, including `ok: false`. Exit code `70`
means the CLI could not reach the daemon but still produced a
`daemon_unavailable` envelope. Exit code `64` means local usage or stdin was
invalid and no admin result should be inferred. SSH reserves exit `255` for
transport failure, which the manager classifies before JSON parsing.

### Operations in v1

| Operation | Payload essentials | Result |
| --- | --- | --- |
| `status.get` | none | Status object |
| `operation.get` | `operationID` | Operation object |
| `group.create` | `name`, top-level `operationID` | Status object after creation |
| `pairing.join.begin` | request correlation ID, sponsor device ID + full public-key fingerprint, endpoint, group ID, top-level `operationID` | Pairing binding without the code until the handshake is ready |
| `pairing.join.status` | `pairingID`, `requestCorrelationID` | Pairing binding; code only in `awaiting_user` |
| `pairing.bindPeerConnection` | full `binding`, top-level `operationID` | Binding with the peer/native-request connection fields durably associated for this attempt |
| `pairing.join.confirm` | full `binding`, top-level `operationID` | Pairing binding after exact server revalidation |
| `pairing.join.cancel` | full `binding`, top-level `operationID` | Pairing binding |
| `pairing.requests.list` | none | `{requests: [PairingBinding]}` with every code and code fingerprint set to null |
| `pairing.request.review` | full list `binding`, top-level `operationID` | Pairing binding with code + fingerprint for human comparison |
| `pairing.request.approve` | full reviewed `binding`, top-level `operationID` | Pairing binding after exact server revalidation |
| `pairing.request.reject` | full reviewed `binding`, top-level `operationID` | Pairing binding |
| `update.stage.begin` | release ID, bundle SHA-256, bundle size, top-level `operationID` | `{uploadID, uploadPath, expiresAt}`; path is under the status-reported state root |
| `update.stage.verify` | `uploadID`, top-level `operationID` | `{releaseID, artifactSHA256, staged: true}` after signature/hash/state-range verification |
| `update.activate` | `releaseID`, `drainTimeoutSeconds`, top-level `operationID` | Durable update operation |
| `update.healthCommit` | `episodeID`, top-level `operationID` | Durable operation |
| `update.rollback` | `episodeID`, `reason`, top-level `operationID` | Durable operation |
| `session.create` | manager-generated `sessionID`, engine and nullable entry/title/working-directory/model/effort/access fields, top-level `operationID` | `{sessionID, globalID, title, engine}` for a new Linux-home session |
| `service.start` | top-level `operationID` | Durable operation; normally sent to the fixed offline `service-start` command |
| `service.stop` | top-level `operationID` | Durable operation; normally sent to the fixed `service-stop` command |
| `service.restart` | top-level `operationID` | Durable operation |

Admin error codes are frozen in the response schema. The human-readable
`message` is diagnostic text, not a programmatic contract. `retryable`
describes whether a later attempt may succeed; it never authorizes automatic
replay of a side effect. `uncertain` is true only when the daemon cannot prove
whether an accepted side effect completed.

### Dedicated secret stream

Secrets are not generic admin operations. The fixed `secret-stdin` command
reads one UTF-8 JSON **header line** conforming to
`secret-request.schema.json`, followed by exactly `valueByteCount` raw bytes
and end-of-stream. For `set`, the header's transport `valueSHA256` must match
those bytes; for `delete`, the byte count and hash are `0`/`null`. The CLI
forwards the unmodified stream to the daemon's separate secret socket. The
value is never placed in generic admin JSON, a process argument, a request
hash stored in the ledger, a log, or a response.

Before changing the backend, the daemon writes a durable operation receipt
whose hash binds `secret.set`/`secret.delete`, expected/actual device ID,
secret ID/kind/byte count, and an HMAC commitment keyed by a device-local
0600 receipt key. The response receipt and status report only `backend`,
`configured`, monotonically increasing `storedVersion`, the version consumers
have actually loaded as `effectiveVersion`, `pendingRestart`, and
`updatedAt`. Linux's file backend is read dynamically, so a successful set
normally makes stored and effective versions equal with
`pendingRestart: false`; a backend/consumer that caches at process start must
instead keep the old effective version and report `pendingRestart: true`
until restart. Delete increments the stored version and reports
`configured: false`. A crash between receipt intent and backend commit leaves
the operation uncertain; reconciliation reads the backend version rather than
replaying a value the manager may no longer possess.

## Pairing and group admission

Linux uses the existing Noise XX, 128-bit eight-group verification code,
fabric membership, and named-group rules. SSH trust does not admit a device to
a Converse group, and Converse group admission does not grant SSH access.

A pairing **binding** is the unit of human approval. It binds the pairing ID,
manager request-correlation ID, native request ID, Linux/requester/sponsor
device IDs and full public-key fingerprints, group ID/name,
requester and sponsor connection-instance IDs, the verification-code
fingerprint, and expiry. `pairing.bindPeerConnection` is the only operation
that may fill in a previously null native-request/peer-connection field, and
it must match every already-known stable field. Confirm, approve, reject, and
cancel send the full last-shown binding. The Linux daemon revalidates every
stable field against the **live** prompt/request, the authenticated peer
public key, both connection instances it has bound, the code fingerprint,
current group, and expiry. Any mismatch is `pairing_binding_mismatch`; a
disconnected or reconnected handshake gets new connection instances and the
stale binding is rejected, never silently rebound. State and `updatedAt` are
presentation fields and are not treated as stable identity. The full code may
be omitted from a confirm payload when its fingerprint is present; if a code
is supplied it must match exactly and may be shown only in `awaiting_user`.

The reference setup offers two explicit choices:

1. **Join this device's current group.** The manager device is the transport
   sponsor. It creates a request-correlation ID and calls
   `pairing.join.begin` with its own device ID/full fingerprint, reachable
   endpoint, and current group. Linux starts the ordinary joiner handshake.
   When the sponsor's native request appears, the manager binds its native
   request ID and sponsor connection instance to the Linux binding, reviews
   the native request, and compares all eight groups and full identities.
   Because the same human and GUI process control both endpoints, **one Pair
   click** is the approval gesture: it invokes the sponsor-side native
   approval and Linux `pairing.join.confirm` with that exact binding. The GUI
   must not auto-click, reuse a binding after reconnect, or infer either
   confirmation from SSH success.
2. **Create a new group on Linux.** The manager calls `group.create`. The GUI
   device then uses the ordinary Join Group flow toward Linux. The manager
   lists Linux's pending binding, binds the GUI requester connection instance,
   reviews it, and displays all eight groups. Again, when the same GUI
   controls the joining endpoint and the Linux reviewer channel, one Pair
   click invokes the GUI-side native confirmation and Linux
   `pairing.request.approve` with the exact binding.

If different people/devices control the endpoints, one-click manager approval
is unavailable: each endpoint confirms separately in its own UI. Pairing
codes exist only in memory and in the single admin response actively being
shown. Code fingerprints and bindings are not written to the deployment
registry, recovery ledger receipts beyond the generic request hash, logs,
crash reports, or fixtures with real values. Pairing bindings expire with the
underlying request and die on disconnect. A restart does not resurrect an
approval.

Automatic reconnect never becomes an admission. A removed Linux device cannot
self-pin over a tombstone. Readmission always requires a fresh human-approved
sponsor action at a higher membership generation, as in `docs/fabric.md` and
`docs/groups.md`.

### Display restoration after restart or rollback

For each session, the ledger stores the last authorized display owner, a
monotonic take generation, and the last execution epoch. On daemon start:

- Allocate a fresh Boot and fresh execution epochs.
- Reject every command carrying a previous Boot or execution epoch.
- A returning viewer that is still the recorded owner at the same take
  generation may be offered a **new** lease.
- Any intervening take increments the take generation and replaces the owner;
  the older viewer receives no restoration offer.
- Park, release, group removal, and dissolution clear restoration eligibility.

Tests must cover ordinary restart and rollback, each with an untouched display
and with an intervening take.

## Update, rollback, and recovery

Updates are explicit. There is no background auto-update in v1. One update or
rollback episode may be active at a time. The episode and every operation are
recorded in the frozen `recovery-ledger/v1` outside application restore sets.

An episode distinguishes **old-release draining** from **new-release
probation**. These states have different crash semantics and must never be
collapsed into one generic “updating” state.

1. **Stage.** Upload one signed bundle to a daemon-issued incoming path.
   Verify detached signature, manifest, architecture, size, and SHA-256.
   Staging does not stop work or change the current release.
2. **Activate request.** Durably record the operation and episode with phase
   `draining_old_release`, close admission to new turns and scheduled work,
   and let active work finish until `drainTimeoutSeconds`.
3. **Drain timeout.** Abort activation, reopen admission on the old release,
   and mark the episode `aborted`. Do not kill provider processes, agent runs,
   or file operations merely because the deadline expired.
4. **Switch.** After a complete drain, record `activating_new_release`,
   atomically move the current-release link, and restart under the same single
   supervisor.
5. **Probation.** The new release starts admin-listenable but fabric/work
   admission remains closed with phase `probation_new_release`. Internal
   health checks may run. No provider turn, scheduled agent run, lease, or
   external side effect is admitted.
6. **Resolve.** Only an explicit `update.healthCommit` opens admission and
   marks the episode `committed`. An explicit `update.rollback` returns to the
   recorded previous release. A failed mandatory health check remains in
   probation or proceeds to rollback only through the recorded rollback path;
   it never silently opens admission.

Crash rules are phase-specific:

- A crash or ordinary restart during an **abandoned old-release drain** may
  clear that drain, mark activation aborted, allocate fresh Boot/epochs, and
  resume the old release. The abandoned operation remains in the ledger.
- A crash during **activation** leaves admission closed until the recorded
  current/previous release choice can be proven from release links plus the
  ledger. Ambiguity is `recovery_required`, not a guess.
- A crash during **new-release probation** returns to probation with admission
  still closed. Restart alone never health-commits a probationary release.
- Rollback to an old executable still reads the newest ledger first and
  allocates counters above its floors. An old binary that cannot read the
  ledger, encounters a counter above `9007199254740992`, or finds the current
  written state outside its signed readable range fails closed with
  `recovery_required`.

### Recovery ledger ordering

The ledger is the authority floor, not a cache. Each mutation is written to a
temporary file in the ledger directory, flushed, fsynced, atomically renamed,
and followed by a directory fsync where the platform supports it.

Ordering is part of the contract:

1. Record operation intent and all preallocated counter floors durably.
2. Perform the side effect.
3. Record the terminal or next nonterminal state durably.

A crash between steps 1 and 3 leaves nonterminal evidence. On restart that
work is `uncertain` unless an authoritative reconciliation proves its result.
Restore and rollback code must preserve nonterminal evidence as well as
terminal receipts. It must never delete an accepted operation merely because
application data was restored from an older snapshot.

Before listening, startup reconciles application state against ledger floors:

- `nextBoot`, `nextHomeSeq`, lease-epoch, membership-generation, and take
  generations are at least the ledger floors, then fresh values are allocated.
- Removal tombstones and dissolved group IDs are the union of durable state;
  restored older state cannot erase them.
- Command receipts are retained by command ID. A restored pending command
  with a terminal or uncertain receipt is not executed again automatically.
- Display restoration follows the separate owner/take-generation rules above.

## Manager-local deployment registry

Each GUI keeps its own local registry of Linux deployments that it manages.
The registry is convenience and identity pinning, not group authority.
Completed deployments may contain the SSH destination alias, approved SSH
host-key fingerprint, Linux Converse device ID, group ID, install roots,
supervisor, capabilities, last-known release/status time, and the completed
installation operation/token reference. Before SSH upload, the same registry
file also holds a **provisional deployment**: operation ID, operation-owned
staging token, stage, destination, fingerprint once verified, bootstrap hash
and size, intended release, discovered device ID once known, timestamps, and
expiry. The manager updates that stage after each durable boundary and uses
the same record to query the installation receipt after an SSH/app restart.
Promotion to a completed deployment and removal of the provisional record are
one registry save. Expired provisional staging is cleaned only by its exact
token; another manager's token is never touched.

It must never contain an SSH password, passphrase, private key, provider
credential, Converse private key, pairing code, webhook secret, transcript, or
draft. Loss of the registry does not change Linux or its group membership; a
manager can rediscover status only after SSH host trust and Converse identity
checks pass again.

Several GUI devices may manage the same Linux home. The daemon's operation
and update locks are authoritative. A manager that observes another active
operation displays it and does not start a competing mutation.

## Fake-SSH fixtures and manual gates

Fixtures under `linux/contracts/fake-ssh/` freeze the automated manager's
process-boundary behavior. Each case records the exact argument array, stdin
fixture when applicable, stdout, stderr, exit code, and expected
classification. A fake `ssh` executable in manager tests may replay these
files; it must not be used to claim PTY, ConPTY, host-key prompt, OpenSSH
config, or provider-login behavior.

The contract suite covers:

- Successful strict `status.get`
- Changed host key
- Automated authentication failure
- Converse identity mismatch
- Daemon unavailable with a valid admin envelope
- Disconnect after a mutating request may have been accepted
- Dedicated secret-stdin header/raw stream with metadata-only receipt
- Offline stopped-daemon status
- Trust-only expected authentication failure as a named manual transcript
- Negative counter JSON-number and 2^53-overflow fixtures, plus an impossible
  release readable/writable state range

Manual/VM acceptance gates remain mandatory for:

- macOS PTY and Windows ConPTY first host-key approval
- `ProxyJump`, custom ports, identity files, and SSH agent configurations
- systemd user service with and without linger
- Cron `@reboot` plus periodic guarded entry, desired-running stop/start, and reboot
- Provider CLI installation and interactive login in an SSH terminal
- Crash during old-release drain and crash during new-release probation
- Stale/reconnected pairing-binding rejection and same-manager one-click Pair
- Secret rotation with stored/effective versions and pending-restart backends
- Offline status plus service start/stop while the daemon socket is absent
- Two managers bootstrapping concurrently and disconnect recovery by token
- Restart/rollback display restoration with and without an intervening take
- Interrupted accepted mutations followed by application-data restore
- Real Mac/Windows/iPad viewing and control of Linux-home sessions

## Versioning and release gate

`VERSION.json` remains the shared product version source. A new user-facing
Linux preview follows the repository's version/build rule; contract-only work
does not bump it. Linux artifacts report the product version, build, source
commit, architecture, device protocol version `1`, admin API version `1`,
state schema version, and recovery-ledger version `1` through status and the
release manifest.

No merge, installation, or release is authorized by this contract alone.
Completion requires mutual review, the maintained contract/Core/Linux tests,
and the manual VM gates above. Current-main UI work remains isolated from this
branch until the coordinated review.
