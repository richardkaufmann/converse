# Development reference

Start with the [user guide](../README.md) to understand the app before building it.

## Build and run

This preview is built and tested on an Apple Silicon Mac using Apple's Command Line Tools and the installed macOS SDK, targeting macOS 14. No third-party libraries or Xcode project are required.

```sh
./build.sh
open .build/Converse.app
```

`./release.sh` builds both CPU architectures, signs with Developer ID, notarizes with Apple, staples the ticket, checks Gatekeeper, and packages the downloadable ZIP under `.build/release/`. It requires a valid **Developer ID Application** identity and a Keychain notarization profile named `ConverseNotary` (override with `CONVERSE_NOTARY_PROFILE`). See [signed releases](../docs/signed-releases.md) for the one-time setup and release checks. A local ad-hoc build cannot pass the release gates.

**Building or publishing does not update an installed copy.** Run `./install.sh` to install the verified build into `~/Applications/Converse.app`, or pass the exact app path you normally launch: `./install.sh /path/to/Converse.app`. For an installation outside protected folders, if that copy is running, installation waits for it to quit, retains the previous bundle as a backup, and replaces the app at that same path. Running copies inside Documents, Desktop or Downloads cannot be reliably updated by the background helper because macOS gives it a different privacy identity; the installer rejects that queue request and recommends installing into `~/Applications/Converse.app`. Quit the old app and open the new Applications copy explicitly; an old Dock shortcut may still target the old copy. Wait a few seconds after quitting before reopening. Conversations and credentials are not touched. The script prints a status-file path; check it for `INSTALLED` before claiming the installed copy is current. This is a local developer installation helper, not an automatic release updater.

Keep your checkout outside Documents, Desktop and Downloads (for example, `~/Developer/Converse`) to avoid macOS protected-folder prompts during development. Builds go into `.build`; use `CONVERSE_APP_OUTPUT=/path/to/Converse.app` to choose another destination. The build refuses to replace a running app because changing an ad-hoc signature can invalidate its privacy permissions.

The build derives app icons from the supplied [logo master](../Resources/Branding/Converse-Logo.jpeg) and creates `.build/Converse.app`. When exactly one valid Developer ID Application identity is installed, builds use it automatically with hardened runtime and a secure timestamp. If several are installed, select one with `CONVERSE_SIGN_IDENTITY` (certificate SHA-1 or full name). Without a Developer ID identity, local builds use an ad-hoc signature; `CONVERSE_SIGN_IDENTITY=-` explicitly requests one. Local builds are not automatically notarized. Generated app and icon bundles are excluded from Git; their source is included.

Install and authenticate the assistant CLIs separately. Configure each entry with the matching adapter; Converse uses Muse’s interactive MSP host and the other adapters’ headless modes. Command lines run through your login shell. Homebrew and `~/.local/bin` are included in the executable search path.

## Check

See the [testing strategy](../docs/testing.md) for the coverage layers, platform commands, release checks and remaining gaps.

With Muse installed:

```sh
./test.sh
```

For provider-only checks without a macOS GUI session, use `./test.sh --providers-only`. They validate shared multi-window placement, displacement/parking, window naming/closing, hover identity and persistence, catalogs, setting arguments, all three interruption paths, exact resumption, queue ordering and recovery, failure handling, account environment separation, and archive compatibility using offline peers. A live read-only smoke query is available with `.build/Converse.app/Contents/MacOS/Converse --probe-provider-status codex /path/to/codex-home` (or `claude /path/to/claude-config`). Neither submits a model prompt. If iconutil is unavailable in the build environment, `CONVERSE_SKIP_ICON_BUILD=1 ./build.sh` reuses an existing icon bundle.

The checks use isolated temporary data and Muse's offline echo provider. They cover real Muse execution and session resumption, prompt quoting, persistence, image creation and image-only clipboard paste validation, interactive Muse completion and approval/question round trips, text editing and styling, Command-Return, input blocks, output cleanup, elapsed-time markers, clickable links, and Claude/Codex protocol fixtures. Claude and Codex checks do not make paid requests.

### Isolated UI testing

After building, run `python3 Tests/prepare_ui_qa.py` and open the app path it prints. The dedicated **Converse Isolated QA** app, copied offline provider fixture, data and working directory live under `~/Library/Application Support/Converse Developer QA`, outside Documents, Desktop and Downloads. The helper does not launch the app or request access to protected folders. It never copies real accounts, conversations or credentials, and refuses QA configurations that point outside its isolated folder or invoke live assistants. Rebuilding this ad-hoc QA app does not require Documents access. Keep UI testing in this app; the production app may legitimately ask for access when a user chooses a protected project folder.

