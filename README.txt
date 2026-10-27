Converse — macOS preview 0.4.2

OPEN
Double-click Converse.app. The download supports Apple Silicon and Intel Macs running macOS 14 or later.
It is ad-hoc signed, not Developer ID signed or notarized.
Drag Converse.app to Applications. Install and sign in to your assistant CLIs separately.
If macOS blocks the app, see https://support.apple.com/102445 for Apple's guidance.
The source and build script are included; no Xcode project or third-party dependencies are required. This preview was built and tested on this Mac with its installed macOS SDK.

FIRST LAUNCH
The setup guide lets you select one or more assistants, follow CLI installation
links, check each CLI, choose a working folder, and sign in to named accounts.
Default accounts reuse existing CLI logins. Add another account for a separate
sign-in. Sign in opens Terminal; finish its browser/terminal flow and return here.
Muse reuses its own CLI login. Choose an assistant and account to create a first
session; creating it sends no prompt. Check CLI confirms installation, not sign-in.
Help > Setup Guide reopens setup. Set up later skips it. Existing accounts,
commands, sessions and drafts survive upgrades unchanged.

USE
Click + beside an assistant to start a separate conversation.
Settings (Command-comma) edits display names, command lines, directories, and adapters.
Each command line must launch the selected CLI; Muse uses interactive MSP, while Claude/Codex use headless modes.
Existing sessions keep their original settings. Changes apply to new sessions.

The entire right pane is a native scrolling Mac text document.
Type at the bottom. Return sends or queues while busy. Queue rows have Inject now;
Inject all sends the queue together. Both interrupt current work. Escape does not send.
Command-Return inserts a newline (Shift-Return also works).
Draft text is blue; submitted input becomes italic in the system text color.
The app follows the Mac's light/dark appearance.
No speaker labels, prompts, or extra spacing. The window follows typing.
Subtle rules enclose each input block. The top-right line numbers checkbox
controls a narrow gutter of logical line numbers; it defaults on and is remembered.
There is no separate composer or fixed-height input box. Drafts grow with the document.
History is selectable and protected from edits. Typing from history moves to the draft.
Command-A while in the draft selects just the draft.
Paste a screenshot with Command-V while the text window has focus, or use the paperclip.
Images are saved as PNG files; their filenames are included in the prompt. Muse and Codex also receive native image arguments. Claude can read the attachment directory.
Click HTTP/HTTPS links to open them in your default browser.
Text is selectable and supports copy. Assistant Markdown renders native headings, emphasis, lists, code, quotes, links and pipe tables. Right-click for Copy this prompt or Copy this response. Rich-text targets receive RTF/HTML formatting; plain-text targets receive original Markdown, without delay markers.
The app icon is a high-top tennis shoe — Converse.

Command-N / File > New Window opens a window with the same sidebar and up to three right panes.
Use 1, 2 or 3 beside a conversation to move it here; any displaced conversation is parked.
Closing windows leaves work running. Click the Dock icon to reopen a window.
Sessions remain listed after their window closes; select one to reopen it.
Bold assistant names indicate that sessions exist. A spinning rainbow beachball indicates active work.
Stop interrupts the current turn, preserving the conversation for another message.
Quitting warns if work is active. Conversation history and drafts are saved across launches.

DATA
~/Library/Application Support/Converse/sessions.json contains settings and transcripts.
Attachments/ contains saved PNG files. These files are persistent rather than temporary,
so saved conversations do not lose their screenshots when the OS clears temporary files.
No separate app account or API keys are needed: the installed CLIs supply authentication.
A login shell supplies your environment; ~/.local/bin and Homebrew are also searched.

ADAPTERS / CURRENT LIMITS
Muse: muse serve with session/resume and turn/start; interactive approvals and questions.
Claude: claude --print --output-format stream-json; resumes its exact session.
Codex: codex exec --json; later turns resume the returned thread ID.
Each Muse turn uses an interactive host; Claude/Codex use headless commands. Context is retained by the CLI's
session store. There is no idle terminal process. Window closure never stops a turn.
Muse terminal responses and tool activity are displayed as provided by its JSON stream;
Claude text streams as it arrives. Some tools only emit their answer at turn completion.

