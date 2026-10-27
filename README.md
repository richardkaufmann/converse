<p align="center">
  <img src="docs/converse-icon.png" width="160" alt="Converse high-top tennis shoe icon">
</p>

# Converse

A native Mac home for Muse, Claude Code, and Codex: the immediacy of a shell with a normal, selectable Mac text window. And a tennis shoe, because **Converse**.

## Use

Click **+** next to an assistant to start a session. Settings (**⌘,**) configures its name, command line, working directory, and adapter. Each entry can have multiple independent conversations.

- **Return** sends, or queues the draft while a turn is active. Queue rows have **Inject now** to interrupt and send that message next. **Inject all** interrupts and sends the entire queue together in order, preserving attachments and the current draft. Escape has no send or interrupt binding. **⌘Return** inserts a newline; Shift-Return also works. These keys have the same meaning for all assistants.
- Queued messages appear above the transcript, with Pause/Resume, Edit, and Clear controls. Stop pauses the queue; failures pause it too. Queued text and attachments survive relaunch, paused until you resume. You can keep editing a separate draft while the queue runs.
- Your draft is **blue**. Submitted input becomes *italic* in the default system text color, enclosed by subtle separator rules. The app follows macOS light/dark appearance.
- Assistant Markdown renders natively: headings, bold/italic text, lists, inline and fenced code, block quotes, clickable links, and pipe tables. Successful tool chatter is hidden; the assistant's answer remains visible. Tool failures remain visible, and Muse's workspace root/trust diagnostics are hidden.
- Gaps of ten seconds or more before answer text get grey markers such as `[10 sec]` or `[10.5 minutes]`. Timing starts at Send, then follows visible answer text; hidden tool events do not reset it.
- Right-click in the transcript for **Copy this prompt** or **Copy this response**, using the exchange under the pointer. Rich-text targets receive formatted text (RTF/HTML), including tables and links; plain-text targets receive the original Markdown. Copies omit delay markers.
- Paste screenshots with **⌘V**, or attach images with the paperclip. Attachments are saved as PNG files and supplied to the assistant.
- The **line numbers** checkbox controls a narrow logical-line gutter. It defaults on and remembers your choice.
- Input stays at the bottom; the window follows typing. Click blank space below the transcript to focus the input line. The editable document fills the window, including tall windows. Older text stays selectable and protected from edits.

The sidebar gutter can be dragged down to 200 points wide. Below 360 points, the model column and its header disappear; narrowing further truncates conversation titles with an ellipsis while keeping the activity indicator and P/1/2/3/X buttons visible. The full model and title remain in row hover details.

Each sidebar row shows a spinning rainbow beachball while the assistant is working (blank when idle or waiting for you), the conversation title, its model, and **P 1 2 3 X**. Hover over the row for account email, profile, model, effort, access, state, current window/pane, usage, quota, directory, queued input, draft/attachment counts and session IDs. Identity comes from the account's CLI: Codex account metadata, Claude initialization/auth status, or Muse's non-secret auth identity fields. The observation time is included; missing identity and probe failures are stated explicitly. Hover refreshes stale metadata without submitting a model prompt.

- **P** parks the conversation: no right pane displays it, and active work continues.
- **1 / 2 / 3** move it into that pane in this window. Each pane holds one conversation; its previous occupant is parked. Moving from another window vacates the original pane immediately.
- **X** asks before closing the conversation, stopping active work and removing it from every sidebar. A recovery snapshot retains transcript, draft and attachments; **File → Restore Closed Conversation** restores it. Closing a conversation leaves the window open and its pane empty.

The selected P/1/2/3 button has a green background and white text. Other buttons have white backgrounds, black text and faint borders. X turns dark red while its confirmation is open. A conversation displayed elsewhere shows P in this window; hover gives its exact location, and its context menu can bring the owning window forward. P always parks it globally.

**File → New Window** (**⌘N**) opens a separate window with the same complete sidebar and up to three independently resizable panes on the right. Empty slots take no space; a numbered header identifies each visible pane. New windows start empty. Right-click the window name in the title bar to rename it; the **Window** menu uses these names to bring windows forward. Names are unique among open windows. Closing a window parks all its conversations and leaves their work running. Quit warns about active commands. Pane assignments belong to open windows; after relaunch, choose 1, 2 or 3 to display saved conversations again.

Right-click a conversation for Configure, pane moves, Park, Show in its owning window, or Close. Configure is disabled while work runs. Assistant headers retain Configure and New Session actions. Conversations, drafts, attachments and last-observed account identities survive relaunches. Bold assistant names indicate that conversations exist.

