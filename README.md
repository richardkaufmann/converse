<p align="center">
  <img src="docs/converse-icon.png" width="160" alt="Converse robot logo">
</p>

# Converse

Converse is **one app for Muse, Claude Code, and Codex across your machines**. It gives Muse, Claude Code, and Codex the same normal, selectable, formatted text window — the immediacy of a shell, without pretending you're using a CRT from the 1970s. Sessions can live on your Mac, a Windows PC, a headless Linux box, or be driven from your iPhone or iPad, and the models can message each other across all of it. You might like it if...

* You use multiple coding tools, or multiple accounts with one coding agent.
* You work on more than one machine and want one place where everything is visible.
* You have noticed how hard it is to build a switchboard where these tools talk to each other.
* You hate looking at raw markdown.

It's a bit "opinionated" to match how I work. Feel free to rip it off and make any changes you like.

100% vibe-coded.

🔒 [Security and privacy](#security-and-privacy) explains provider sharing, Group access and credential storage.

📖 **Documentation:** this README is both the [GitHub front page](https://github.com/richardkaufmann/converse) and the in-app Help (searchable, offline, under **Help → Converse Help** on Mac). The two are the same text.

## Security and privacy

Converse runs sessions and agents on their **home system** while Converse is open. Local storage does not mean local AI: your prompts and the context needed to answer them are sent to the **provider selected for that session or agent**. That provider's account terms, retention settings and privacy policy apply. Converse does not make a blanket promise that providers never retain data.

**Choose what an agent can see.** An agent receives its conversation, objective and working notes. If you select other sessions in Agent Setup, relevant excerpts from those sessions are also sent to the agent's selected provider—even when those sessions use a different provider or live on another Group member. New agents start with no watched sessions. Repository checks send the repository name to GitHub and supply returned issue/release information to the selected model. Treat private repository content as private data. App Support's daily check uses the Converse repository, runs every 1,440 minutes while the app is open, and starts without watched sessions or mood art. You can pause its loop in Agent Setup.

**Integrations have their own sharing boundaries.** Enabling Discord reading supplies the configured channel's messages to the agent. Alerts and mention replies can send content back to that channel; public mention handling excludes private session history by default. Sharing session information requires an explicit setting and a verified private channel. Enabling Jolly lets the authenticated Meta Muse phone connector submit requests to permitted agents and retrieve replies/images. General Converse health questions route to App Support and may include the Group name and host display names/status. Disable an agent's Jolly access to remove it from this routing. Voice and image features—including SAM—use Meta services independently of the conversation's selected model; the relevant audio/image is sent when you invoke those features. Pasting a key into a credential field does **not** send it to a model.

**Keys and logins.** On Mac, API tokens entered into Agent Setup are saved in macOS Keychain; the app's device identity also uses Keychain. On Windows, agent API keys and GitHub tokens use Windows Credential Manager (`PasswordVault`). Credential fields mask typed and pasted values with bullets, and saved credentials are not filled back into the form. A blank field preserves the saved credential; removal is explicit. These credentials belong to the home system and are not included in Group agent-settings messages. CLI login tokens are managed by Muse, Claude Code or Codex in their own account stores; their storage protection depends on that provider and platform. Converse saves account labels and store locations, not a copy of the login token in the transcript. Never paste passwords or API tokens into a chat: chat text becomes conversation context. Masking a field protects against casual viewing; it does not erase the system clipboard or protect against software already running as your user.

**Group connections and local data.** Pair only devices you trust and compare the displayed pairing code. Group traffic uses authenticated encryption and pinned device identities. A Group can carry transcripts, drafts and attachments to its authorized viewers; it is not a permission boundary between mutually untrusted people. Removing a member prevents future authorized access but cannot retract data it already received. Conversation archives, attachments, exported files and diagnostic/recovery snapshots are local files and may contain private information; they are not all individually encrypted by Converse. Protect your OS account, enable FileVault/BitLocker as appropriate, and protect backups. In the current Windows implementation, the device identity is also a file in the user profile; it does not yet have the Keychain-equivalent protection used on Mac. Do not share an application profile or include it in a public source archive.

**Agent control is scoped, not infallible.** Teaching a session app control enables a defined set of validated operations; it is separate from switchboard messaging permission. Quoted instructions, repository issues and remote messages are data, not permission to change settings. Background runs cannot execute setup changes. A provider error or incomplete response must not execute partial actions. Ordinary coding sessions can still run tools under the access mode you select; use restrictive permissions for unfamiliar projects. App Support reports critical bugs and available releases; it does not silently install an update. Automated tests cover these boundaries, but this is not a claim of an independent security audit.

## Converse App Support (Mac)

Starting with Mac **0.5.58 (83)**, a new installation starts with one **Converse App Support** session. Pick Meta Muse, Claude, or Codex; Converse opens that provider's native CLI login, then checks one short model response. Setup stays gated on failed, cancelled, missing, or timed-out authentication. The support session becomes available only after a successful model response. No additional setup questionnaire is required.

Starting with the next preview, successful onboarding turns App Support into an agent using the login you just verified, with a daily (1,440-minute) loop watching `richardkaufmann/converse`, no watched sessions and no mood art. It reports release availability and serious bugs rather than installing updates automatically. Successful onboarding teaches App Support both app setup/control and the switchboard. It clears the login and teaching text from view before showing the support reply; the learned context remains intact.

The welcome message links to **README**, **Security and privacy**, **Discord**, and **Connect the Meta Muse iPhone app**, plus the three getting-started guides below, using in-app links. The Meta Muse iPhone link opens Jolly; it is distinct from pairing the native Converse iPhone/iPad viewer. The welcome ends: “Tell me what you'd like to set up, or just ask for help understanding what the app can do”.

Right-click a local session or agent and choose **Teach Converse Setup & Control** to enable the same help and app commands. Teaching survives restart and compaction. The assistant can inspect safe configuration, search installed Help, create a paused agent, configure its objective/repository/Discord channel/Jolly access, and open native setup controls for credentials and connection tests. App operations return explicit results; saving settings does not prove a connection works. No scheduled loop or speech is enabled by teaching. **Disable app control** revokes the capability.

Existing installations retain their sessions, accounts and layout; upgrading does not rerun first-launch setup. The separate **Converse Setup Preview** remains available for isolated onboarding tests. See [the preview walkthrough](docs/NUX-PREVIEW.md).

## Set up your first coding session

A **coding session** is a conversation with Muse, Claude Code, or Codex, connected to a working folder on its home computer. The provider can inspect or change files there according to the access settings you choose. Start with one session and one project.

1. **Finish provider setup.** In the App Support welcome, pick a provider and complete its login. Wait for Converse to confirm a model response. On an existing installation, use **Settings → Models & sessions** to check your provider and login.
2. **Choose the computer that holds your code.** In the sidebar, find that device and click its **+** menu. For a first session, use **this device**. A remote device must be online and in your Group; its folders and logins belong to that computer.
3. **Choose Muse, Claude, or Codex.** Give the session a useful name, such as “Website — Claude,” and select the project's working folder. Choose your existing login—including the one you just set up for App Support—or **New login…** for a separate account. Complete any login in the provider's Terminal/browser flow.
4. **Create the session and show its pane.** Creation itself sends no prompt. If it is parked, use **1**, **2**, or **3** beside its name. On iPhone, select it in the session picker.
5. **Review the footer settings.** Choose the model, reasoning effort, and access/permission mode appropriate to your work. To get oriented, begin with a request such as: “Read this project and explain how it is organized. Don't change any files yet.”
6. **Type at the bottom and send.** Return sends on desktop; Command-Return adds a line on Mac. On iPhone/iPad, use **Send**. Read the response and answer any provider approval request before asking for changes.

You have a working coding session when the assistant responds about the intended project, using the intended login and home computer. A provider being installed is not enough; the first successful response confirms the connection.

To have this session cooperate with others, choose **Teach Session To Talk To Other Sessions** from its context menu. Then ask naturally: “Ask Code Review to review this change.” App Support receives switchboard teaching automatically during Mac onboarding. Each ordinary coding session still has its own teaching choice.

## Set up your first agent

An **agent** is a session that can check on a defined objective, read/message the sessions you select, and optionally run on a schedule. Choose a model from the enabled providers in Agent Setup. The picker binds the model to its provider/login; Meta API models use the locally saved Meta key. CLI agents use the evidence supplied by Converse; hosted web research, mood art and voice still require Meta API support.

1. **Choose its home.** On Mac or Windows, select **New agent…**, or use the **+** menu on a capable online device in your Group. Give it a descriptive name, such as “Project Steward.” New agents start paused.
2. **Open Agent Setup.** Use the agent's context menu or **… Agent actions → Agent Setup / Loop…**. On its home computer, choose a model and login from the dropdown. For Meta API models, enter your key in the secure field and use **Test key** (one short Meta request). Save the settings; don't paste keys into the conversation.
3. **Write the objective and success criteria.** For example: “Watch the Website and Code Review sessions. Identify blockers, ask for missing evidence, and tell me when the release checklist is satisfied.” A specific outcome makes the agent's reports more useful.
4. **Select its scope.** Under **Sessions this agent may read and message**, check only the sessions needed for that objective. The selection starts empty. Those selected sessions provide the evidence the agent can use; pairing a device does not automatically select all of its sessions for an agent.
5. **Start with one manual check.** Leave **Enable automatic loop** off, save, then choose **Run once**. Read its response and any attention message. Adjust the objective or scope until the result is useful.
6. **Add a schedule if you want one.** Choose the interval or text schedule and **Maximum turns per loop**, then enable the automatic loop and save. On desktop homes, Converse must remain open; Linux agents run in the home service.

GitHub, Discord, art, and the Meta Muse iPhone connector are optional. Leave **Repository** blank for a general-purpose agent. For artwork, enable mood art and use **Scoreboard art direction** to specify the subject and style. Scheduled runs stay silent; spoken conversation starts with **Start talking!**

For Discord, follow [Agents and project scoreboards](#agents-and-project-scoreboards). For the **Meta Muse iPhone app**, follow [Jolly (Mac)](#jolly-mac). That connector is separate from the native Converse iPhone/iPad app, which joins a Group.

A useful first test is a manual run that correctly describes the selected sessions and reports a concrete next step. Saving configuration alone does not prove that an external service is connected.

## Connect your devices into a Group

A **Group** connects your Converse installations so you can view and control sessions across computers and mobile devices. A session always runs on its **home**: its provider login, tools, and working folder stay there, even when you type from another device.

1. **Open Converse on both devices.** Start on the same local network, using compatible current builds. Mac and Windows can host sessions; iPhone and iPad are viewers/controllers. To add a headless Linux home, first follow [Connect a Linux computer](#connect-a-linux-computer).
2. **Create one Group.** On your first desktop, open **Converse Groups** below the sidebar or from the Converse menu. Choose **Create Group**, enter a name, and press **Create**.
3. **Join from the other device.** Open its Groups/pairing controls, find that Group, and choose **Join**. On iPhone, those controls are in the session picker opened by the stacked-rectangles button. Create the Group only once; the other devices join it.
4. **Verify the devices together.** The joining device shows an eight-part verification number. On an existing member, choose **Review** for the incoming request. Compare all eight parts, then press **Pair** on both devices.
5. **Choose a session to display.** After admission, the sidebar lists devices and their sessions. Use **1**, **2**, or **3** on desktop/iPad, or the session picker on iPhone. Joining does not automatically take a session.
6. **Try a round trip.** Open a session from another device, send a simple request, and confirm its reply. Taking that session transfers its display to you; it does not copy the project or move execution. **P** parks the pane while work continues at home.

Repeat the join and verification steps for additional computers, iPhones, or iPads. Any current member can review the next join. Each installation belongs to one Group at a time. You can give devices recognizable shared display names using **Rename device…**; their internal identities stay unchanged.

If discovery shows nothing, check that the apps are open, local-network access is allowed, and both devices can reach each other. On a reachable VPN or another network without discovery, use **Host or IP**, **Port**, and **Join** to contact an existing member, then perform the same verification.

Group membership grants access to session history and tool control under the home computers' logins, and members can admit other devices. Use your own trusted devices. A disconnected viewer does not stop work at home; return to the same home session when it reconnects.

## Feature overview

### 1. One client for your coding models

Converse drives **Muse, Claude Code, and Codex** through one native UI on Mac, Windows, iPhone, and iPad, so every provider gets the same behaviors instead of each vendor's terminal quirks. Answers render as real, selectable Markdown — headings, lists, code, tables, links — with tool chatter hidden. Images paste in with ⌘V on Mac/iPad or Ctrl+V on Windows, or attach through the attachment controls, and images the assistant produces appear inline in the conversation and travel to remote viewers.

You type at the end of the conversation: **Return** sends (or queues while a turn runs), **Inject now** interrupts and sends your queued prompt next, and drafts, queue, and attachments survive relaunch. Hover a session for its home, account, model, effort, access, and usage; hover a message number for its date and time; right-click any exchange to **copy that whole prompt or response** (formatted for rich-text targets, original Markdown for plain text). Prompt/response/export flows are built in — see [Export transcripts](#export-transcripts).

Model parameters are yours, per conversation: **model**, **reasoning effort**, and **access/protection** (from read-only to bypass-permissions) sit in the footer. Muse applies supported changes through its live connection; Claude and Codex use saved choices on their next turn. Mac reads provider catalogs from the installed CLIs; Windows and Linux currently discover Codex models while using built-in options for the other providers. On Mac, account status (quota, context use) is one click away, and when a Mac-hosted Claude or Codex session nears its reported context limit, a yellow **Compact** warning offers provider compaction at the session's home — with the transcript, draft, and images left intact. On Mac, local slash commands (`/model`, `/usage`, `/status`, `/login`, …) answer without spending model tokens.

### 2. Converse Groups: one fabric across your machines

Pair your devices into a **Converse Group** and every member sees every session, grouped under its home device. **Mac and Windows** are full participants (UI + sessions). **Linux** runs as a headless home (sessions only): the same Claude/Codex/Muse execution with no desktop, provisioned and maintained over SSH. **iPhone and iPad** are viewers/controllers — models, logins, and working folders stay on their home machines.

Press **1, 2, or 3** to *take* any session onto the screen in front of you — from your iPad, create a session on the Linux box in the closet and drive Claude, Codex, or Muse there — or **P** to park it and let the work continue. Only one device displays a session at a time; the home arbitrates with fenced display epochs, so a stale viewer can never submit under an old lease. Drafts, queues, and attachments transfer with the pane. Disconnects leave home work running, and uncertain sends resolve with **Check home** instead of silent replay.

On iPhone, choose one or two sessions with the subtle **stacked-rectangles** button. Two sessions stack vertically; opening the keyboard gives the focused session the available space and reduces the other to a tappable title strip. **Show keyboard / Hide keyboard** stays visible at the top. Tapping the draft also opens the keyboard; tapping history selects its pane without starting editing. Scrolling keeps the keyboard state, and switching sessions while typing moves the keyboard to the other draft. The session picker also contains pairing, Help, About, and remote session creation. iPad retains its wider sidebar and three-pane layout. A group can contain several iPhones and iPads: each installation has its own device identity and saved layout, with a distinct default name that you can change. Taking the same session from another device still transfers its display lease.

Pairing is designed to be honest about trust: you compare an eight-part verification number on both devices and press Pair on each. Traffic is Noise-encrypted with device keys pinned after pairing. Group admission grants history access and tool control under home logins, and any member can admit the next device, so admit only devices you trust. Discovery works on a LAN via Bonjour; join-by-address covers VPN paths where discovery doesn't reach.

### 3. Messaging: Tell, Ask, and cooperating webs of models

Sessions can talk to each other — across machines, operating systems, and providers. Teach a session once (**Teach Session To Talk To Other Sessions**), then just say so in plain English: *"Ask WindowsClaude for its opinion on this design; iterate until you agree, then go build it."* The assistant discovers live session names and IDs, sends messages through the switchboard, and you watch the exchange unfold in both transcripts as compact traffic lines with status, direction, and an excerpt.

There are two message kinds. **Tell** is one-way: it queues behind existing work (or interrupts with `tell-urgently`), never overwrites a draft, and asks for nothing back. **Ask** expects a correlated answer, blocker, or decline — a delivery acknowledgment does not count. Converse supervises asks: an unanswered request gets at most one corrective nudge, then watching agents are alerted. If two sessions deadlock with tells queued to each other, Converse injects one message once to break the tie — durably recorded, never replayed. Automatic chains stop after 100 hops; every delivery is deduplicated and visible, so a web of cooperating models stays inspectable instead of becoming a black box.

### 4. Agents: sessions with initiative

An agent is a session with a loop. It reads the coding sessions you explicitly select (scope starts empty and is re-checked before every use), assesses progress, injects prompts when needed, and reports back in its own conversation. It runs on a home device's own credentials — the selected CLI login or Meta API key stored on that home — on a bounded interval with per-activation turn limits; failures pause the loop and show a yellow attention badge instead of spiraling.

Agents reach beyond the app. They can search the web for current facts, watch a GitHub repository (stars, issues, PRs, downloads), and, on Mac homes, answer questions in **Discord**, where anyone in a configured channel can mention the bot. Each run can generate **Muse Image** art that reflects current sentiment — new bugs might suggest cinematic horror; zero bugs, a peaceful chocolate orchard — shown in the agent's scoreboard window, an exportable HTML widget, or Discord on request. On Mac, voice works both ways: dictate a draft, or use **Start talking** for a hands-free spoken conversation with turn-by-turn replies.

Converse also integrates with **Meta's Muse mobile app and its avatar, Jolly**. From Jolly on your phone you can address a Converse agent by name, ask what your coding sessions are doing, and leave requests it picks up on your Mac — your desktop coding workspace, reachable from Meta's personal assistant. Credentials and execution stay on the agent's home; its transcript and scoreboard data travel to viewers. Native scoreboard windows and HTML export are desktop features.

### Image tools on Mac and iPad

After attaching or pasting an image, tap the **wand** beside the image count. **Describe image** uses Muse Spark to draft notes you can edit before adding them to the current prompt. Choose **Find Segments** to discover objects, or enter a short description to find matching objects. Blank discovery uses Muse Spark to identify up to six object types, then Meta’s hosted `sam-3.1` segments each type. A typed description goes directly to SAM. Candidates have cyan outlines with contrasting black borders; selected segments turn yellow with a stronger fill. Outlines and numbered badges stay legible when the preview is reduced. Tap/click a segment or its numbered badge to select it, type numbers and press Toggle, or use All / None. **Add selected to draft** creates separate tightly cropped PNG cutouts. **Copy selected** creates one transparent PNG at the original image dimensions and object positions. The original stays attached. Nothing sends until you press Send.

On Mac, right-click any transcript image or unsent attachment and choose **Image tools · Describe / SAM…**. Processing uses the Meta key saved on that Mac. On iPad, the image menu also offers **Use in draft · Image tools…**, which attaches a copy of a historical image and opens the same tools. Neither action submits a prompt.

On Mac, **Save Image to Photos** hands a named PNG to Photos and reports success or failure. Successful import on the Mac is separate from iCloud synchronization to other devices.

These tools work with any session provider. The iPad version requires an updated **Mac home** with a Meta API key saved in Agent Setup; Windows/Linux image processing is not yet available. Processing sends the selected attachment to Meta, using the home's credentials. SAM selects geometry; Spark writes descriptions. Cutouts preserve alpha; background pixels are transparent, including holes inside objects. Discovery is bounded and may miss objects; overlapping duplicate masks are merged. It runs only when you press Find Segments. The binary mask decoder is adapted from Meta’s parser and distributed under the included SAM License (`Resources/ThirdParty/SAM-LICENSE.txt`). If a request times out, **Check result** queries the same operation without paying for another run.

In **Agent Setup**, the separate **Scoreboard art direction** field controls subject, style, colors and humor. It is saved independently of success criteria and passed directly to Muse Image. A changed direction requests new art on the next scoreboard refresh, even if the mood is unchanged. Save and run once to try it; automatic runs remain governed by the existing loop settings.

### Meta models, from desktop to Muse mobile

**Reach your coding workspace from Muse mobile through Jolly.** Ask for a Converse agent by name, get the current status of its selected sessions, and receive its response and available scoreboard art on your phone. The phone is Meta’s Muse client; Converse supplies the authenticated bridge to the agent on your Mac. This is the same multi-provider workspace: a Meta-powered agent can monitor authorized Muse, Claude Code, and Codex sessions together.

Meta also powers work inside Converse itself. Muse coding sessions run through **Muse Code**, and Converse’s own agents call **Meta Model API** directly. These are distinct integration paths:

| Feature | Model and transport | Calling code |
| --- | --- | --- |
| Muse coding sessions | Muse Code’s selected Spark/Wonder model via `muse serve` and MSP `turn/start`; the footer reports the resolved model from the CLI | [Muse connection](Sources/MuseConnection.swift), [status and model catalog](Sources/MuseStatus.swift) |
| Agent reasoning and optional web search | Configurable model, default `muse-spark-1.3`; `POST https://api.meta.ai/v1/responses` | [Mac API client](Sources/Agents.swift), [Mac agent runtime](Sources/AgentRuntime.swift), [Windows/Linux agent runtime](windows/src/Converse.Core/AgentRuntime.cs) |
| Scoreboard art | `muse-image-1.0`; `POST https://api.meta.ai/v1/images/generations` | [Mac API client](Sources/Agents.swift), [Windows/Linux agent runtime](windows/src/Converse.Core/AgentRuntime.cs) |
| Mac speech recognition | `muse-voice-transcribe-1.0`; `POST https://api.meta.ai/v1/asr/transcribe` | [Voice input](Sources/AgentVoice.swift) |
| Muse mobile / Jolly access | Named-agent routing, request status, and returned art through Converse’s own bridge; the selected agent then uses the reasoning path above | [Jolly routing](Sources/Jolly.swift), [bridge and connector schema](scripts/jolly_bridge.py) |

For a demo, keep the Muse session’s resolved model visible while it completes a task. Spark’s current API model ID is `muse-spark-1.3`; Wonder’s is `muse-wonder-1.0`. Wonder Full is a Muse Code subscription option, not a Model API model. The installed CLI’s catalog and the model shown for the actual turn are authoritative; do not label one run as both Spark and Wonder. See [Meta’s model catalog](https://dev.meta.ai/docs/models).

Voice input uses Meta transcription; spoken replies use Apple speech synthesis. Jolly’s mobile access is a connector integration, not an embedded Muse mobile SDK or a replacement phone app. Art is returned when available, and pending work remains pending until the home produces a result. See [Jolly setup](#jolly-mac) for deployment and access details.

The [demo storyboard and implementation evidence](docs/demo-storyboard.md) distinguish the original Mac prototype from the agent, voice, art, mobile bridge and distributed work added during the build period. The iPad image tools also use `muse-spark-1.3` for editable descriptions and `sam-3.1` for point-selected region crops through the Responses endpoint, independently of the session model ([calling code](Sources/ImageAssist.swift)). Spark Open and Glimmer are not implemented integrations.

The rest of this document is the reference: setup first, then daily use, groups, messaging, agents, and internals.

## Download

[Download the latest Mac preview](https://github.com/richardkaufmann/converse/releases/latest). Unzip, drag **Converse.app** into **Applications**, and open it. The universal download targets **macOS 14 or later**, on **Apple Silicon and Intel**. It is tested on an Apple Silicon Mac; older macOS versions and Intel hardware have not been tested directly.

Current releases are **Developer ID signed and notarized by Apple**. macOS shows its normal first-open confirmation. Earlier previews were ad-hoc signed. Install and sign in to Muse, Claude Code, or Codex separately, then set a valid working directory in Converse Settings. No accounts, credentials or conversations are included in the download. You only need the CLIs you intend to use.

## First launch

Setup opens automatically for a new installation. Mac **0.5.58 (83)** and later use the provider-gated App Support flow described above; it does not offer Set up later. Existing users reopening Setup, and older builds, use the assistant/account wizard:

1. Choose one or more assistants, follow the official CLI installation links, and use **Check CLI** to verify installation. Choose an existing project folder (or keep `~` for your home folder).
2. Reuse an existing CLI login or use **Sign in…** to open the selected CLI’s login flow in Terminal. Add another named Codex or Claude account for an independent sign-in. Muse reuses its CLI login. Credentials stay in the CLI’s stores.
3. Choose an assistant and account, then **Create session**. Creating a session sends no prompt. Type at the bottom and press Return to begin.

Use **+** for more sessions, **Settings → Models & sessions** for additional sign-ins, and **Converse → Setup** to revisit setup. **Set up later** skips the guide. Existing users keep their saved accounts, commands, sessions and drafts; upgrades do not rerun first-launch setup or replace local settings. CLI version checks confirm installation, not sign-in or subscription access.

## Use

The Mac sidebar groups sessions by device, with an alphabetized, indented list under each bold green device heading. Offline devices have a lighter green heading and hide their sessions. Click the local device’s **+**, choose Claude, Codex or Muse, then choose a session name, working folder, and an existing login or **New login…**. A new login opens authentication in Terminal; finish there and return. Settings (**⌘,**) follows the same model → session → login structure, with advanced CLI configuration below each model.

- **Return** sends, or queues the draft while a turn is active. Queue rows have **Inject now** to interrupt and send that message next. **Inject all** interrupts and sends the entire queue together in order, preserving attachments and the current draft. Escape has no send or interrupt binding. **⌘Return** inserts a newline; Shift-Return also works. These keys have the same meaning for all assistants.
- Queued messages appear above the transcript, with Pause/Resume, Edit, and Clear controls. Stop pauses the queue; failures pause it too. Queued text and attachments survive relaunch, paused until you resume. You can keep editing a separate draft while the queue runs.
- **Inject now** immediately shows **Interrupting — your queued prompt is next**, then confirms when the prompt starts. Repeated clicks while stopping do not send additional interrupts. Remote queue controls wait for a home acknowledgment; stale items and blocked injections show a reason instead of false success. **Check home** resolves an outstanding request without submitting it again.
- Draft image previews have a small **×** in the upper-right corner. Click or tap it to remove that image before sending; your text and other images stay in place. This also works in remote panes and on iPad.
- Muse turns wait for the previous local host to exit before starting queued input. If another host owns the session, Converse holds the unsubmitted prompt in a paused queue and shows **Session in use · input held**. Close that host, then use **Resume queue** or **Inject now**. Newer draft text and attachments stay intact.
- Your draft is **blue**. Submitted input becomes *italic* in the default system text color, enclosed by subtle separator rules. The app follows macOS light/dark appearance.
- Assistant Markdown renders natively: headings, bold/italic text, lists, inline and fenced code, block quotes, clickable links, and pipe tables. Tool chatter is hidden; the assistant's answer remains visible. Individual failed Muse tool attempts remain in diagnostic activity while the assistant can recover; an actual failed Muse turn is shown explicitly. Muse's workspace root/trust diagnostics are hidden.
- Gaps of ten seconds or more before answer text get grey markers such as `[10 sec]` or `[10.5 minutes]`. Timing starts at Send, then follows visible answer text; hidden tool events do not reset it.
- Right-click in the transcript for **Copy this prompt** or **Copy this response**, using the exchange under the pointer. Rich-text targets receive formatted text (RTF/HTML), including tables and links; plain-text targets receive the original Markdown. Copies omit delay markers.
- Paste screenshots with **⌘V**, or attach images with the paperclip. Attachments are saved as PNG files and supplied to the assistant.
- Images returned by an assistant appear in the conversation and travel to remote panes. Converse asks the assistant to save output images in its session output folder and return Markdown image references. Local output images and public HTTPS image URLs are copied into bounded PNG attachments on the session’s home computer and travel to viewers. HTTPS downloads use no saved cookies or credentials, enforce byte/pixel limits, and reject private-network destinations and redirects. While loading, or if loading fails, a web image’s caption remains a clickable link. Code examples and paths outside the permitted output folders are not imported.
- The **message numbers** checkbox controls the transcript gutter. Each visible message receives one number in a single sequence: prompt numbers are blue and response numbers are grey. Wrapped lines, paragraphs, images, and the editable draft do not add numbers. Numbers from Mac homes continue through history paging. The checkbox defaults on and remembers your choice.
- Input stays at the bottom; the window follows typing. Click blank space below the transcript to focus the input line. The editable document fills the window, including tall windows. Older text stays selectable and protected from edits.
- Scrolling up pauses following. **Jump to latest** shows the number of new output updates and immediately returns to the tail. There is no idle timeout: leaving the cursor at the tail does not pull you away from older text. Typing in that pane or pressing Jump to latest returns to the draft. New output follows only when you have not paused following by scrolling up or selecting history.
- Remote drafts identify the home device and version they were restored from. If a lease refresh supplies a different draft while you have unsent edits, choose **Keep my draft** or **Use home draft**; Converse preserves your local text and images until you choose.

On iPad, an empty display in an existing group explains how to take a session using its sidebar buttons; joining is offered only when no group is selected.

The sidebar gutter can be dragged down to 160 points wide. A compact provider-icon column on Mac, iPad, and Windows identifies each session’s provider; narrowing truncates conversation titles with an ellipsis while keeping the activity indicator and P/1/2/3/X buttons aligned. The full model and title remain in hover details.

Click the **pin** to the left of **Conversation** to hide the sidebar. A small restore pin stays at the top-left of the conversation area. Click it again to restore your previous sidebar width, constrained by the space available. Each window has its own pin state. Hiding the sidebar leaves its displayed conversations and work running.

**Converse → Setup…** reopens account and session setup. **Help → Converse Help…** opens searchable, selectable documentation built from this README and bundled with the app for offline use. Search matches topic titles and article text and highlights matches. Command-F focuses Help search when the Help window is active.

On Mac and Windows, drag files or folders from Finder or Explorer into a conversation pane to insert their full paths at the draft cursor (or at the end of the draft when reading history). Multiple paths are separated by spaces and quoted as needed. This inserts references without uploading or attaching the files; remote drafts label each reference `file from <device name>: <full path>` so its source is clear. Use Paste or Attach to include an image itself. iPad does not insert desktop paths.

Prompts and responses have a blank line between them. In light mode prompt line-number blocks have a light blue background; responses have white. In dark mode the gutter is black, with blue prompt numbers and white response numbers. JSON blobs and switchboard/tell traffic use orange.

Each sidebar row shows a spinning rainbow beachball while the assistant is working (blank when idle or waiting for you), the conversation title, its provider icon, and **P 1 2 3 X**. Agent names have a **🕵️** marker on the right in Mac, iPad, and Windows sidebars and pane headers; the stored name stays unchanged. Hover over the row for account email, profile, model, effort, access, state, current window/pane, usage, quota, directory, queued input, draft/attachment counts and session IDs. Identity comes from the account's CLI: Codex account metadata, Claude initialization/auth status, or Muse's non-secret auth identity fields. The observation time is included; missing identity and probe failures are stated explicitly. Hover refreshes stale metadata without submitting a model prompt.

- **P** parks the conversation: no right pane displays it, and active work continues.
- **1 / 2 / 3** move it into that pane in this window. Each pane holds one conversation; its previous occupant is parked. Moving from another window vacates the original pane immediately.
- **X** asks before closing the conversation, stopping active work and removing it from every sidebar and remote display pane. A group member can also close it remotely when its home supports remote close; older homes keep remote X disabled. A recovery snapshot retains transcript, draft and attachments; **File → Restore Closed Conversation** restores it. Closing a conversation leaves the window open and its pane empty.

Hover details appear in a native scrollable panel after a short pause over any part of a session row. Moving into the panel keeps it open so its text can be selected and copied; moving away closes it.

The selected P/1/2/3 button has a green background and white text. Other buttons have white backgrounds, black text and faint borders. X turns dark red while its confirmation is open. A conversation displayed elsewhere shows P in this window; hover gives its exact location, and its context menu can bring the owning window forward. P always parks it globally.

**File → New Window** (**⌘N**) opens a separate window with the same complete sidebar and up to three independently resizable panes on the right. Changing the number of visible session panes divides their available space equally and preserves the sidebar width. Manual pane widths remain when the count is unchanged. Empty slots take no space; a numbered header identifies each visible pane, with its provider’s logo, a larger session title and a **P** button to park it. New windows start empty. Right-click the window name in the title bar to rename it; the **Window** menu uses these names to bring windows forward. Names are unique among open windows. Closing a window parks all its conversations and leaves their work running. Quit warns about active commands and any agents hosted on this Mac, even paused agents: exiting makes them unreachable and stops their loops until Converse restarts. Confirmed quit preserves configured loop settings for restart; Keep Running changes nothing. Pane assignments belong to open windows; after relaunch, choose 1, 2 or 3 to display saved conversations again.

Adding or removing a visible pane evenly redistributes the conversation widths. Adding a pane caps an overly wide sidebar just below the model-column threshold without expanding a sidebar you deliberately made narrow; removing a pane leaves it alone when space permits. Replacing a conversation in an existing pane keeps the gutter positions. Resizing the window preserves your session-pane proportions, temporarily clamps panes at readable minimums, and restores those proportions when space returns. The sidebar scales down in smaller windows and returns toward your chosen width as the window grows. Gutters remain adjustable; the window grows only if needed to fit the minimum sidebar and session widths.

Right-click a conversation for Configure, pane moves, Park, Show in its owning window, or Close. Configure is disabled while work runs. Session titles update immediately everywhere after Save. Changing a session’s working folder applies to its next CLI turn, retaining its login and conversation ID; no new conversation is needed. The current working folder is included in the next prompt’s local context. Missing folders are rejected before saving. Assistant headers retain Configure and New Session actions. Conversations, drafts, attachments and last-observed account identities survive relaunches. Bold assistant names indicate that conversations exist.

A compact bottom status line shows the current state, model, reasoning effort, access setting, and last-turn input/output token counts. Opening a Muse session queries `muse serve` through read-only `session/read` and `usage/read` calls. No turn is submitted and the session is not resumed or attached. The app combines retained session metadata and the session log with saved settings: the model and access profile are session-derived, while a saved effort without a retained override is explicitly labeled `(config)`. The log supplies last-turn and cumulative session token counts across relaunches. The refresh button queries again. Model, effort and access dropdowns work for all three assistants. Codex queries its app server for its catalog, effective configuration and retained thread metadata; Claude uses its prompt-free SDK initialization catalog and retained transcript. Effort menus use the selected model’s reported supported levels. Custom model IDs and effort levels are also available; the CLI validates custom choices. Click the model, effort or access value to choose a conversation setting. Existing sessions use Muse's durable setters; new conversations retain choices for their first turn. Controls remain editable during active work and metadata refresh; they briefly disable while a setting transaction awaits acknowledgment. Global settings and other conversations are unchanged. Values persist and also refresh after turns. For subscription quota, Converse also runs the installed CLI's `/usage` command in an invisible, ephemeral terminal (`--no-session-log`), with no model prompt. This retrieves current-window and weekly percentages and reset times. It refreshes on open (cached for five minutes), `/usage`, or the refresh button. The displayed timestamp identifies the CLI observation when available, otherwise the query time. Failures are shown explicitly; token counts are never presented as remaining quota.

The Mac's local time zone and send time are supplied as context to the assistant, and the child process receives the matching `TZ`. Local time is preferred unless another time zone is requested.

### Account status

**Status unavailable:** click the orange status warning for **Retry status**, **Login settings**, **Session settings**, and troubleshooting help. A CLI status timeout does not by itself mean the login expired. Retry, check that the session command points to the installed CLI, then use Login settings if the provider reports an authentication problem. Muse uses its installed CLI login; follow its sign-in instructions in Terminal and return to retry.

**Agent settings missing:** choose an enabled provider and model in **Agent Setup**. CLI choices use that account’s login; Meta API models use the saved Meta API key. Click **Open Agent Setup** (also available by right-clicking the session). If its configuration is missing, execution stays paused and the setup form explains that it starts with an empty session scope and automatic loops off. Review the objective, selected sessions, schedule and optional Discord settings before saving. This does not restore lost settings from a backup. The existing transcript, draft and saved credentials are retained.

On Mac, **Configuration Diagnostics** in the Converse data folder records startup/quit, archive save origins, configuration field changes, and unexpected archive replacement by another writer. Events include process/run and build identity, but omit configuration values, session titles, transcripts and credentials. Logs rotate and retain a bounded history. Private **Agent Recovery** files retain the latest and previous valid configuration per agent; these can contain objectives and working notes, are owner-readable only, and are never restored automatically. Keep recovery files private; review them before sharing diagnostics. Missing configurations retain the agent marker and cannot launch a CLI.

The compact **Account** control follows Approvals in each local session footer. It shows the last reported context utilization and the highest reported account-limit percentage. Click for individual allowance windows, reset times, and refresh. Codex reports context from its last model call and account rate limits; Muse reports current-window and weekly allowances. Providers that do not expose a value show `?`, including API agents whose account allowance is not reported. These are observations, not guarantees of remaining capacity; account allowances may be shared with other sessions. A clock marks old, unknown-age, or expired observations. Refresh runs off the UI thread and does not send a model prompt.

### Compact session context

For retained Codex and Claude sessions hosted on Mac, **Compact** appears in yellow near the lower-right of the transcript when the latest provider observation is at least 80% of its reported context window. Observations older than ten minutes, unknown limits, cumulative billing totals, and observations from before a known compaction do not trigger a recommendation. A ten-minute cooldown prevents repeated recommendations immediately after compaction. The session-actions menu also offers manual compaction without a recommendation.

Compaction runs at the session's home. If a turn is active, it waits for that turn to finish and runs before queued prompts; **Cancel compact** cancels that waiting request. The full displayed transcript, session identity, draft, and draft images stay intact. Provider compaction summarizes the model's working context and can omit details. Converse waits for a provider completion event; an acknowledgement alone is not success. Interrupted or unconfirmed compaction pauses queued input and is never automatically retried after restart.

Mac and iPad remote viewers use the home's advertised capability and existing display lease. Older or unsupported homes do not show the action. Muse's native context usage events are recorded when supplied, but manual Muse compaction remains unavailable in this preview pending a verified host implementation. This feature does not change any provider's automatic compaction policy.

### About and responsive controls

Mac, iPad, and Windows have **About Converse** with the installed version/build, copyright, and GPLv3-or-later statement and SAM codec exception. Mac and Windows also show version/build in the main window title. On iPad, open **… → About Converse**; **Converse Help** always includes a link to the GitHub README. Linux prints the same information with `converse --about`.

Model, effort, and access controls appear directly when the pane has room. In a narrow pane, a single **…** menu replaces them; it does not duplicate visible controls.


## Converse Groups

Choose **Converse → Converse Groups…**, or **Converse Groups** below the sidebar sessions. **Create Group** gives this device a named group. On another device, find that group and press **Join**. Groups and their discovered devices are listed together; group names must be unique among the groups this device can see.

The joiner immediately sees an eight-part verification number. All current group members see its request; any one presses **Review** to reveal the same number. Compare **all eight parts**, then press **Pair** on both the joiner and that reviewing device. Admission does not take a session automatically. Join-by-address uses the same flow for VPN connections where discovery is unavailable.

Only group members see the additional **Group** section and remote devices/sessions in the sidebar. Sessions stay organized under their home device. The **+ ▾** menu beside an online remote device creates a Claude, Codex, Muse, or agent session on that home. Provider sessions use the home’s configured CLI and login; creation does not start a turn. New sessions appear in the sidebar for placement with **1**, **2**, or **3**. Both apps need remote-creation support; older homes still offer agent creation only. Use **1**, **2**, or **3** to move a session’s display here; its tools, logins and working folder stay home. **P** parks the display. Home work continues when the viewer disconnects; saved panes restore on reconnect if nobody has taken them in the meantime. Uncertain sends require **Check home** rather than automatic replay.

Hover a sidebar device heading to see its reported name, identity, connection status and group. **Rename device…** in its right-click menu (long-press on iPhone/iPad, also available in Groups) sets a display name shared with every group member. Offline devices receive the change on reconnect. Device keys, pairing and operating-system hostnames stay unchanged. Update all group members to use this feature.

Each device belongs to at most one group. A canceled join keeps the previous group. Creating a group or successfully joining another moves **this device only**; groups never merge. **Leave** parks remote panes and preserves local sessions. Any member can **Dissolve** the group after confirmation; offline devices learn that on reconnect. Group membership grants history access and tool control under home logins, and every member can admit other devices, so admit only devices you trust.

Existing paired devices migrate into a default **Converse Group**, preserving their logins and sessions. Update every device to a groups-capable build. Names are display labels; separate LANs may independently create identically named groups, which retain distinct internal identities. [Protocol and verification details](docs/groups.md).


### Linux homes

Linux runs Converse as a headless service: real Claude/Codex/Muse sessions with no desktop and no Converse window. It joins a group through the same pairing flow, answered from another group member, and every member can then take its sessions into a pane. The daemon runs under a systemd user service (guarded cron loop as fallback), keeps execution, logins, files, and secrets on the Linux computer, and is provisioned and maintained over SSH — install, start/stop, session creation, secret storage, and explicit signed updates. Because there is no UI on the host, setup begins over SSH from another computer. Windows **Converse → Set up Linux** walks a trust-first SSH bootstrap (you type the host-key answer yourself; the app verifies the fingerprint before any automated step). The Mac deployment GUI is not yet included; on a Mac, follow [Connect a Linux computer](#connect-a-linux-computer). Linux participates in the same Tell/Ask switchboard, so an agent or a Mac session can message a headless Linux session like any other. See [Linux home contract](docs/linux.md) for the full deployment and recovery model.

### Returning to a displayed session

After wake, reconnect or relaunch, a saved remote pane requests a conditional restore. The home grants a fresh display epoch only if nobody has taken it since that viewer last held it. A newer take remains authoritative even after its holder parks or disconnects, including across home restarts. Explicit P cancels restoration; 1/2/3 remain deliberate takeovers. Both ends need the `lease-resume-v1` capability; older homes still require a manual take. Draft conflicts and uncertain outgoing commands retain their existing review behavior.

## Connect a Linux computer

A Linux computer can be a **headless Converse home**: an always-on box in a closet, a cloud server, or a VM. It runs real Claude Code, Codex, and Muse sessions under its own logins, with no Converse window. You drive those sessions from your Mac, Windows PC, or iPad. Set it up once from your Mac over SSH; it takes about 20 minutes.

> **Let Converse do it for you.** Copy this whole Help topic (click in the text, press **⌘A**, then **⌘C**) and paste it into a Converse session on your Mac that can run shell commands, such as Claude Code or Codex with full access. Add a line like *"Set up my Linux computer `you@my-linux.local` using these steps."* The session runs the commands for you and skips any step that's already done. It stops and hands you a command whenever it needs you: anything with `sudo` (you run it yourself in Terminal, for example `ssh -t mylinux 'sudo loginctl enable-linger $USER'`), approving the SSH host key, signing in to Claude, Codex, or Muse, and comparing the pairing number and pressing **Pair**. Those steps stay with you on purpose.

**What you need**

- A Linux computer with systemd (tested on Ubuntu 26.04), 64-bit Intel/AMD (`x86_64`) or ARM (`aarch64`), on the same network as your Mac.
- Your own user account on it, with `sudo` rights for a few one-time steps. Converse itself runs as you, never as root.
- A Mac that is already in a Converse group (see [Converse Groups](#converse-groups)).
- For now, the Converse source code and the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) on that Mac. Linux builds aren't published as downloads yet, so you build the Linux program on the Mac (Step 4). The build finds .NET on your `PATH` or in `~/.dotnet`; check with `dotnet --version` or `~/.dotnet/dotnet --version`.

In the steps below, replace `you@my-linux.local` with your Linux user name and computer name. The `.local` name works on most home networks; you can use the computer's IP address instead. `mylinux` is the short SSH nickname you create in Step 1; if you already have one for this computer, use it instead. Already did some steps? Skip them. Every check below is safe to repeat.

### Step 1: Let your Mac log in with an SSH key

Converse sets up and manages Linux over SSH, and it needs to log in **without a password prompt**.

1. At the Linux computer itself (its own screen or console), make sure the SSH server is installed:
   ```sh
   sudo apt install openssh-server
   ```
2. On your Mac, make a key just for this computer and copy it over. `ssh-copy-id` asks for your Linux password one last time:
   ```sh
   ssh-keygen -t ed25519 -N "" -f ~/.ssh/mylinux
   ssh-copy-id -i ~/.ssh/mylinux.pub you@my-linux.local
   ```
3. Give it a nickname. Add this to `~/.ssh/config` on your Mac:
   ```
   Host mylinux
     HostName my-linux.local
     User you
     IdentityFile ~/.ssh/mylinux
     IdentitiesOnly yes
   ```
4. Connect once by hand in Terminal: `ssh mylinux`. The first time, SSH shows the computer's fingerprint and asks whether to trust it. If you can get to the Linux computer's own screen or console, run `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` there and compare before you type `yes`.
5. Confirm it now works with no prompts at all; this should print `ok`:
   ```sh
   ssh -o BatchMode=yes mylinux echo ok
   ```

### Step 2: Keep Converse running when you're logged out

Converse runs as a background service under your account. Linux normally stops those when you log out. On the Linux computer, run this once:

```sh
sudo loginctl enable-linger $USER
```

If a firewall is turned on (check with `sudo ufw status`), let Converse and Bonjour through:

```sh
sudo ufw allow 48721/tcp
sudo ufw allow 5353/udp
```

### Step 3: Install and sign in to Claude Code, Codex, and Muse

Install the ones you want to use, at least one. Converse starts them itself, and **it only looks for them in these folders**:

`~/.local/bin`, `/usr/local/bin`, `/usr/bin`, `/bin`

Your shell's `PATH` doesn't matter here, because the Converse service doesn't read `~/.bashrc` or `~/.profile`. Codex is a Node.js program, so `node` must be in one of those folders too. A Node installed only through a version manager such as `nvm` won't be found.

Log in from your Mac with `ssh mylinux`, then on the Linux computer:

1. Install Node.js (for Claude Code and Codex):
   ```sh
   sudo apt install nodejs npm
   ```
2. Install Claude Code and Codex into `~/.local/bin`, no `sudo` needed:
   ```sh
   mkdir -p ~/.local/bin
   npm config set prefix ~/.local
   npm install -g @anthropic-ai/claude-code @openai/codex
   ```
3. Install Muse's launcher into the same folder. It downloads Muse itself the first time you run it:
   ```sh
   curl -fsSL https://api.meta.ai/muse-launcher.sh -o ~/.local/bin/muse
   chmod +x ~/.local/bin/muse
   ```
4. Let your own shell find them too. Put this line at the **very top** of `~/.bashrc`, above everything else, so it also works for one-off commands like `ssh mylinux claude --version`. Then log out and back in:
   ```sh
   PATH="$HOME/.local/bin:$PATH"
   ```
5. Sign in to each one. You're in SSH with no browser on the Linux side, so each tool gives you a link to open on your Mac:
   - **Claude Code:** run `claude`, choose your account type, and open the link it prints on your Mac. After you approve, copy the code from the browser and paste it back into the terminal. Type `/exit` when you're done.
   - **Codex:** run `codex login --device-auth`. Open the link on your Mac and enter the code it shows. (Plain `codex login` waits for a browser on the Linux computer, so it doesn't work over SSH.)
   - **Muse:** run `muse`. It shows a meta.com link and a code. Approve it on your Mac, and Muse finishes downloading. Exit when it's ready.
6. Check that everything is in place:
   ```sh
   ls ~/.local/bin
   claude auth status
   codex login status
   muse usage
   ```

### Step 4: Build Converse for Linux (on your Mac)

1. Find out which kind of processor the Linux computer has:
   ```sh
   ssh mylinux uname -m
   ```
   `x86_64` means **linux-x64**; `aarch64` means **linux-arm64**.
2. In your Converse source folder on the Mac, build it. Use the matching name:
   ```sh
   ./linux/build.sh linux-arm64
   ```
   The program is written to `.build/linux/linux-arm64/converse`. The rest of this page says `linux-arm64`; if yours is `linux-x64`, use that everywhere instead.

### Step 5: Install Converse on Linux

From your Converse source folder on the Mac, copy the program over and run its installer. Use the same name as Step 4:

```sh
scp .build/linux/linux-arm64/converse mylinux:converse-setup
ssh mylinux 'chmod 700 ~/converse-setup && ~/converse-setup install-self </dev/null && rm ~/converse-setup'
```

The installer puts Converse in `~/.local/bin/converse`. It creates its own identity, sets up a `converse` background service, and starts it. Check that it's running:

```sh
ssh mylinux 'systemctl --user is-active converse && ~/.local/bin/converse --version'
```

The computer initially appears under its Linux host name. Right-click its device heading in a desktop sidebar, or long-press it on iPhone/iPad, to change its group display name without changing the Linux host name.

### Step 6: Join your Converse group

Make sure Converse is open on your Mac, then run this from your Converse source folder:

```sh
python3 linux/join-from-mac.py mylinux
```

It finds your Mac's group, asks the Linux computer to join, and walks you through approval. (This script is new and hasn't yet been run end to end on a fresh computer. If it stops with an error, the message says why, and nothing is admitted until you press **Pair** and type `yes`.)

1. In Converse on your Mac, open **Converse → Converse Groups**. The Linux computer is asking to join; press **Review**.
2. The script prints an eight-part number. Compare **all eight parts** with the number on your Mac. They must match exactly.
3. If they match, press **Pair** on your Mac, then type `yes` in the terminal.

Do this within three minutes; if the request expires, just run the script again. If the computer has already joined, the script says so and changes nothing. When it says **Done!**, the Linux computer is a full member of your group.

### Step 7: Use it

On your Mac, the Linux computer now appears under **Group** in the sidebar. Use the **+ ▾** menu beside it to create a Claude, Codex, or Muse session there. Then press **1**, **2**, or **3** to show it in a pane. The work runs on Linux, with its logins and files, and keeps running when your Mac sleeps or disconnects. Each pane's **⋯ Session settings** menu sets the model, effort, and restrictions. Your iPad and Windows PC in the same group can take these sessions too.

**Updating later.** Wait until none of the Linux computer's sessions is in the middle of a reply. Build again (Step 4), then stop the service, reinstall, and it starts again on its own. It keeps its identity, group membership, and sessions. (These exact commands haven't been tested end to end yet; they follow the same stop-then-install sequence used for earlier updates.)

```sh
scp .build/linux/linux-arm64/converse mylinux:converse-setup
ssh mylinux 'systemctl --user stop converse && chmod 700 ~/converse-setup && ~/converse-setup install-self </dev/null && rm ~/converse-setup'
```

**If something goes wrong**

- *The script can't reach Linux:* `ssh -o BatchMode=yes mylinux echo ok` must print `ok` with no questions (Step 1).
- *Pairing never shows a number:* the Linux computer must be able to reach your Mac on port 48721. Make sure both are on the same network, and check firewalls on both sides. If your Mac has several network connections, run the join script again with the address Linux should use, for example `python3 linux/join-from-mac.py mylinux --host 192.168.1.20`.
- *A session says it can't find `claude`, `codex`, or `muse`:* the tool isn't in one of the four folders in Step 3, or `node` isn't. Check with `ssh mylinux 'ls ~/.local/bin /usr/local/bin'`.
- *Converse stops after you log out:* turn on lingering (Step 2).
- *See what the service is doing:* `ssh mylinux journalctl --user -u converse -n 50`.

For how deployment, trust, and recovery work under the hood, see [Linux home contract](docs/linux.md).

## Messaging between sessions

Right-click a conversation row, or its Mac transcript, and choose **Teach Session To Talk To Other Sessions**. The option is also available for remote sessions on updated homes, including parked sessions; teaching queues instructions without taking over the pane. Converse queues an instruction prompt that teaches the assistant to interpret user requests such as “tell Reviewer to check the tests.” It discovers current names and IDs by emitting exactly one complete `converse` fenced JSON reply: `{"command":"list-sessions"}`. Converse queues a live JSON directory response to that session. No static directory is taught.

Every switchboard command must be the assistant’s entire final reply: one `converse` fenced JSON block, with no prose before or after it. Surrounding prose makes the block discussion; no command runs and no delivery error appears.

To deliver, the assistant emits `{"command":"tell","to":"SESSION-UUID","text":"message"}` in the same fence. `tell` queues behind existing work, starts when idle, and respects a paused queue. `tell-urgently` interrupts and delivers next, resuming a paused queue. Drafts and attachments stay intact. Parked sessions receive messages without changing pane placement. Both transcripts show sender, recipient and delivery ID; queued means accepted, not read or answered. No extra acknowledgment turn is generated.

For a request that needs an answer, add `"replyExpected":true`. Reply with `"inReplyTo":"REQUEST-UUID"` and the original sender as `to`. The receiving home matches both the request ID and the authenticated sender; a delivery acknowledgment is not an answer. After a completed turn leaves a request unanswered, Converse allows 30 seconds, then makes at most one corrective injection. If that fails, agents watching either participant receive one attention notice. Human-paused queues and approval/input waits are left alone.

If two sessions have ordinary tells queued to each other and neither has produced output for two minutes, Converse injects one existing message once. Both local sessions and updated group homes participate. Cross-home recovery uses fresh authenticated queue reports containing identities only, with one home elected to act. Recovery is recorded before interruption, survives restart, preserves drafts, and never replays the original tell. Older homes reject tracked requests explicitly; they continue accepting ordinary tells. This mechanism detects mutual waiting, not every kind of dependency cycle.

Traffic appears as a single line with its status, arrow, peer and a short excerpt. Desktop hover shows the complete message; on iPad tap a transcript traffic line to open it. Copy/export retains the original text. Desktop message-number hover shows a recorded local date and time when that message has a saved timestamp; legacy messages without one are left undated.

A recognizable whole-reply command from an untaught session gets a visible notice explaining how to enable messaging; nothing is sent. Bare command JSON also gets a formatting notice and never executes. Only successful, completed assistant turns from enabled sessions execute commands. Partial streams, tool output, prose examples and failed/interrupted replies do not. IDs are recorded with pending delivery before provider execution; restored queues remain paused. Self-messages, missing recipients and messages over 32 KB are rejected visibly. Automatic chains stop after 100 hops, including directory responses. Normal human input starts a fresh chain. The context menu also offers **Disable session messaging**. Teaching and disabling affect the sender; recipients can receive ordinary labeled input without being taught to send.

### Messaging across homes

`list-sessions` includes local sessions and remote sessions from the current group, labeled with their execution home and online/messaging state. Copy the directory’s exact ID: local UUIDs remain supported; remote IDs are `homeDeviceID/sessionUUID`. Both homes need this update for cross-device messaging. Older/unsupported homes are listed with messaging unavailable.

Tells do not acquire a display lease. The recipient must have session messaging enabled on its home; ordinary tells preserve paused queues and drafts. Acceptance means **persisted in the recipient queue**, not read or answered. Duplicate delivery IDs do not enqueue twice. Offline/out-of-group targets fail visibly; an unconfirmed send is not automatically replayed. See [the wire contract](docs/participant-control.md) and [agent design](docs/agents.md).

## Agents and project scoreboards

Agents are **sessions with initiative**: talk to them in a normal session pane, or let a bounded loop and opt-in file events initiate work. Use **New agent…** below the sidebar sessions or **Converse → New Agent…**. An agent appears under its execution home in Group, alongside its other sessions. It starts paused with no sessions selected. Creation and control are available from Mac and Windows (including creating an agent on a remote home in the same group); the agent's execution, credentials, and scoreboard window stay on that home, which may also be a headless Linux server. iPad can view agent transcripts and use agent actions, but does not host agents.

Choose a capable online home in the current group. Mac and Windows run agents while Converse is open; Linux runs them in its headless service. Credentials and execution stay there when you take the transcript on another device. Leaving/changing groups removes old-group visibility and routing; queued messages are checked again before execution.

On desktop homes, open **Agent Setup** to enter a [Meta Model API](https://dev.meta.ai/docs/overview) key; Mac also offers optional GitHub and Discord bot tokens. Linux accepts its key through the SSH manager or secret-stdin CLI. **Test key** makes one short request to the selected model without sending session history; it tests an entered replacement or the saved key. Credentials stay on the home: Mac Keychain, Windows Credential Manager, or the configured Linux secret backend. The home’s agents share its saved key. Remote Agent Setup edits settings without receiving keys. Blank credential fields retain saved values; **Remove saved** explicitly deletes one. Remote creation retries use a durable command identity, so uncertain retries do not create a second agent.

The **… Agent actions** menu stays visible in narrow panes on Mac, iPad and Windows. It opens **Agent Setup / Loop**, **Run once** and **Scoreboard**; local Mac agents also offer loop controls and voice actions. Select the local or same-group sessions the agent may read/message. For the demo steward, explicitly select Converse Development and MuseConverse and explain your project and acceptance criteria in its conversation. Scope starts empty. Same-group evidence is requested from its home without taking a pane; unsent drafts and stored API credentials are excluded. Right-click for **Run once**, **Agent Setup**, **Show scoreboard** or **Clear attention**. **Start talking!** starts a hands-free conversation on this Mac. After detecting sustained sound, a 1½-second quiet pause sends your question. The microphone is off during transcription, the agent’s work, and its spoken answer; it reopens after playback ends. **Stop talking** stops listening/playback without cancelling a question already sent. Existing typed drafts and images stay intact. Automatic loops and queued messages wait while you talk. Initial silence stops after 20 seconds; each recording is capped at one minute, and a conversation at 20 spoken turns. Silence detection uses microphone level, so a noisy room may need **Dictate…** instead. Parking the pane or quitting ends the conversation.

**Dictate…** opens a nonmodal recorder: Record, Stop & transcribe, then review and Insert into draft. Up to 60 seconds of audio goes to Meta Voice using the saved Meta key. It never submits text automatically. Permission denial or transcription failure shows a retryable status; Cancel stops recording and removes temporary audio. Spoken replies use bounded pace/pitch settings from emotional intent.

Agent requests use explicit low reasoning effort and an 8192-token budget shared by reasoning and visible output. An incomplete response never applies actions; token exhaustion, other termination and authentication errors have distinct notices. Safe model/status/token metadata is saved in `Agents/<session-id>/last-response.json`, without request contents, raw output, reasoning text or keys.

The interval is at least 60 seconds. Scheduled ticks, incoming agent tells, Run once and file events each get a fresh per-activation turn limit. Runs never overlap or overwrite a separately edited draft. A failure pauses the loop and raises yellow attention. Closed apps do not run agents. Relaunch schedules the next interval without replaying missed ticks. Stale settings forms cannot overwrite intervening settings changes: use **Reload settings** before saving again.

Optional file events use `Agents/<session-id>/Inbox/*.json` under the home’s Converse application-data folder (the full path is shown in Agent Setup). Enable file input explicitly. A regular, non-symlink file under 16 KB contains `{"id":"event-UUID","text":"Your event, at most 8000 UTF-8 bytes"}`. The event ID and pending input are saved before the file is consumed; duplicate event IDs do not run twice. Invalid input pauses file ingestion with an attention notice. This adds no inbound webhook server or autonomous shell access.

Discord uses one bot token saved in the Mac home’s Keychain, shared by its agents. In Agent Setup, set each agent’s channel ID, enable reading and/or alerts, and use **Test Discord** to post a labeled marker and read it back through channel history. Enable Message Content Intent for the bot and grant channel/history/send permissions in Discord. Reading happens during agent runs; each agent remembers its own position. The first run reads up to 50 recent messages. Bot posts are excluded from monitoring; outgoing alerts identify the agent. Former webhook credentials are no longer used. See [Discord setup](docs/agents.md#discord-bot-integration).

For direct questions, enable **Anyone in this channel may @mention this agent** in Agent Setup. One shared listener checks configured channels every five seconds independently of loop schedules. Choose a **Default agent for this channel** for `@Converse question`, or use `@Converse Agent Name: question` / `@Converse ask Agent Name question`. Use a real Discord mention at the start of the message. Anyone who can post there can use this feature. Requests queue behind active work, respect paused queues, and receive a fresh per-activation turn limit. Replies go back to the source message without pinging anyone. By default these turns see only the question and recent public channel history, with optional web research. **Share session information** additionally supplies this agent’s recent conversation, working notes and scoreboard only when Discord verifies the configured guild text channel is private (the everyone role cannot view it). Both the option and privacy are checked again before delivery. Credentials, unsent drafts and other sessions’ transcripts are excluded; Discord requests cannot change settings or message other sessions. The sharing option starts off. DMs and unconfigured threads are not monitored. Mentions start off until explicitly enabled.

GitHub is optional: leave Repository blank for a general-purpose agent. Such agents skip GitHub requests and show their update and optional art without repository metrics or a GitHub setup warning. Agents can use Meta’s built-in web search for current facts and news; turn it off in Agent Setup if unwanted. Each run allows at most four hosted search calls. Source links come from API results/citations, not invented URLs. With a repository configured, the scoreboard measures stars, open PRs, open issues, open issues labeled `bug`, issue/PR conversation comments, release-asset downloads and, with an authorized GitHub token, unique repository visitors over 14 days. **Actual app users are not measured.** Unavailable values remain unavailable; PRs are excluded from issue/bug totals. Public polling may hit GitHub’s unauthenticated limit.

For general-purpose agents, the model chooses scoreboard cards from your instructions (for example price, change and volume), with a short news/status summary. External metric cards require a source URL returned by that run’s search; unsupported values show Unavailable. Cards display source-reported observation time separately from retrieval time: a prior close or delayed quote is not advertised as a live tick. Search-backed values are model-extracted, not an exchange-grade market feed. Native and exported scoreboards retain clickable sources.

Optional [Muse Image](https://dev.meta.ai/docs/image-generation) art follows your requested subject, humor and logos, using scoreboard sentiment or measured repository changes: new bugs can suggest cinematic horror; zero bugs can become a peaceful chocolate orchard. The scoreboard keeps generated art in a header and measured counts on solid, readable cards. When repository data is unavailable, it shows one GitHub setup explanation rather than empty metric tiles. Art refreshes on mood change or after an hour, at most once per run. **Scoreboard → Export widget** saves a portable HTML snapshot with embedded art, no scripts or network dependencies. Latest `widget.html` and `metrics.json` live under Application Support/Converse/Agents/<session-id>/. Generated art also uses ordinary inline-image transport. Discord is off until enabled and suppresses mentions. Agent Setup includes **Test key** for Meta, **Test GitHub** for token/repository/traffic access, and **Test Discord** for Discord. Tests use an entered replacement or the saved credential without saving changes. Discord posts one labeled test message with no session content or mentions; GitHub tests are read-only.

On Mac, agents show a yellow caution badge in the sidebar whenever attention is requested, including while displayed in a pane. Hover puts that message first. The beachball means a check or prompt is actively running; a green loop symbol means periodic checks are enabled and waiting. The agent footer shows Thinking/Idle, loop state, interval, next check, and per-loop turn limit. **Agent actions → Loop controls…** opens controls for automatic checks, interval, maximum turns per loop, and scoreboard refresh every N scheduled loops (default 1). Enabling the loop schedules its first check one interval later. **Run once** queues a check and forces a scoreboard refresh without enabling the periodic loop. Turning the loop off leaves a current run alone. Between scoreboard refreshes, scheduled checks still produce conversation reports using timestamped cached repository metrics. Held queues still require **Resume queue**. Watched-session summaries include timestamped host activity so an active session is distinguished from historical unresolved bugs.

### Images and formatting in Discord

Enable **Share scoreboard and mood image on Discord requests** in the agent's home setup to allow channel posters to request those images with a real bot mention: `@Converse show the scoreboard` or `@Converse show the current image`. The host uploads a PNG attachment containing only the saved mood art and, for a scoreboard, its measured cards and observation time. This does not expose transcripts, working notes or arbitrary files. Sharing defaults off and is checked again before delivery. Images use the same durable reply/nonce handling as text; an uncertain upload is never automatically repeated. The bot also needs **Attach Files** in the channel.

Discord replies retain supported Markdown; pipe tables become labelled records because Discord does not render GFM tables. The iPad transcript now renders block headings, lists and code, with tables presented as wrapping labelled records rather than raw Markdown.

Agent schedules repeat until paused. **Maximum turns per loop** bounds each activation, rather than counting down future scheduled checks. The current engine completes one model response per activation (up to four hosted searches and 8,192 output tokens); it does not automatically continue itself. Existing exhausted agents remain paused, but can be enabled again without replenishing a lifetime counter. iPad Setup has explicit Save/Cancel and Save-and-run controls. Clipboard image paste and the Photos picker have separate buttons. On iPad, Command-V and the standard Paste menu also accept image-only clipboards when the session is editable.

On iPad, the system **Paste** button accepts images from other apps; **Photos** opens the photo library. Startup and Take show the transcript tail unless you deliberately selected text or positioned an editing cursor. Scrolling up pauses following indefinitely; idle refreshes and timers never pull you back down. Pasted images are revealed automatically on Mac and iPad. Agent Setup reports failed saves in an alert and returns the home’s saved settings. Starting a loop or mention does not invalidate an open settings form.

## Jolly (Mac)

Choose **Converse → Jolly…** to choose the local agents that Jolly may address and leave an explicit message for the phone. Jolly uses the existing connector hostname and bearer authentication; its destination is now the Converse-owned bridge. Refresh the phone connector’s schema so it shows **Ask Converse**, then ask Jolly to list agents and address one by exact name or ID. With multiple possible destinations it asks which one; it never broadcasts or guesses.

The bridge on loopback port 4691 persists requests with stable IDs. Retrying the same request ID returns the same status/result; changing its contents is rejected. Replies taking more than 20 seconds return pending with a pollable request ID. Agents use their saved per-activation turn limits and preserve typed drafts. Busy/paused agents report that condition without interrupting. An app restart marks interrupted work uncertain rather than automatically repeating it. Only agents on this bridge’s home Mac are directly listed; their existing authorized switchboard scope can include their group.

Converse must be open to answer. The bridge stays available to say that the app is offline and to serve already-saved replies. It has no alternate backend. Retired connector operations return an explicit error. The bridge installer is an explicit operator step; building or running Converse does not reconfigure system services.

The outbox contains only explicitly entered messages (up to 500 characters). Jolly reads **/v1/inbox** without consuming messages, then acknowledges received IDs through **/v1/inbox/ack**. Converse does not poll the phone inbox. This remains a pull mechanism, not a push into Muse conversations. Requests, replies and the outbox stay under Application Support/Converse/Jolly; credentials stay outside the app bundle and source tree.

## Export transcripts

Remote transcript export from the Mac **File → Export…** lists local and remote sessions, labeled by home. Updated homes provide the complete submitted transcript and images through a read-only export; no display ownership is taken and drafts remain private. If a home is offline, too old, or the transcript changes during paging, export reports the problem rather than writing an incomplete file.


Choose **File → Export…**. In the standard Mac save dialog, check one, several, or all sessions; choose **Interleaved by time** or **One after the other**, **Prompts**, **Responses**, or **Both**, and whether to include line numbers. Local transcripts are captured when the dialog opens; remote transcripts are read when you export; drafts, tool activity, and account configuration are excluded.

Choose **HTML** for one portable file with formatted headings, emphasis, code, tables, links, and embedded attachment images. Open it in a browser to read or print. Choose **Text** for a UTF-8 `.txt` file preserving original Markdown and listing attached image filenames; line numbers are disabled for Text. New messages retain their creation times. Older messages without recorded timestamps are labeled **Time unavailable** and appear after timed messages in their original session order when interleaved.

## Local slash commands

These are handled by Converse without sending a prompt or spending model tokens:

| Command | Behavior |
| --- | --- |
| `/model`, `/models` | Read model, effort, access and their sources |
| `/usage` | Read last-turn and session-total token usage, plus any observed account quota |
| `/status` | Refresh and display all session details |
| `/stop` | Interrupt the current turn |
| `/login` | Choose an existing login, create a new login, or sign in again; uses the same picker as session creation |
| `/clear` | Mac: hide the current transcript without resetting model context or teaching |
| `/unclear` | Mac: restore the hidden transcript |
| `/help` | Show local command help |

Muse queries run automatically when a conversation is opened. Read-only metadata commands do not change model, permissions or effort. `/usage` additionally invokes the built-in CLI usage view to fetch subscription quota; it never submits a model request. The status pickers, by contrast, explicitly update the selected conversation's model, effort or access profile. Muse uses its durable setters. Codex and Claude save per-conversation overrides and pass them on each subsequent turn, including resumed turns. CLI defaults are labeled when the CLI does not report a resolved effort. Claude and Codex also refresh their model catalogs and account/session metadata without submitting a model prompt. These commands do not implement the full CLI slash-command menus. Unrecognized commands remain ordinary prompts.

## Model, effort and access options

On Mac, catalogs come from the installed CLI and selected login. Windows and Linux currently discover Codex catalogs; their other providers use built-in model options. Codex includes hidden catalog rows and follows pagination; availability still depends on the account. Effort menus use each model’s reported supported levels. Custom model/effort entries remain available.

| Assistant | Access controls |
| --- | --- |
| Claude | Manual, Accept edits, Auto, Plan, Don’t ask (deny unapproved), Bypass permissions |
| Codex | Read-only, Workspace write, Full access; independent approval policy: CLI default, Never, On request, Untrusted |
| Muse | The host’s available permission profiles; current built-ins include read-only, ask-me, auto-review, unrestricted |

**Claude’s Don’t ask denies actions needing approval. Bypass permissions is the separate mode for skipping permission checks.** Converse passes the selected mode to every turn, including resumed turns. CLI/organization restrictions still apply. Claude and Codex run headlessly here, so terminal approval dialogs are not embedded. Muse’s host supplies native approval choices. Claude/Codex model, effort and access menus can return to CLI defaults.

For a session running on another device, including a headless Linux home, use the **⋯ Session settings** menu in its pane. **Model**, **Effort**, and **Restrictions** remain reachable in narrow panes on Mac, iPad, and Windows. Codex homes query their installed CLI for model names and model-specific effort levels, including on Linux and Windows. Choose **Custom model…** if discovery is unavailable or to enter a provider model ID. Changes are sent to and saved by the home; Codex and Claude use them on the next turn. The viewer must hold the session’s display lease.

**X** also closes remote sessions from any member of the group, without taking the session first. Confirming stops work on the home, removes the session from every viewer, and preserves its transcript and draft in the home’s `Deleted Sessions` recovery folder. A home running an older release must be updated before remote X is enabled.

Sources checked against the installed CLI help and schemas: [Claude permission modes](https://code.claude.com/docs/en/permission-modes), [Codex command reference](https://learn.chatgpt.com/docs/developer-commands), and Muse’s offline MSP schema (`muse schema generate-json-schema`). Muse’s reported effort variants and profile availability take precedence over its broader CLI vocabulary.

## Accounts

Settings → Models & sessions groups sessions and saved logins under their model. Click the login identity in the conversation footer, type **/login**, or use **Login…** in Settings. Choosing an existing login binds it to this session without changing that login or any other session. Authenticating another account always stages a fresh isolated login for the selected session. The session keeps its ID, history, draft, attachments and retained CLI transcript; only that conversation’s transcript is copied to the selected CLI store, never credentials or other conversations. Missing or conflicting context leaves the binding unchanged with an error. Closing windows keeps active work alive.

Default accounts use the standard CLI stores (`~/.codex` and `~/.claude`); Muse reuses its current CLI sign-in. Add more named Codex or Claude accounts in Settings. Each additional account gets a separate configuration directory under Converse’s local data folder. Use **Sign in…** for each account, complete the official CLI flow in Terminal/browser, then return to Converse. Claude desktop accounts are separate from Claude Code accounts. No account names, credentials or configuration are bundled with the app.

Click a conversation’s login identity or type **/login** to open its login picker. **Sign in to another account for this session** opens authentication in a fresh private CLI configuration folder. Finish in Terminal/browser, then return to Converse and retry your message or resume its held queue. Authentication cannot overwrite a saved login used by another session. Signing into one session does not block or pause peers. A conversation’s title does not select its login.

Claude’s normal installed CLI login is kept distinct from an explicit `CLAUDE_CONFIG_DIR` store, even when both refer to `~/.claude`: their macOS authentication namespaces can differ. Both are selectable without copying credentials or requiring another sign-in when they are already authenticated.

Additional Codex and Claude accounts can be added, renamed, or pointed at existing CLI stores. New conversations take a snapshot of the account path. Changes in Settings leave existing conversations on their original paths. Account-directory overrides are applied after shell startup, and inherited API/OAuth token environment overrides are removed for explicitly selected accounts so they cannot silently use another account. The CLIs retain responsibility for authentication, keychain storage and permissions.

Each distributed preview advances its visible patch version and build number (for example, **0.5.1 (26)** → **0.5.2 (27)**). Check **Converse → About Converse** on Mac or the **…** menu on iPad to identify the installed update. `VERSION.json` is the shared version source for both apps.

## Build and run

This preview is built and tested on an Apple Silicon Mac using Apple's Command Line Tools and the installed macOS SDK, targeting macOS 14. No third-party libraries or Xcode project are required.

```sh
./build.sh
open .build/Converse.app
```

`./release.sh` builds both CPU architectures, signs with Developer ID, notarizes with Apple, staples the ticket, checks Gatekeeper, and packages the downloadable ZIP under `.build/release/`. It requires a valid **Developer ID Application** identity and a Keychain notarization profile named `ConverseNotary` (override with `CONVERSE_NOTARY_PROFILE`). See [signed releases](docs/signed-releases.md) for the one-time setup and release checks. A local ad-hoc build cannot pass the release gates.

**Building or publishing does not update an installed copy.** Run `./install.sh` to install the verified build into `~/Applications/Converse.app`, or pass the exact app path you normally launch: `./install.sh /path/to/Converse.app`. For an installation outside protected folders, if that copy is running, installation waits for it to quit, retains the previous bundle as a backup, and replaces the app at that same path. Running copies inside Documents, Desktop or Downloads cannot be reliably updated by the background helper because macOS gives it a different privacy identity; the installer rejects that queue request and recommends installing into `~/Applications/Converse.app`. Quit the old app and open the new Applications copy explicitly; an old Dock shortcut may still target the old copy. Wait a few seconds after quitting before reopening. Conversations and credentials are not touched. The script prints a status-file path; check it for `INSTALLED` before claiming the installed copy is current. This is a local developer installation helper, not an automatic release updater.

Keep your checkout outside Documents, Desktop and Downloads (for example, `~/Developer/Converse`) to avoid macOS protected-folder prompts during development. Builds go into `.build`; use `CONVERSE_APP_OUTPUT=/path/to/Converse.app` to choose another destination. The build refuses to replace a running app because changing an ad-hoc signature can invalidate its privacy permissions.

The build derives app icons from the supplied [logo master](Resources/Branding/Converse-Logo.jpeg) and creates `.build/Converse.app`. When exactly one valid Developer ID Application identity is installed, builds use it automatically with hardened runtime and a secure timestamp. If several are installed, select one with `CONVERSE_SIGN_IDENTITY` (certificate SHA-1 or full name). Without a Developer ID identity, local builds use an ad-hoc signature; `CONVERSE_SIGN_IDENTITY=-` explicitly requests one. Local builds are not automatically notarized. Generated app and icon bundles are excluded from Git; their source is included.

Install and authenticate the assistant CLIs separately. Configure each entry with the matching adapter; Converse uses Muse’s interactive MSP host and the other adapters’ headless modes. Command lines run through your login shell. Homebrew and `~/.local/bin` are included in the executable search path.

## Check

See the [testing strategy](docs/testing.md) for the coverage layers, platform commands, release checks and remaining gaps.

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

## Preview limitations

Muse approval and question dialogs are supported. Approval buttons use the server’s exact labels, choice IDs, scope, and current requirement token. Questions support single choices, multiple choices, free text, and cancellation. Requests stay visible until Muse settles them; errors and stale decisions are shown and refreshed. Auto-review policy may resolve an action without asking you. The status line distinguishes approval waits, automatic review, retries, foreground completion with background checks, and terminal completion; waiting on your input shows no working spinner. Closing a window keeps the host alive.

Claude and Codex still use headless adapters and do not yet support interactive approval/question dialogs. Authentication opens the CLI in Terminal; full CLI slash-command menus are not embedded. Explicit access and approval selections apply to each turn, including resumes. Codex exposes named **Approve for me** and **Full access** presets. Approve for me sets workspace-write, on-request, and the auto-review reviewer together; Full access sets danger-full-access and never together. Ask for approval requires the not-yet-integrated interactive app-server path and is not offered as a working mode. The obsolete `untrusted` choice is removed. Existing custom CLI configurations are preserved until you select a preset. Some tools provide their response only at turn completion.

The downloadable release is the Mac app. The [iPad viewer/controller](iPad/README.md) is distributed through TestFlight. Windows has a separate native implementation sharing the same C# core: sidebar/panes, groups, switchboard messaging, agents, and a Set up Linux deployment manager. The Linux home is newer and still maturing: its deployment, admin, and recovery behavior is covered by automated tests and VM deployment, with interactive acceptance (live pairing walks, provider turns, recovery walkthroughs) still being exercised. Native context compaction and Discord bot execution currently require a Mac home; matching build numbers do not imply complete feature parity.

See [README.txt](README.txt) for additional usage notes. App and adapter implementation is in [Sources/main.swift](Sources/main.swift); platform icons are generated from the shared logo master by [Sources/Icon.swift](Sources/Icon.swift).

Read-only Muse status probing and retained usage aggregation are implemented in [Sources/MuseStatus.swift](Sources/MuseStatus.swift). The status probe has an eight-second timeout and exposes failures rather than fabricating values. The CLI quota bridge is in [Sources/MuseQuota.swift](Sources/MuseQuota.swift), has a fifteen-second timeout, and keeps terminal escape sequences out of the UI.

The interactive Muse transport and request controls are in [Sources/MuseConnection.swift](Sources/MuseConnection.swift). Its wire shapes are checked against the installed CLI’s offline `muse schema generate-ts` export. `Tests/msp_fixture.py` checks the bidirectional approval/question exchange without model requests. Pasted images are saved as PNG; Muse receives both image content and the filename, while Claude/Codex receive the attachment paths through their adapters.

Provider protocol references: [Codex app server](https://learn.chatgpt.com/docs/app-server) documents catalog and retained thread reads; [Claude Code environment variables](https://code.claude.com/docs/en/env-vars) documents separate `CLAUDE_CONFIG_DIR` stores. Installed CLI help and locally exported Codex schemas are the authority for accepted launch arguments. Provider fixtures reject any status query that attempts to resume a session or submit a prompt.

## Feedback

Questions and ideas are welcome in [Discussions](https://github.com/richardkaufmann/converse/discussions). Please use the [bug-report form](https://github.com/richardkaufmann/converse/issues/new/choose) for problems. Pull requests are by invitation; see [contribution guidelines](CONTRIBUTING.md).

## License

Copyright 2026 Richard Kaufmann. Converse-owned code is licensed under the [GNU General Public License, version 3 or (at your option) any later version](LICENSE), with the narrow SAM codec permission in [LICENSING.md](LICENSING.md). That notice defines the grant and third-party scope. GPL permits commercial copies and forks subject to its terms; earlier Apache-licensed versions retain their existing grants.

The SAM mask codec in [Sources/SAMMask.swift](Sources/SAMMask.swift) is adapted from Meta’s parser and is distributed under the [SAM License](Resources/ThirdParty/SAM-LICENSE.txt), included with the Mac and iOS apps. The additional permission allows combining that codec with Converse; it does not relicense Meta’s code. Provider-logo notices are in [Resources/ProviderLogos](Resources/ProviderLogos/).
