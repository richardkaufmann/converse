<p align="center">
  <img src="docs/converse-icon.png" width="160" alt="Converse high-top tennis shoe icon">
</p>

# Converse

A native Mac home for Muse, Claude Code, and Codex: the immediacy of a shell with a normal, selectable Mac text window. And a tennis shoe, because **Converse**.

## Use

Click **+** next to an assistant to start a session. Settings (**⌘,**) configures its name, command line, working directory, and adapter. Each entry can have multiple independent conversations.

- **Return** sends. **⌘Return** inserts a newline; Shift-Return also works.
- Your draft is **blue**. Submitted input becomes *italic* in the default system text color, enclosed by subtle separator rules. The app follows macOS light/dark appearance.
- Assistant Markdown renders natively: headings, bold/italic text, lists, inline and fenced code, block quotes, clickable links, and pipe tables. Successful tool chatter is hidden; the assistant's answer remains visible. Tool failures remain visible, and Muse's workspace root/trust diagnostics are hidden.
- Gaps of ten seconds or more before answer text get grey markers such as `[10 sec]` or `[10.5 minutes]`. Timing starts at Send, then follows visible answer text; hidden tool events do not reset it.
- Right-click in the transcript for **Copy this prompt** or **Copy this response**, using the exchange under the pointer. Rich-text targets receive formatted text (RTF/HTML), including tables and links; plain-text targets receive the original Markdown. Copies omit delay markers.
- Paste screenshots with **⌘V**, or attach images with the paperclip. Attachments are saved as PNG files and supplied to the assistant.
- The **line numbers** checkbox controls a narrow logical-line gutter. It defaults on and remembers your choice.
- Input stays at the bottom; the window follows typing. Click blank space below the transcript to focus the input line. The editable document fills the window, including tall windows. Older text stays selectable and protected from edits.

Right-click a conversation in the sidebar for **Configure**, **Show Window**, **Close Window**, or **Delete Conversation**. Configure is a compact dialog for its name, command, and directory; it is disabled while work runs. Assistant headers have their own Configure and New Session actions. Closing keeps the session alive. Deleting stops active work, removes the conversation from the sidebar, and keeps the window open, selecting another conversation when available. It keeps a recovery snapshot; **File → Restore Deleted Conversation** restores its transcript and draft. Attachment files are retained for recovery.

**File → New Window** (**⌘N**) opens another two-pane window. Selecting a session already visible in another window brings that window forward. Closing a window leaves active work running. Quit warns about active commands.

Conversations, drafts, and attachments survive relaunches. Bold assistant names indicate that sessions exist; green dots indicate active work.

A compact bottom status line shows the current state, model, reasoning effort, access setting, and last-turn input/output token counts. Opening a Muse session queries `muse serve` through read-only `session/read` and `usage/read` calls. No turn is submitted and the session is not resumed or attached. The app combines retained session metadata and the session log with saved settings: the model and access profile are session-derived, while a saved effort without a retained override is explicitly labeled `(config)`. The log supplies last-turn and cumulative session token counts across relaunches. The refresh button queries again. Click the model, effort or access value to choose a session-scoped setting from Muse's catalog. Existing sessions use Muse's durable setters; new conversations retain choices for their first turn. Controls are disabled during active work or a setting change. Global settings and other conversations are unchanged. Values persist and also refresh after turns. For subscription quota, Converse also runs the installed CLI's `/usage` command in an invisible, ephemeral terminal (`--no-session-log`), with no model prompt. This retrieves current-window and weekly percentages and reset times. It refreshes on open (cached for five minutes), `/usage`, or the refresh button. The displayed timestamp identifies the CLI observation when available, otherwise the query time. Failures are shown explicitly; token counts are never presented as remaining quota.

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

Muse queries run automatically when a conversation is opened. Read-only metadata commands do not change model, permissions or effort. `/usage` additionally invokes the built-in CLI usage view to fetch subscription quota; it never submits a model request. The status pickers, by contrast, explicitly update the selected conversation's model, effort or access profile. Claude and Codex local commands show the metadata captured from their streams; live read-only probing is currently Muse-specific. These commands do not implement the full CLI slash-command menus. Unrecognized commands remain ordinary prompts.

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

The checks use isolated temporary data and Muse's offline echo provider. They cover real Muse execution and session resumption, prompt quoting, persistence, image creation and image-only clipboard paste validation, interactive Muse completion and approval/question round trips, text editing and styling, Command-Return, input blocks, output cleanup, elapsed-time markers, clickable links, and Claude/Codex protocol fixtures. Claude and Codex checks do not make paid requests.

## How it works

- **Muse:** `muse serve` over bidirectional JSON-RPC (MSP), resuming the retained session and using `turn/start`. Approval requests and questions are displayed above the transcript; decisions and answers go back on the same connection.
- **Claude:** print mode with streaming JSON, resuming its exact session ID.
- **Codex:** `codex exec --json`, resuming the returned thread ID.

Each Muse turn opens an interactive host, which closes after the authoritative `turn/completed` event; Claude and Codex launch headless processes. The CLI's own session store retains model context; Converse retains the visible transcript and draft. There is no idle terminal process. The interface uses AppKit's native text system, with a SwiftUI sidebar and controls.

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