A compact bottom status line shows the current state, model, reasoning effort, access setting, and last-turn input/output token counts. Opening a Muse session queries `muse serve` through read-only `session/read` and `usage/read` calls. No turn is submitted and the session is not resumed or attached. The app combines retained session metadata and the session log with saved settings: the model and access profile are session-derived, while a saved effort without a retained override is explicitly labeled `(config)`. The log supplies last-turn and cumulative session token counts across relaunches. The refresh button queries again. Model, effort and access dropdowns work for all three assistants. Codex queries its app server for its catalog, effective configuration and retained thread metadata; Claude uses its prompt-free SDK initialization catalog and retained transcript. Effort menus use the selected model’s reported supported levels. Custom model IDs and effort levels are also available; the CLI validates custom choices. Click the model, effort or access value to choose a conversation setting. Existing sessions use Muse's durable setters; new conversations retain choices for their first turn. Controls are disabled during active work or a setting change. Global settings and other conversations are unchanged. Values persist and also refresh after turns. For subscription quota, Converse also runs the installed CLI's `/usage` command in an invisible, ephemeral terminal (`--no-session-log`), with no model prompt. This retrieves current-window and weekly percentages and reset times. It refreshes on open (cached for five minutes), `/usage`, or the refresh button. The displayed timestamp identifies the CLI observation when available, otherwise the query time. Failures are shown explicitly; token counts are never presented as remaining quota.

The Mac's local time zone and send time are supplied as context to the assistant, and the child process receives the matching `TZ`. Local time is preferred unless another time zone is requested.

## Local slash commands

These are handled by Converse without sending a prompt or spending model tokens:

| Command | Behavior |
| --- | --- |
| `/model`, `/models` | Read model, effort, access and their sources |
| `/usage` | Read last-turn and session-total token usage, plus any observed account quota |
| `/status` | Refresh and display all session details |
| `/stop` | Interrupt the current turn |
| `/help` | Show local command help |

Muse queries run automatically when a conversation is opened. Read-only metadata commands do not change model, permissions or effort. `/usage` additionally invokes the built-in CLI usage view to fetch subscription quota; it never submits a model request. The status pickers, by contrast, explicitly update the selected conversation's model, effort or access profile. Muse uses its durable setters. Codex and Claude save per-conversation overrides and pass them on each subsequent turn, including resumed turns. CLI defaults are labeled when the CLI does not report a resolved effort. Claude and Codex also refresh their model catalogs and account/session metadata without submitting a model prompt. These commands do not implement the full CLI slash-command menus. Unrecognized commands remain ordinary prompts.

## Accounts

Settings → Accounts manages named CLI accounts and their configuration directories. The bottom account menu selects one for a fresh conversation. On an existing conversation, choosing another account opens a new conversation under that account and transfers the unsent draft and attachments; the original history and remote session stay tied to the original account. Sidebar rows show their account labels. Closing windows keeps all accounts’ active work alive.

On this Mac, Sam and AltSam reuse `~/.codex` and `~/.codex-samclone`; Muse uses its existing CLI login. Claude uses its existing CLI store, and AltClaude gets a separate store under Converse’s data directory. Claude desktop profiles (including `ClaudeAlt`) do not supply Claude Code authentication. Use **Sign in…** for each Claude CLI account once, choosing the matching account in the browser. The action opens the official CLI login in Terminal. Return to Converse and refresh; no credentials are stored in the repository or in `sessions.json`.

Additional Codex and Claude accounts can be added, renamed, or pointed at existing CLI stores. New conversations take a snapshot of the account path. Changes in Settings leave existing conversations on their original paths. Account-directory overrides are applied after shell startup, and inherited API/OAuth token environment overrides are removed for explicitly selected accounts so they cannot silently use another account. The CLIs retain responsibility for authentication, keychain storage and permissions.

## Build and run

This preview is built and tested on an Apple Silicon Mac using Apple's Command Line Tools and the installed macOS SDK. No third-party libraries or Xcode project are required.

```sh
./build.sh
open Converse.app
```

The build generates the sneaker artwork, creates `Converse.app`, and applies a local ad-hoc signature. Generated app and icon bundles are excluded from Git; their source is included.

Install and authenticate the assistant CLIs separately. Configure each entry with the matching adapter; Converse uses Muse’s interactive MSP host and the other adapters’ headless modes. Command lines run through your login shell. Homebrew and `~/.local/bin` are included in the executable search path.

## Check

With Muse installed:

```sh
./test.sh
```

For provider-only checks without a macOS GUI session, use `./test.sh --providers-only`. They validate shared multi-window placement, displacement/parking, window naming/closing, hover identity and persistence, catalogs, setting arguments, all three interruption paths, exact resumption, queue ordering and recovery, failure handling, account environment separation, and archive compatibility using offline peers. A live read-only smoke query is available with `Converse.app/Contents/MacOS/Converse --probe-provider-status codex /path/to/codex-home` (or `claude /path/to/claude-config`). Neither submits a model prompt. If iconutil is unavailable in the build environment, `CONVERSE_SKIP_ICON_BUILD=1 ./build.sh` reuses an existing icon bundle.

The checks use isolated temporary data and Muse's offline echo provider. They cover real Muse execution and session resumption, prompt quoting, persistence, image creation and image-only clipboard paste validation, interactive Muse completion and approval/question round trips, text editing and styling, Command-Return, input blocks, output cleanup, elapsed-time markers, clickable links, and Claude/Codex protocol fixtures. Claude and Codex checks do not make paid requests.

