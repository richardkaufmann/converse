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
4. **No silent replay.** An accepted command or update operation whose outcome
   is unknown remains `uncertain`. A retry with the same operation ID returns
   the recorded operation; it does not execute the side effect again.
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
9. **Secrets never enter process arguments, logs, fixtures, or status.**
   Secret values travel only in an admin request body over the already trusted
   SSH/Unix-socket path. Status exposes metadata only.
10. **No shell construction from user data.** Managers invoke OpenSSH with an
    argument array. Every remote command is one of the fixed strings in this
    contract. No destination, path, name, token, or secret is interpolated
    into a local or remote shell command.

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
| Pairing binding | `bindingVersion: 1` | Transient group-join/review state shown to a human |
| Release manifest | `manifestVersion: 1` | Signed Linux release description |
| Deployment registry | `registryVersion: 1` | Manager-local record of provisioned Linux homes |
| Recovery ledger | `ledgerVersion: 1` | Linux-local authority floor excluded from restore sets |

All timestamps in the new admin/deployment artifacts are RFC 3339 UTC strings.
Device IDs are lowercase SHA-256 hex of the 32-byte X25519 public key, exactly
as in `docs/fabric.md`. SHA-256 values are lowercase hex. UUIDs use canonical
hyphenated text. JSON text is UTF-8.

## Linux filesystem and releases

The installer uses the invoking Linux user's account; v1 does not require
`sudo` and does not create a system user.

- Executable link: `~/.local/bin/converse`
- Versioned releases: `~/.local/lib/converse/releases/<releaseID>/converse`
- Configuration: `${XDG_CONFIG_HOME:-~/.config}/converse`
- Application data: `${XDG_DATA_HOME:-~/.local/share}/converse`
- State: `${XDG_STATE_HOME:-~/.local/state}/converse`
- Incoming update bundles: `<state>/incoming/`
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
- **Fallback:** one `@reboot` crontab entry that starts the same single
  instance through an atomic lock.

The installer records the chosen supervisor in status. It never installs both.
A second daemon instance must fail closed on the single-instance lock rather
than share state.

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
and SHA-256 against the manifest before staging it.

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

The trust-only process uses `RequestTTY=no`. That option controls allocation
of a remote tty; the local PTY/ConPTY is what lets the GUI see OpenSSH's own
host-key prompt and send the user's explicit answer. Authentication methods
are deliberately disabled for this process, and its fixed remote command is
`true`. The manager:

1. Shows the host-key fingerprint that OpenSSH itself presents, in full.
2. Lets the user approve or cancel. It sends an affirmative answer only after
   that click and only in response to the expected host-key prompt.
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
fixed relative target `.converse-bootstrap.bin`. Update upload uses only a
daemon-returned absolute path that is exactly
`<status.filesystem.stateRoot>/incoming/<token>.tar.gz`, where the token
matches `[A-Za-z0-9-]{32,64}`. The manager rejects relative paths, traversal,
path separators inside the token, and every other remote path.

The complete fixed remote-command allowlist for bootstrap and administration
is:

| Purpose | Exact remote command |
| --- | --- |
| Host-key trust probe | `true` |
| Acquire bootstrap lock | `mkdir "$HOME/.converse-bootstrap.lock"` |
| Bootstrap preflight | `chmod 700 "$HOME/.converse-bootstrap.bin" && exec "$HOME/.converse-bootstrap.bin" preflight` |
| Install uploaded binary | `exec "$HOME/.converse-bootstrap.bin" install-self` |
| Bootstrap cleanup after a failed attempt | `rm -f "$HOME/.converse-bootstrap.bin"; rmdir "$HOME/.converse-bootstrap.lock"` |
| Admin request | `exec "$HOME/.local/bin/converse" admin-request` |

No other remote command is generated by the manager in v1. The bootstrap lock
prevents two managers from replacing the fixed bootstrap path concurrently. A
stale lock is reported for explicit user cleanup; the manager does not force
it. `preflight` prints exactly one JSON status object conforming to the status
schema, with `runtime.processState` set to `not_installed` before installation.

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

One `converse` binary provides the daemon and local administration. The SSH
entry point is `converse admin-request`. It reads exactly one UTF-8 JSON
request line from stdin, forwards that line to the daemon's Unix socket, and
writes exactly one JSON response line to stdout. The same newline-delimited
framing is used on the Unix socket. Pretty-printed JSON, multiple objects,
trailing non-whitespace, requests over 64 KiB, and responses over 1 MiB are
rejected.

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

