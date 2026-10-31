# Converse testing strategy

Converse is tested as a distributed application that runs AI sessions on Mac, Windows and Linux homes and presents them on desktop and iPad clients. The central question is whether it preserves the user's work and applies each action to the correct session, with the correct authority, even when a process stops or a connection fails.

## Layers of evidence

| Layer | What it establishes |
| --- | --- |
| Deterministic behavior checks | Parsing, settings, schedules, transcript formatting, draft handling, routing, permissions and state transitions behave as specified. |
| Provider and process fixtures | Streaming, resume identity, interruption, approvals, errors and process termination behave correctly at the CLI boundary. Codex and Claude fixtures are offline; the Mac suite also exercises the installed Muse CLI through its offline echo provider. |
| Persistence and recovery checks | Reopening stores preserves conversation state; interrupted operations remain uncertain when appropriate; completed commands are not replayed; configuration recovery and diagnostics preserve evidence. |
| Protocol and service integration | Real loopback connections exercise encrypted transport, group admission, display ownership, snapshots, acknowledgements and image transfer. Swift and C# implementations are checked against common protocol expectations and cryptographic vectors. |
| Native client checks | Mac tests exercise AppKit text and layout behavior; iPad XCTest exercises UIKit/SwiftUI-backed transcript and model behavior. Simulator interoperability tests connect an iPad client to an isolated Mac home. |
| Platform and release acceptance | Native UI inspection, real-device/VM tests, signing, packaging, version identity, installation and rollback checks cover behavior that fixtures alone cannot establish. |

## The properties we protect

- **User work survives transitions.** Draft text, attachments, queues and transcript history must survive restart, reconnect, display takeover and failed sends. Late snapshots or completions must not overwrite newer typing. A new session or reused pane must not inherit another session's history.
- **Execution remains ordered and bounded.** Stop, Inject and queue operations must preserve the intended conversation identity and avoid overlapping replacement turns. Authentication errors, transient retries and terminal failures must produce different outcomes.
- **Distributed authority remains valid.** Pairing binds approval to the compared identity and live request. Old display leases, stale snapshots, revoked trust and duplicate commands must not regain authority after reconnect or restart.
- **Messaging and agents respect their scope.** Tell is one-way; Ask requires a correlated answer. A transport acknowledgement is not an answer. Supervision must respect human pauses, avoid repeated interventions and obey update admission. Agents start with explicit scope and are checked for budget limits, scheduling, request deduplication and private-data exclusion from public responses.
- **Recovery does not replay side effects.** Linux tests cover operation receipts, secret-operation evidence, update drain and probation, and recovery-ledger invariants. Configuration diagnostics have tests for removal evidence, previous/latest snapshots, privacy, permissions, rotation and failure without blocking the primary archive save.

Tests use disposable data folders, synthetic identities, local peers and injectable service responses. Live provider requests and production profiles are not required for the normal regression suites. Native UI QA uses a separate app/data setup; it must not be launched against the user's working archive.

## Repeatable checks

```sh
# Mac: build current source before testing. test.sh reuses an existing bundle.
CONVERSE_APP_OUTPUT=/tmp/converse-qa/Converse.app ./build.sh
CONVERSE_APP_OUTPUT=/tmp/converse-qa/Converse.app ./test.sh

# iPad: include the Mac-home integration tests, not just simulator-only checks.
CONVERSE_APP_OUTPUT=/tmp/converse-qa/Converse.app ./iPad/test.sh --interop

# Linux contracts, runtime, pairing helper and shared Windows/Linux core.
./linux/test.sh

# On Windows: shared core plus native WinUI compilation.
dotnet run --project windows/src/Converse.Core.Tests -c Release
dotnet build windows/src/Converse.Windows -c Release -p:Platform=x64
```

The Mac suite requires the installed Muse CLI, a macOS GUI environment for its full checks, and the Apple build tools. iPad tests require Xcode and an available simulator. Linux/core checks require .NET 8 and Python 3. Without `--interop`, the three iPad tests requiring a Mac home are skipped rather than evidence of interoperability.

GitHub Actions currently runs Linux contracts/runtime/shared-core checks on Ubuntu and shared-core checks plus a WinUI build on Windows. Apple tests are run locally; there is no checked-in Mac or iPad CI workflow. The shared core running on a Mac is useful evidence but does not replace its native Windows run or a WinUI build.

## Regression and release discipline

A bug report should become a reproducible scenario and, where practical, a maintained test that fails before the correction and passes afterward. Check meaningful outcomes: the exact retained draft, the absence of a replay, the rejected stale binding, or the version actually running. A successful process exit or a staged package is not sufficient evidence of the user-visible result.

For each candidate, record the source commit, version/build, environment, commands, failures and skipped checks. Distinguish automated test success, manual acceptance, staged installation and verified running installation. Mac distribution additionally checks Developer ID signing, hardened runtime, both CPU architectures, notarization, stapling and Gatekeeper. Local updates wait for normal quit, retain the previous app and verify the Dock target. Signing and notarization establish package identity and distribution acceptance, not application correctness.

## Remaining gaps

The corpus is strongest in state transitions, protocols and recovery. It is not a complete end-to-end or compatibility certification:

- Expand repeatable UI coverage for narrow panes, overflow menus, long setup forms, tooltips, focus, accessibility and touch/keyboard behavior, particularly in WinUI.
- Maintain a real-device matrix across Mac, Windows, Linux and iPad, including background/foreground, sleep/wake, network loss and viewer takeover. Simulator and loopback tests do not reproduce every network or OS lifecycle condition.
- Complete and retain evidence for the Linux manual gates: real OpenSSH PTY/ConPTY trust prompts and ProxyJump, service supervisors and reboot, provider login, concurrent bootstrap, and crash/rollback recovery. Fake SSH results cannot satisfy these gates.
- Add measured streaming-latency, long-transcript, large-attachment and soak tests. Functional correctness checks do not establish responsiveness or bounded long-running resource use.
- Broaden platform coverage. Universal Mac compilation does not prove Intel execution or every supported macOS version. Model/CLI updates also need periodic, separately identified live compatibility smoke tests.
- Improve timing-test determinism and repeated-run evidence where concurrency depends on wall-clock waits. A retry that passes must not silently erase an earlier failure.

No line- or branch-coverage percentage is claimed here. Assertion counts are useful inventory, but they are not equivalent to independent test cases or a measure of completeness. In particular, the original incident that removed agent configurations has not been reproduced; the new regression checks and production diagnostics improve detection and recovery without proving that original cause resolved.