Provider identification marks are bundled from [Simple Icons 14.15.0](https://github.com/simple-icons/simple-icons/tree/14.15.0) under CC0. Their license and source notice are included with the app.

## How it works

- **Muse:** `muse serve` over bidirectional JSON-RPC (MSP), resuming the retained session and using `turn/start`. Approval requests and questions are displayed above the transcript; decisions and answers go back on the same connection.
- **Claude:** print mode with streaming JSON, resuming its exact session ID.
- **Codex:** `codex exec --json`, resuming the returned thread ID.

Each Muse turn opens an interactive host, which closes after the authoritative `turn/completed` event; Claude and Codex launch headless processes. Muse interruption uses `turn/interrupt`. If no completion arrives within five seconds, Converse stops that session’s local host, escalates to a forced exit after another five seconds if needed, and waits for the host to exit before resuming. Stop holds queued messages; Inject resumes them in the saved conversation without changing the current draft. Claude and Codex receive SIGINT, with SIGTERM after five seconds if needed; Converse waits for the old process and output stream to close before resuming the exact conversation with the replacement draft. It never starts a replacement concurrently with the interrupted turn. This gives consistent interruption behavior without depending on each CLI’s terminal key bindings. The CLI's own session store retains model context; Converse retains the visible transcript and draft. There is no idle terminal process. The interface uses AppKit's native text system, with a SwiftUI sidebar and controls.

### Session identity for embedded agents

Every user turn includes a local-context line with the **current session title**, Converse session ID, time zone and working folder. Titles use JSON string escaping. A rename appears on the next sent message, including queued messages when they are dispatched. Right-click a sidebar session (long-press on iPad) → **Rename…** works for local and remote sessions, even while running. Remote renaming saves at home and updates every viewer without taking the display lease. Blank names are rejected; image-only first prompts keep a default name. Settings → Models & sessions also offers Rename.

For Claude Code, Converse publishes `~/.converse/sessions/<transcript-uuid>.json`. The UUID is Claude Code’s transcript filename (`<uuid>.jsonl` under the selected login’s `projects` directory), lowercased, rather than the window or title. The local-context line includes that UUID and the exact sidecar path so an agent can resolve its own seat without guessing from other sessions. New Claude sessions use the UUID passed to `--session-id`; resumed sessions use the reported transcript UUID.

The JSON contains `title`, `transcriptUuid`, `converseSessionId`, ISO-8601 `createdAt` and `titleUpdatedAt`, `converseVersion`, `live` and optional `closedAt`. Converse writes it at creation/startup and replaces it atomically on every rename or transcript-ID discovery. Published files are read-only (0444); Converse owns title changes through its UI, with no title-writing agent API. As with other local files, these permissions do not isolate a tool that has unrestricted access as the same macOS user.

Agents must check `live` is `true` and `transcriptUuid` matches their own transcript before trusting the title. Closing a conversation writes a tombstone (`live: false`, `closedAt` set); parking it or closing its window keeps the conversation live. Restoring a closed conversation republishes its identity. Isolated developer runs place sidecars under their isolated data directory instead of the user’s `~/.converse`.

Right-clicking submitted text offers **Copy this prompt** or **Copy this response** for that message alone. Drafts and gaps do not offer a whole-message copy action; the standard selection Copy remains available.

In light mode, the line-number gutter uses white behind responses and light blue behind prompts (including the editable draft), with grey numbers. In dark mode it uses black behind both, with white response numbers and blue prompt numbers. Prompt shading spans wrapped lines and attached images so input blocks remain easy to find while scrolling.

Permission requests use a bright yellow PERMISSION REQUIRED heading and bordered approval card in the session pane. If a conversation awaiting approval is parked everywhere, its sidebar row turns yellow with an exclamation point. Assigning it to any pane clears the sidebar alert; approval controls stay in that pane.

Model, effort and permission menus remain editable during a running turn (a setting RPC briefly waits for its acknowledgment). Muse uses the active connection for live changes: permissions apply to subsequent actions without deciding approvals already waiting, models apply at the next model-call boundary, and effort applies next turn. Claude/Codex selections are saved for the next CLI turn. A status message states the timing or rejection. Renaming is immediate even while running. Muse’s YOLO option is named **Unrestricted** in its native catalog.

The developer installer uses `dockutil`, when available, to repair an obsolete Converse Dock shortcut while preserving its position, and verifies the target afterward. Local updates must verify both the installed app and its actual shortcut.

## Data

Local data lives in `~/Library/Application Support/Converse/`:

- `sessions.json`: assistant settings, transcripts, drafts, attachment paths, and saved delay markers.
- `Attachments/`: persistent image files, so saved screenshots remain available after temporary files are cleared.

The app uses the installed CLIs' authentication and permission configuration. Credentials, transcripts, and personal settings are not part of this repository.