Mutating long-running requests carry a client-generated `operationID`. Before
any side effect, the daemon durably records the operation ID, a payload
SHA-256, and an `accepted` state in the recovery ledger. The hash input is the
payload encoded with object keys sorted ordinally at every depth, array order
preserved, strings JSON-escaped, numbers kept in their received lexical form,
and no insignificant whitespace. A retry with the same operation ID and
payload hash returns the recorded operation. The same ID with a different
payload is an `operation_conflict`.
If SSH disconnects before a valid response, the manager marks the local
attempt uncertain, reconnects, and issues `operation.get`; it never chooses a
new operation ID merely to retry.

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
| `group.create` | `name` | Status object after creation |
| `pairing.join.begin` | sponsor device ID, endpoint, group ID | Pairing binding without the code until the handshake is ready |
| `pairing.join.status` | `pairingID` | Pairing binding; code only while awaiting the Linux-side human |
| `pairing.join.confirm` | `pairingID` | Pairing binding |
| `pairing.join.cancel` | `pairingID` | Pairing binding |
| `pairing.requests.list` | none | `{requests: [PairingBinding]}` with every code set to null |
| `pairing.request.review` | `pairingID` | Pairing binding with the code for human comparison |
| `pairing.request.approve` | `pairingID` | Pairing binding |
| `pairing.request.reject` | `pairingID` | Pairing binding |
| `update.stage.begin` | release ID, bundle SHA-256, bundle size | `{uploadID, uploadPath, expiresAt}`; path is under the status-reported state root |
| `update.stage.verify` | `uploadID` | `{releaseID, artifactSHA256, staged: true}` after signature/hash verification |
| `update.activate` | `releaseID`, `drainTimeoutSeconds`, top-level `operationID` | Durable update operation |
| `update.healthCommit` | `episodeID`, top-level `operationID` | Durable operation |
| `update.rollback` | `episodeID`, `reason`, top-level `operationID` | Durable operation |
| `service.restart` | top-level `operationID` | Durable operation |
| `secret.set` | `secretID`, `kind`, `value` | Secret metadata only |
| `secret.delete` | `secretID` | Secret metadata only |

Admin error codes are frozen in the response schema. The human-readable
`message` is diagnostic text, not a programmatic contract. `retryable`
describes whether a later attempt may succeed; it never authorizes automatic
replay of a side effect. `uncertain` is true only when the daemon cannot prove
whether an accepted side effect completed.

## Pairing and group admission

Linux uses the existing Noise XX, 128-bit eight-group verification code,
fabric membership, and named-group rules. SSH trust does not admit a device to
a Converse group, and Converse group admission does not grant SSH access.

The reference setup offers two explicit choices:

1. **Join this device's current group.** The manager device is the transport
   sponsor. It calls `pairing.join.begin` with its own authenticated device ID,
   reachable endpoint, and current group ID. Linux starts the ordinary joiner
   handshake. The manager polls `pairing.join.status`, displays all eight code
   groups beside the native Group Review code, and sends
   `pairing.join.confirm` only after the user presses the Linux-side Pair.
   The user separately completes the sponsor-side Pair in the native group
   UI. Neither confirmation is inferred from SSH success.
2. **Create a new group on Linux.** The manager calls `group.create`. The GUI
   device then uses the ordinary Join Group flow toward Linux. The manager
   lists Linux's pending request, calls `pairing.request.review`, displays all
   eight groups, and approves or rejects only from an explicit user action.

Pairing codes exist only in memory and in the single admin response that is
actively being shown. They are never written to the deployment registry,
recovery ledger, logs, crash reports, or fixtures with real values. Pairing
bindings expire with the underlying request and die on disconnect. A restart
does not resurrect an approval.

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
  ledger or state schema fails closed with `recovery_required`.

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
The registry is convenience and identity pinning, not group authority. It may
contain the SSH destination alias, approved SSH host-key fingerprint, Linux
Converse device ID, group ID, install roots, supervisor, capabilities, and
last-known release/status time.

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
- Trust-only expected authentication failure as a named manual transcript

Manual/VM acceptance gates remain mandatory for:

- macOS PTY and Windows ConPTY first host-key approval
- `ProxyJump`, custom ports, identity files, and SSH agent configurations
- systemd user service with and without linger
- Cron fallback and reboot behavior
- Provider CLI installation and interactive login in an SSH terminal
- Crash during old-release drain and crash during new-release probation
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
