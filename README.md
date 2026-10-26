<p align="center">
  <img src="docs/converse-icon.png" width="160" alt="Converse high-top tennis shoe icon">
</p>

# Converse

A native Mac home for Muse, Claude Code, and Codex: the immediacy of a shell with a normal, selectable Mac text window. And a tennis shoe, because **Converse**.

## Use

Click **+** next to an assistant to start a session. Settings (**⌘,**) configures its name, command line, working directory, and adapter. Each entry can have multiple independent conversations.

- **Return** sends. **⌘Return** inserts a newline; Shift-Return also works.
- Your draft is **blue**. Submitted input becomes *italic* in the default color, enclosed by subtle separator rules.
- Output is plain text, with clickable links. Successful tool chatter is hidden; the assistant's answer remains visible. Tool failures remain visible, and Muse's workspace root/trust diagnostics are hidden.
- Gaps of ten seconds or more before answer text get grey markers such as `[10 sec]` or `[10.5 minutes]`. Timing starts at Send, then follows visible answer text; hidden tool events do not reset it.
- Paste screenshots with **⌘V**, or attach images with the paperclip. Attachments are saved as PNG files and supplied to the assistant.
- The **line numbers** checkbox controls a narrow logical-line gutter. It defaults on and remembers your choice.
- Input stays at the bottom; the window follows typing. Older text stays selectable and protected from edits.

**File → New Window** (**⌘N**) opens another two-pane window. Selecting a session already visible in another window brings that window forward. Closing a window leaves active work running. Quit warns about active commands.

Conversations, drafts, and attachments survive relaunches. Bold assistant names indicate that sessions exist; green dots indicate active work.

A compact bottom status line shows the current state, model, reasoning effort, access setting, and last-turn input/output token counts. Values come from structured CLI events or explicit command flags. Unreported values are labeled honestly as `not reported` or `CLI default`; token usage is not remaining account quota. Status values persist with the conversation and refresh on new turns.

The Mac's local time zone and send time are supplied as context to the assistant, and the child process receives the matching `TZ`. Local time is preferred unless another time zone is requested.

## Build and run

This preview is built and tested on an Apple Silicon Mac using Apple's Command Line Tools and the installed macOS SDK. No third-party libraries or Xcode project are required.

```sh
./build.sh
open Converse.app
```

The build generates the sneaker artwork, creates `Converse.app`, and applies a local ad-hoc signature. Generated app and icon bundles are excluded from Git; their source is included.

Install and authenticate the assistant CLIs separately. Configure each entry with the matching adapter; Converse appends that adapter's headless-mode flags. Command lines run through your login shell. Homebrew and `~/.local/bin` are included in the executable search path.

## Check

With Muse installed:

```sh
./test.sh
```

The checks use isolated temporary data and Muse's offline echo provider. They cover real Muse execution and session resumption, prompt quoting, persistence, image creation, text editing and styling, Command-Return, input blocks, output cleanup, elapsed-time markers, clickable links, and Claude/Codex protocol fixtures. Claude and Codex checks do not make paid requests.

## How it works

- **Muse:** `muse exec --json --session-id`, retaining the same session ID across turns.
- **Claude:** print mode with streaming JSON, resuming its exact session ID.
- **Codex:** `codex exec --json`, resuming the returned thread ID.

Each turn launches a headless process. The CLI's own session store retains model context; Converse retains the visible transcript and draft. There is no idle terminal process. The interface uses AppKit's native text system, with a SwiftUI sidebar and controls.

## Data

Local data lives in `~/Library/Application Support/Converse/`:

- `sessions.json`: assistant settings, transcripts, drafts, attachment paths, and saved delay markers.
- `Attachments/`: persistent image files, so saved screenshots remain available after temporary files are cleared.

The app uses the installed CLIs' authentication and permission configuration. Credentials, transcripts, and personal settings are not part of this repository.

## Preview limitations

Interactive terminal approval menus, login flows, slash-command menus, and tool-driven question dialogs are not implemented. Authenticate through the CLI first. Headless permission errors appear in the transcript; Converse adds no approval or sandbox bypass flags. Some tools provide their response only at turn completion.

The current app is macOS-only. An iPad client and remote session service are future work.

See [README.txt](README.txt) for additional usage notes. App and adapter implementation is in [Sources/main.swift](Sources/main.swift); the vector-drawn sneaker icon is generated by [Sources/Icon.swift](Sources/Icon.swift).
