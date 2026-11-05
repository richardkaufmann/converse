# Converse Setup Preview

The isolated Mac preview validated onboarding in build82. The same onboarding and teaching flow ships in the normal Mac app starting with **0.5.58 (83)**. Windows has an isolated build84 preview described in [Windows onboarding preview](WINDOWS-NUX-PREVIEW.md). Mobile onboarding has not been ported. This separate preview remains available for testing without touching production data.

Build with:

```sh
CONVERSE_NUX_PREVIEW=1 CONVERSE_APP_OUTPUT="/tmp/converse-nux82/Converse Setup Preview.app" ./build.sh
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
2. Check the clickable README, Security and privacy, Discord, and Connect the Meta Muse iPhone app links. Before login these open the relevant Help articles; after login the mobile link opens Jolly.
3. Pick 1 Meta Muse, 2 Claude, or 3 Codex (buttons or number keys).
4. Complete the provider-owned login in Terminal/browser. The app checks a short
   model response automatically. The first model request may consume provider
   quota. If login fails or is cancelled, the gate remains; select again to retry.
   The manual Check connection action covers a login completed outside this flow.
5. In build84, App Support becomes a native agent using the verified provider, with a daily repository-health loop, no watched sessions and no mood art. Pause the loop in Agent Setup at any time. Successful onboarding enables and teaches both app setup/control and the
   switchboard, using the same instructions as the manual teaching menu.
   Both capabilities persist after restart. Login checks and teaching are hidden
   from the display before the welcome reply. Once connected, ask support to create an agent with an objective, then inspect
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

Operations: inspect, help, open, create-parking-lot, create-agent, configure-agent, show-session.
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

## Clear the Mac conversation display

Type `/clear` to hide existing messages without resetting the provider session,
teaching, pending work or attachments. New replies remain visible. Type
`/unclear` to restore the hidden history. The display boundary survives restart;
exports and model context retain the complete transcript. Onboarding uses the
same display operation after injecting both teaching prompts, so the user sees
the support welcome and links instead of setup machinery.