## How it works

- **Muse:** `muse serve` over bidirectional JSON-RPC (MSP), resuming the retained session and using `turn/start`. Approval requests and questions are displayed above the transcript; decisions and answers go back on the same connection.
- **Claude:** print mode with streaming JSON, resuming its exact session ID.
- **Codex:** `codex exec --json`, resuming the returned thread ID.

Each Muse turn opens an interactive host, which closes after the authoritative `turn/completed` event; Claude and Codex launch headless processes. Muse interruption uses `turn/interrupt`. Claude and Codex receive SIGINT, with SIGTERM after five seconds if needed; Converse waits for the old process and output stream to close before resuming the exact conversation with the replacement draft. It never starts a replacement concurrently with the interrupted turn. This gives consistent interruption behavior without depending on each CLI’s terminal key bindings. The CLI's own session store retains model context; Converse retains the visible transcript and draft. There is no idle terminal process. The interface uses AppKit's native text system, with a SwiftUI sidebar and controls.

## Data

Local data lives in `~/Library/Application Support/Converse/`:

- `sessions.json`: assistant settings, transcripts, drafts, attachment paths, and saved delay markers.
- `Attachments/`: persistent image files, so saved screenshots remain available after temporary files are cleared.

The app uses the installed CLIs' authentication and permission configuration. Credentials, transcripts, and personal settings are not part of this repository.

## Preview limitations

Muse approval and question dialogs are supported. Approval buttons use the server’s exact labels, choice IDs, scope, and current requirement token. Questions support single choices, multiple choices, free text, and cancellation. Requests stay visible until Muse settles them; errors and stale decisions are shown and refreshed. Auto-review policy may resolve an action without asking you. The status line distinguishes approval waits, automatic review, retries, foreground completion with background checks, and terminal completion; waiting on your input shows no working spinner. Closing a window keeps the host alive.

Claude and Codex still use headless adapters and do not yet support interactive approval/question dialogs. Login and full CLI slash-command menus are not implemented. Authenticate through the CLI first. Converse adds no approval or sandbox bypass flags. Some tools provide their response only at turn completion.

The current app is macOS-only. An iPad client and remote session service are future work.

See [README.txt](README.txt) for additional usage notes. App and adapter implementation is in [Sources/main.swift](Sources/main.swift); the vector-drawn sneaker icon is generated by [Sources/Icon.swift](Sources/Icon.swift).

Read-only Muse status probing and retained usage aggregation are implemented in [Sources/MuseStatus.swift](Sources/MuseStatus.swift). The status probe has an eight-second timeout and exposes failures rather than fabricating values. The CLI quota bridge is in [Sources/MuseQuota.swift](Sources/MuseQuota.swift), has a fifteen-second timeout, and keeps terminal escape sequences out of the UI.

The interactive Muse transport and request controls are in [Sources/MuseConnection.swift](Sources/MuseConnection.swift). Its wire shapes are checked against the installed CLI’s offline `muse schema generate-ts` export. `Tests/msp_fixture.py` checks the bidirectional approval/question exchange without model requests. Pasted images are saved as PNG; Muse receives both image content and the filename, while Claude/Codex receive the attachment paths through their adapters.

Provider protocol references: [Codex app server](https://learn.chatgpt.com/docs/app-server) documents catalog and retained thread reads; [Claude Code environment variables](https://code.claude.com/docs/en/env-vars) documents separate `CLAUDE_CONFIG_DIR` stores. Installed CLI help and locally exported Codex schemas are the authority for accepted launch arguments. Provider fixtures reject any status query that attempts to resume a session or submit a prompt.

## Session switchboard

Right-click a conversation and choose **Teach Session To Talk To Other Sessions**. Converse queues an instruction prompt that teaches the assistant to interpret user requests such as “tell Reviewer to check the tests.” It discovers current names and IDs by emitting exactly one complete `converse` fenced JSON reply: `{"command":"list-sessions"}`. Converse queues a live JSON directory response to that session. No static directory is taught.

To deliver, the assistant emits `{"command":"tell","to":"SESSION-UUID","text":"message"}` in the same fence. `tell` queues behind existing work, starts when idle, and respects a paused queue. `tell-urgently` interrupts and delivers next, resuming a paused queue. Drafts and attachments stay intact. Parked sessions receive messages without changing pane placement. Both transcripts show sender, recipient and delivery ID; queued means accepted, not read or answered. No extra acknowledgment turn is generated.

Only successful, completed assistant turns from enabled sessions execute commands. Partial streams, tool output, prose examples and failed/interrupted replies do not. IDs are recorded with pending delivery before provider execution; restored queues remain paused. Self-messages, missing recipients and messages over 32 KB are rejected visibly. Automatic chains stop after eight hops, including directory responses. Normal human input starts a fresh chain. The context menu also offers **Disable session messaging**. Teaching and disabling affect the sender; recipients can receive ordinary labeled input without being taught to send.
