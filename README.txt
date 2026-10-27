Converse — macOS preview 0.3.0

OPEN
Double-click Converse.app. The download supports Apple Silicon and Intel Macs running macOS 14 or later.
It is ad-hoc signed, not Developer ID signed or notarized.
Drag Converse.app to Applications. Install and sign in to your assistant CLIs separately.
If macOS blocks the app, see https://support.apple.com/102445 for Apple's guidance.
The source and build script are included; no Xcode project or third-party dependencies are required. This preview was built and tested on this Mac with its installed macOS SDK.

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

Muse displays approval choices and tool questions above the transcript and sends your decisions back. Status distinguishes waits, reviews, retries, background checks and completion. Claude/Codex interactive approvals, login flows and full slash-command menus remain unsupported. No approval or sandbox bypass flags are added.

BUILD / TEST
./build.sh rebuilds the application using swiftc and applies a local ad-hoc signature.
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
Changes affect only this conversation and apply on subsequent turns. Active work
finishes before the controls become available. Existing sessions use durable Muse
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
Return sends or queues; Escape interrupts and sends the current draft, or just
stops if it is empty. Muse uses native turn/interrupt. Claude and Codex receive
SIGINT and resume the exact conversation only after the old process exits.
Stop and failures pause queued messages. Queues survive relaunch paused.
Settings > Accounts manages named sign-ins. Sam/AltSam reuse their Codex stores.
Claude/AltClaude have separate CLI stores; desktop sign-ins do not transfer.
Sign in to each Claude CLI account once with its Sign in button. Choosing another
account for existing work opens a separate conversation and transfers your draft;
the original account keeps its history. No credentials are copied into Converse.

SESSION MESSAGING
Right-click a session and choose Teach Session To Talk To Other Sessions.
Then ask it to "tell <name> <message>" (or "tell <name> urgently <message>").
The assistant queries a live session directory and emits visible JSON commands.
Normal messages queue; urgent messages interrupt. Both preserve the recipient draft.