Muse displays approval choices and tool questions above the transcript and sends your decisions back. Status distinguishes waits, reviews, retries, background checks and completion. Claude/Codex interactive approvals and full slash-command menus are not embedded; /login opens a login picker; new logins and Sign in again open Terminal authentication. Explicit session access selections apply to subsequent turns, including resumes.

BUILD / TEST
./build.sh builds .build/Converse.app using swiftc and applies a local ad-hoc signature.
Keep the checkout outside Documents, Desktop and Downloads while developing.
Running app bundles cannot be overwritten; use CONVERSE_APP_OUTPUT for another destination.
./test.sh runs isolated offline checks using the installed Muse echo provider.
Sources/main.swift contains the app, session engine, adapters, and checks.
The current UI is macOS only. An iPad client and remote session service are future work.

Output cleanup: Muse workspace root/trust diagnostics are hidden, including in saved
conversations. Successful tool activity is hidden; failures remain visible. Gaps of ten seconds or more
before new text display a grey elapsed-time marker. Timing starts when Return sends
a message and resets when visible answer text arrives, not on tool activity. Saved markers survive restarts.

The bottom status line shows reported model, effort, access and last-turn token usage.
Unreported settings are marked CLI default or not reported. This is not account quota.
The assistant receives the Mac local time zone and send time as context.

MUSE STATUS QUERIES AND LOCAL COMMANDS
Opening a Muse session queries its retained metadata with session/read and usage/read.
No turn is submitted; no writer lease, resume, or model request is created.
The log supplies last-turn and cumulative session tokens. Saved effort is labeled
(config) when Muse has no retained effort override. Account quota is displayed only
when observed by Muse, with its observation time; tokens are not account quota.
/model and /models query model details; /usage queries usage; /status refreshes all
metadata; /help lists commands; /stop interrupts. These run locally without a prompt.
The refresh button queries again. Codex and Claude also query their CLI catalogs and retained session metadata without a model prompt.

CLICKABLE SESSION SETTINGS AND SUBSCRIPTION QUOTA
Click model, effort, or access in the bottom bar to choose from Muse's catalogs.
Changes affect only this conversation. Muse permissions apply live, model changes
at the next model call, and effort next turn. Other CLIs apply changes next turn.
Settings remain editable during active work. Existing sessions use durable Muse
setters; new sessions retain choices for their first turn. Global config is untouched.
/usage now fetches the installed CLI's weekly and current-window percentages and
reset times using its built-in usage view in an invisible, no-session-log terminal.
No model prompt is sent. Automatic quota refresh is cached for five minutes; /usage
and the refresh button request fresh data. Failures are explicit, not zero usage.

INPUT AND SIDEBAR SHORTCUTS
Click blank space below the transcript to focus the current input. The editable
view fills tall windows, and normal Mac input methods work after clicking history.
Each sidebar row has activity, title, model and P 1 2 3 X controls.
P parks a conversation without stopping it. 1/2/3 assign it to that pane here,
removing it from any other window and parking the previous occupant.
Each window has a shared list of all conversations and its own pane assignments.
A row shown elsewhere indicates P locally; hover shows the owning window/pane.
Selected placement buttons are green/white; unselected buttons are white/black.
X asks before closing the conversation and turns dark red during confirmation.
Closing stops active work and saves a recovery snapshot. The window stays open.
File > Restore Closed Conversation recovers the latest closed transcript/draft.
Hover over a row for its CLI account email, settings, activity, usage and location.
Right-click a row for configuration, pane moves, park, show owning window or close.
Right-click the titlebar name to rename a window. The Window menu lists the names.
Closing a window parks all its conversations and leaves work running. New windows
start empty; after relaunch, use 1/2/3 to show saved conversations again.

ALL-ASSISTANT SETTINGS, QUEUES AND ACCOUNTS
The bottom model, effort and access dropdowns work for Muse, Claude and Codex.
Menus use the installed CLI catalogs and supported effort levels. Settings apply
to subsequent turns, including resumed conversations. Other model/effort entries
accept custom values, which the CLI validates. CLI defaults remain labeled when
no resolved effort is reported.
Return sends or queues. Inject now and Inject all interrupt with queued input.
Escape has no send or interrupt binding. Muse uses native turn/interrupt. Claude and Codex receive
SIGINT and resume the exact conversation only after the old process exits.
Stop and failures pause queued messages. Queues survive relaunch paused.
Settings > Models & sessions groups sessions and saved logins by model. Defaults reuse standard CLI stores.
Add named accounts for separate logins; desktop sign-ins do not transfer.
Choose an existing login or sign into another account for a selected session.
The same session keeps its history, retained CLI context and draft; other sessions
keep their bindings. No credential files are copied.

