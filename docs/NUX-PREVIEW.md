# Converse Setup Preview

This is a Mac-only build81 prototype, not a production update or a TestFlight release.

Build with:

```sh
CONVERSE_NUX_PREVIEW=1 CONVERSE_APP_OUTPUT="/tmp/converse-nux81/Converse Setup Preview.app" ./build.sh
```

The signed bundle has ID `local.richard.Converse.NUXPreview` and an embedded
`ConverseNUXPreview` flag. Opening it from Finder sets its data root to
`~/Library/Application Support/Converse Setup Preview` before loading any store.
Preferences and Keychain services are separate. It creates a new device identity,
uses an ephemeral network port, and does not inherit production pairing/trust.
Provider profiles live in `SupportAccounts` under that root. The Muse launcher
uses a separate auth path and XDG directories. Provider executables remain the
installed executables; no CLI installation is replaced by this preview.

## Walkthrough

1. Open **Converse Setup Preview**. Only Converse App Support is shown.
2. Check the clickable README, Discord, and Connect the Meta Muse iPhone app links. Before login these open the relevant Help articles; after login the mobile link opens Jolly.
3. Pick 1 Meta Muse, 2 Claude, or 3 Codex (buttons or number keys).
4. Complete the provider-owned login in Terminal/browser. The app checks a short
   model response automatically. The first model request may consume provider
   quota. If login fails or is cancelled, the gate remains; select again to retry.
   The manual Check connection action covers a login completed outside this flow.
5. Once connected, ask support to create an agent with an objective, then inspect
   it in Agent Setup. It starts paused. Ask for Discord or the Meta Muse iPhone
   connector; provide secrets only in native secure fields, never chat.
6. Quit and reopen the preview: its support session and teaching remain, without
   recreating the welcome session or rearranging the normal app.

The model cannot run before login. Converse starts native authentication itself;
it does not pretend a model is guiding an unauthenticated provider. Missing CLIs
link to the provider's installation instructions, then the same choice retries.

## Command boundary

App control is a separate, explicit session capability. Ordinary sessions use
one complete `converse` fenced final reply with `command: app-control`. Native
agents use the optional `appControl` object in their existing reply JSON.
Only successful final responses are processed; Codex uses its authoritative
final-answer file. Quotes, partial output, and bare JSON never execute.

Operations: inspect, help, open, create-agent, configure-agent, show-session.
No arbitrary shell/paths, credential reads, deletion, auto-updates, or scheduled
loop activation are exposed. Background/forwarded requests cannot invoke these
commands. A human request can continue for at most eight app operations before
requiring another user turn. Results are persisted and report saved vs tested.

## Validation

The full Mac gate includes capability checks, strict command parsing, invalid
configuration rollback, duplicate creation handling, restart persistence,
authentication failure and final-response gating, and a complete local fixture
journey through provider selection, native login completion, CLI response parsing,
and support handoff. The fixture uses no external account/model. A human login
walkthrough remains necessary to validate the installed provider's real OAuth UX.
