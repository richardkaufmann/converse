# Windows onboarding preview

Build 84 adds a separate **Converse Setup Preview** for a human login walkthrough.
Build with `dotnet build windows/src/Converse.Windows -c Release -p:Platform=ARM64 -p:RuntimeIdentifier=win-arm64 -p:ConverseSetupPreview=true -o <separate-output-folder>`.

The compile-time preview flag selects `%LOCALAPPDATA%\Converse Setup Preview`,
a separate app-instance mutex, separate Credential Manager resource, separate
provider account stores and a new device identity. The listener uses loopback and
an ephemeral port; discovery is disabled. It does not replace production or its
shortcut. Use the installed provider CLIs; their native login opens a console or
browser. Do not copy production tokens into the preview.

The welcome links work before authentication. Pick Muse, Claude or Codex. A
successful login exit is insufficient: a completed model response must pass the
connection check. Cancellation, missing CLI, nonzero exit, wrong reply and timeout
leave the gate closed. On success the same selected login powers App Support;
both switchboard and app-control teaching are injected and cleared from view.
The new agent watches `richardkaufmann/converse` every 1,440 minutes while the app
is open, with mood art and watched sessions off. It reports bugs and release
availability; it does not silently update software. Its loop can be paused.

Agent Setup offers provider/account/model choices; catalog queries do not send
conversation history. CLI agents use host-supplied evidence in fresh bounded
requests. Meta-hosted research, image generation and voice are separate features.
Windows does not implement local Discord/Jolly or voice; use a Mac home for them.
Keys are masked in native password fields and saved to Credential Manager.
See the README's Security and privacy section for storage and sharing limits.

App control supports inspect/help, open a known page, create a paused agent,
configure objective/repository, and show a local session. It rejects autonomous
and forwarded configuration attempts and bounds continuation chains. `/clear`
hides history without deleting it; `/unclear` restores it.

`dotnet run --project windows/src/Converse.Core.Tests -c Release -- --support-only`
runs deterministic onboarding and permission-boundary checks without accounts.
The real provider OAuth flow still needs a human walkthrough. Keep native smoke
results separate from fixture tests and from production installation evidence.

## Build 84 verification

The full Mac regression suite and Windows core suite passed. The isolated
Windows ARM64 preview compiles with zero warnings/errors; mobile simulator
builds compile the shared model picker and security Help link. Fixture coverage
includes failed/cancelled authentication, authoritative response gating, provider
account binding, daily defaults, preserving a paused loop, and app-control
permissions. The Mac fixture also completes the first taught agent turn using
the selected CLI provider. No real provider login or paid model request is part
of these fixture checks.

Windows native login, secure-field paste appearance and Quit still need a human
walkthrough. Generated Help is copied from the Mac build because the Windows
build host lacks Git/Python on its service PATH. Production is not replaced by
the preview.