SESSION MESSAGING
Right-click a session and choose Teach Session To Talk To Other Sessions.
Then ask it to "tell <name> <message>" (or "tell <name> urgently <message>").
The assistant queries a live session directory and emits visible JSON commands.
Normal messages queue; urgent messages interrupt. Both preserve the recipient draft.

LICENSE
Copyright 2026 Richard Kaufmann. Licensed under the Apache License, Version 2.0.
See the included LICENSE file.

SIGN-IN RECOVERY
Click the conversation login identity or type /login; choose Sign in again.
Converse opens that account's CLI login in Terminal, without sending a model prompt.
Finish sign-in there, return, then retry your input or resume the held queue.
The conversation title does not choose its account. History and drafts stay intact.
Sidebar hover details use a scrollable panel; move into it to select/copy text.

MODEL → SESSION → LOGIN
The sidebar has one heading each for Claude, Codex and Muse. + creates a session
and lets you choose an existing login or New login. /login and the footer login
identity open the same picker. Settings uses the same model/session hierarchy.
Changing a login preserves the same session and its retained CLI context.
Claude: Manual, Accept edits, Auto, Plan, Don't ask (deny unapproved), Bypass permissions.
Codex: sandbox access and approval policy have independent controls.
Muse: models, efforts and available permission profiles come from the host.
CLI catalogs supply model IDs and supported effort levels for the selected login.

PANE SIZING
Adding a pane caps a wide sidebar until the model column is hidden, preserves
a deliberately narrow sidebar, then divides the remaining width evenly.
Removing a pane keeps the sidebar width and
evenly redistributes the remaining panes. Replacing a pane's conversation leaves
its gutter positions unchanged. Gutters remain adjustable.

SESSION CONFIGURATION
Session titles refresh immediately in the sidebar, pane header and Settings.
Working-folder and command changes apply to the next CLI turn, preserving the
conversation and login. The next prompt includes the current working directory.
Stop or finish active work before changing these settings.

SESSION LOGINS
Login is a property of each session. Reusing an existing login never changes its
authentication. Signing into another account stages a fresh isolated CLI store
for only that session, preserving its history and retained conversation context.
Other sessions keep their login and work. Credential files are never copied.
The installed Claude CLI login is distinct from explicitly setting its config
folder; existing authenticated logins can be reused without another sign-in.

SESSION IDENTITY
Each user turn identifies its current session title and Converse session ID in
local context. Right-click a sidebar session > Rename works during a running turn.
Claude agents can also read ~/.converse/sessions/<transcript-uuid>.json, where the
UUID matches their Claude Code transcript filename. Local context gives the exact
path. Fields: title, transcriptUuid, converseSessionId, createdAt, titleUpdatedAt,
converseVersion, live, closedAt (when closed). Dates use ISO 8601.
Files are replaced atomically and published read-only. Renames update immediately;
closed conversations are tombstoned with live:false. Agents must verify live:true
and their own transcriptUuid. Parking/window closing leaves the conversation live.
There is no agent API to change titles. Same-user unrestricted file tools retain
normal macOS access. Isolated developer runs use their isolated data directory.
Right-click text to copy only that prompt or response, according to the message.

Window resizing preserves manually chosen session-pane proportions. In small
windows the sidebar shrinks; growing restores its preferred width and pane
proportions. Temporary readable-minimum clamping does not erase your settings.
Header logos use Meta blue, Claude clay, and the uncolored OpenAI mark.

The line-number gutter is white for responses and very light grey for prompts,
with midpoint-grey numbers. Wrapped prompts and the draft keep the same shading.

Approvals stand out with a bright yellow PERMISSION REQUIRED card in the pane.
A session awaiting approval that is parked everywhere gets a yellow sidebar row
and an exclamation point. Showing it in any pane clears that sidebar alert.

Muse YOLO is called Unrestricted in the native permission-profile menu.
Setting timing or rejection is shown below the controls. Renaming is immediate.
