<p align="center">
  <img src="docs/converse-icon.png" width="160" alt="Converse robot logo">
</p>

# Converse

Converse is one app for multiple, simultaneous conversations with the providers **Muse, Claude Code, and Codex**. From one pane of glass you can orchestrate projects across multiple systems (Mac, Linux, Windows) with a set of agents overseeing progress.

**Watch the 3-minute demo:** [on YouTube](https://youtu.be/bSWs7vsioNI) (or [download the MP4](https://github.com/richardkaufmann/converse/releases/download/v0.6.3/Converse-hackathon-demo.mp4))

**Try it:** [download the Mac release](https://github.com/richardkaufmann/converse/releases/latest) or [build from source](#build-and-run), open Converse, and pick **Meta Muse**, **OpenAI Codex** or **Anthropic Claude** when App Support asks. After that provider's own sign-in you have a coding session, an agent and a Parking Lot ready to go. No Meta API key is needed to start; it only adds Muse Spark API agents, scoreboard art, voice and the image tools. [First launch](#first-launch) walks through it.

**Hackathon:** The tag `pre-hackathon` marks the code before the hackathon window opened (last commit before Oct 26, 2026, 9:00 AM PT), and `hackathon-submit` marks the submitted version; `git diff pre-hackathon hackathon-submit` shows everything built during the hackathon.

Its standout features:

1. **[It’s multi-session.](#keep-several-sessions-visible)** You can have many sessions open simultaneously, and have up to three of them up, side by side, in each of the app’s desktop windows.
2. **[It’s multi-account.](#accounts)** Each session is logged into its own provider account—e.g. a user can be logged into two different Muse accounts, three different Codex accounts, etc. In practice this is useful to balance token budgets, but also to get different perspectives on development efforts.
3. **[It’s multi-provider.](#set-up-your-first-coding-session)** Meta, OpenAI, Anthropic can be mixed and matched as desired.
4. **[It’s multi-system.](#download)** Sessions can run on Mac, Windows and Linux. The app UI runs on Mac, Windows, iPads and iPhones.
5. **[It has Parking Lots.](#parking-lots)** Organize ideas and future prompts in an outline. Sessions can take ideas from, and make changes to, Parking Lots. Users can talk to the Parking Lot agent to bounce off ideas, direct edits, and listen to summaries.
6. **[It’s distributed.](#connect-your-devices-into-a-group)** Systems running Converse can join peer-to-peer **Groups**. Each app instance can “take” (display) sessions from any system in the Group. Groups are persistent. Systems rejoin when they come back online, including iPhones and iPads, as long as they can reach the other systems.
7. **[It hosts agent sessions.](#set-up-your-first-agent)** These sessions have initiative and can start periodically or via an external stimulus.
8. **[It’s chatty.](#messaging-between-sessions)** Sessions can talk to each other. “Tell” sends a message; “Ask” expects a response. Agents can supervise groups of sessions, and Converse can “force inject” prompts to break logjams. Agents also have rich tooling to assess progress toward shared goals.
9. **[It talks to the outside world.](#give-the-agent-evidence-for-its-objective)** Agents interact with GitHub (to track PRs, issues, updates), [Discord](#connect-discord-on-a-mac) (to send and receive messages), [Home Assistant](#give-the-agent-evidence-for-its-objective) (to read selected device states), and [Meta’s Muse mobile app](#jolly-mac) (“Jolly” can talk to agents and get updates). They can do outbound searches and assess sentiment too.
10. **[It has polish.](#use)** Images can be pasted into sessions—and even analyzed with a right click using Meta’s segmentation toolkit—allowing only pertinent content to be passed to session prompts. Responses’ Markdown output is converted to tables, headings, etc., providing a pleasing experience. Right-click to copy entire prompts and responses, or export traffic across sessions and systems in a consolidated, well-formatted document. Quit and restart the app: your sessions survive!
11. **[You can enter into spoken conversations with your agent.](#voice-on-mac)**
12. **It has an “opinionated” security posture.** The basic thesis: if you can reach another system’s Converse port (normally TCP 48721), you can ask to join its Group. Messages are encrypted with ChaCha20-Poly1305, and both sides approve pairing—it feels like pairing a phone to a car! Once paired, you’re trusting that system with your sessions. You've been warned! Read the [security section](#security-and-privacy) to make sure this app is for you!

These features combine in interesting ways. There’s a built-in support agent that knows this README, and can help you avoid fiddly UIs to configure providers, agents, etc. You can talk with this support agent via Discord or Muse Jolly. And it checks daily for bugs and version updates of the app! This uses a teaching prompt injected into a normal Converse agent.

You can build an app that is multi-system. One session on a Mac, for example, can “tell” a Windows session to finish producing a Windows version of the app and install it. That’s how we build Converse!

You can build Linux apps and services on a Mac or PC without multiple windows, or having to deal with complex different UIs. Since Linux is headless, you log into it to set up Converse and its providers. From there you can start sessions on those providers from your Mac or PC.

The cross-system session support also greatly eases development. Ask a session to generate an image, paste it into another session running on a different system. It just works!

The rest of this README walks through installing Converse, and then using it. A friendly suggestion: AI wrote what follows (it’s kind of grim, to be honest). Let AI read the details! You tell App Support what you want to do; it can work through the instructions with you. Install the app on a Mac or Windows PC, and the support agent will walk you through provisioning your first provider on that system. From there you can just chat and have it help set up multiple systems (including headless Linux), agents, whatever. It’ll ask for what it needs. You can give feedback too: “File a bug about blah blah blah” gets a report ready for GitHub. You review it and send it. No Discord account needed.

Enjoy.

This guide is also bundled as searchable, offline **Converse Help**: open **Help → Converse Help** on desktop, or **Help** in the mobile menu. The [security and privacy section](#security-and-privacy) explains data sharing and key storage.

Please file bugs and suggestions through the support agent. Your agent will talk to Converse's agents; your input will be used to fix bugs and add great new features.

## Download

**On Mac:** [download the latest Mac preview](https://github.com/richardkaufmann/converse/releases/latest), unzip it, drag **Converse.app** into **Applications**, and open it. Current release downloads are Developer ID signed and notarized by Apple. The universal app targets macOS 14 or later on Apple Silicon and Intel; direct hardware testing has been on Apple Silicon.

**One thing keeps running after you quit, if you set up Jolly.** Connecting [Jolly](#jolly-mac) installs a small background bridge (the launchd agent `local.converse.jolly.bridge`), and it stays up after **⌘Q** so the Muse phone app can still reach your Mac and hear whether Converse is available. Without Jolly, Converse installs no background service.

**On Windows:** use a Windows preview supplied by the project, or build the Windows app from source. There is not yet a general-purpose Windows installer. The [Windows build instructions](windows/README.md#build-and-test-on-the-windows-box) are for developers, not a required step for someone who already has a preview.

**On iPhone or iPad:** There is no public testing link at present. If you have an Apple Developer account, you can build from the source with a Mac coding session. I haven't figured out a real distribution channel for those not willing to cough up $100/year for a developer account.

Coding sessions have scrubbed this repo for security issues, but please do read those [security posture notes](#security-and-privacy) in this README. Better yet, have your agent pound away on it and have it reach out with issues...

## First launch

You do not need Discord to use App Support, set up Converse or report a bug. App Support lives right in Converse. Discord and Jolly are optional ways to reach agents later. See [Set up Discord, Jolly, GitHub and Home Assistant](#set-up-discord-jolly-github-and-home-assistant) to connect your own accounts and services.


On a brand-new Mac installation, Converse opens with four things in the left panel: **Converse App Support**, a **Parking Lot**, **Coding** and an **Agent**. Only App Support is up. It says hello and asks one question: which provider should lead? Pick **Meta Muse**, **OpenAI Codex** or **Anthropic Claude**. A provider is the service behind the model; its account and usage charges are separate from Converse.

1. **Click a provider.** Converse sets everything up to use it and renames the sessions to match, for example **Claude Coding** and **Claude Agent**. The Parking Lot is already linked to both.
2. **Press Return.** App Support has typed `/login` for you. Return opens that provider's normal login (`claude auth login`, `codex login` or `muse login`) in Terminal and your browser. Finish there and come back. Already signed in? Click **I’m already signed in** instead.
3. **Wait for one short answer.** Converse asks the model for a single reply to prove the login works (this may use a little quota), then App Support opens your coding session beside it in a second pane and explains what it can help with, including the **1 2 3** icons that put any session in the first, second or third pane.
4. **Start in your coding session.** It asks: *What shall we build today? You can also ask me to read the Parking Lot and react to it and update it.* The Parking Lot starts with **What Are We Building** and one idea to react to. Your agent has a greeting too; right-click its name for **Agent Setup**, **Run once**, **Show scoreboard** and more. It starts on, watching your coding session (*Monitor the health of the Claude Coding session.*), checks hourly with **Auto pacing** on, and makes its first check an hour after you sign in. With a saved Meta key it also draws mood art that matches how the project is going.

Not ready to choose? Click **Decide later**. Everything else keeps working, and **Choose a provider…** brings the question back. If a provider's button is greyed out, its command-line tool isn't installed yet: use **How to install** ([Install a provider CLI](#install-a-provider-cli)), then **Check again**. Do not put passwords, API keys or login codes into a conversation.

**Picking Meta Muse?** Your Muse subscription sign-in is enough for coding sessions, App Support and agents. A **Meta Model API key** is optional: it is needed only for Muse Spark API agents, Muse Image scoreboard art, voice transcription and the image tools. To add one, [get it on Meta's developer site](https://dev.meta.ai/docs/models) and paste it into the masked field App Support shows (or later into Agent Setup). If a key is already saved, Converse doesn't ask again.

**Keys stay in your Keychain.** Converse saves API keys and tokens in the macOS Keychain and logins stay with each provider's own tool. Nothing secret goes into a conversation, a settings file or this repository, so there is nothing to commit and no `.env` file to fill in.

**What works without a Meta key:** coding sessions and App Support with any of the three providers (including a Muse sign-in), agents running on those logins, messages between sessions through the [switchboard](#messaging-between-sessions), [Parking Lots](#parking-lots) and [Groups](#connect-your-devices-into-a-group). The key adds Muse Spark API agents, scoreboard art, voice and the image tools.

For a problem involving another Group system, App Support can find its support agent and ask for a scoped, read-only health report. It uses live session IDs, reports unavailable peers, and does not turn a peer message into permission to change settings.

Ask App Support to “open another coding session with my selected provider” and it creates and displays one, using your saved login. Ask how to do it and it explains the steps. It can also read installed Help, inspect safe settings, and open setup controls. It can perform supported setup actions you request and report their result. You still complete provider sign-in and enter secrets yourself. A saved setting is not proof that an external service is connected.

Ask App Support to set up an agent, a Parking Lot and who it can talk to, and it does it. For example: “Create a Video Steward agent on Claude, give it a new Video Parking Lot, let it talk to Scraper and Codex Scraper Auditor, and have it ask Scraper for the GitHub details.” App Support creates the lot and the agent, grants access to exactly the sessions and lot you named, queues that first question for the new agent, and tells you what changed, with names and IDs. If a name matches more than one session, it asks which one you meant. The new agent's automatic loop stays paused unless you ask for it to run. Signing in to a provider and entering keys are still yours to do.

**Existing installations:** upgrading preserves your sessions and does not rerun onboarding. On Windows, choose **Help → Converse App Support…** to open or set up your support agent. Existing sessions keep their logins. New sessions and agents default to the provider login verified during setup; you can choose another login in setup. Demo and the normal app keep separate credentials. On either desktop, App Support can use any enabled provider; it does not require Meta or Discord.

**Recording a fresh start?** In the separate Mac or Windows **Converse Demo** app, choose **Converse → Reset Demo… → Reset and Quit**. Reopen Demo to go through setup again. This clears Demo’s sessions, logins, tokens and pairing, keeping a local backup of its files. Your normal app and project files stay untouched.

### Report a bug

Tell App Support what went wrong and ask it to file a bug. It prepares a title and description and opens a report you can edit. You can also choose **Help → Report a Bug on GitHub…** on desktop, or **Report a Bug on GitHub…** in the mobile menu.

**Easiest: no token.** Converse prepares the report; click **Continue on GitHub…** to open a prefilled issue (or **Copy description** and paste it into a new issue), sign in to GitHub, and submit. Mobile opens GitHub’s report form directly.

**To file directly from Converse, save a GitHub token once.** Paste it into the masked **GitHub token** field in the report window or Agent Setup, then save; Converse keeps it with your other credentials. After that, review your report and click **Submit report**, and Converse files it and gives you the issue link. The token must be able to create issues on a public repository. For most people that’s a **classic token with only the `public_repo` scope**: fine-grained tokens can’t create issues on a repository you don’t own unless you’re a collaborator (if you are one, a fine-grained token limited to `richardkaufmann/converse` with **Issues: read and write** is the smaller choice). Read-only access isn’t enough. [GitHub’s token guide](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) explains creation and expiry.

Reports go to `richardkaufmann/converse`. A report window or browser draft is not yet a filed issue. If sending fails or times out, check the issue list before trying again: Converse does not automatically repost. For a description too long for a browser link, use **Copy description** and paste it into a new issue on GitHub.

**Help us reproduce it without sharing your life.** In the desktop report window, **Add diagnostic summary** adds app/OS versions and Group/session counts. It leaves out Group and device names, IDs, addresses, file paths and conversations. **Remove likely secrets** locally removes common token/key patterns, email addresses, home paths and IPv4 addresses from the draft. This is a useful first pass, not a guarantee of anonymity: read the whole report, edit or remove anything private, then approve it with **Submit report**. The report may become public. An agent can help summarize symptoms, using Host A/Host B instead of real names; do not paste keys or raw logs into a model just to ask it to scrub them.

Only the report text you review is included. Logs, screenshots, attachments and other conversations are not added automatically. If you use the browser route, its prefilled report link contains that text and may appear in browser history. Keep secrets and unrelated private information out of reports. Saved GitHub credentials stay in the Mac Keychain or Windows Credential Manager; they are never given to the model or placed in a report. Discord is not involved.

Copying a selected passage on Mac, iPhone or iPad preserves link destinations in plain-text paste—for example, `Cursor Agent (https://cursor.com/docs/agent/overview)`. Copying a whole response also preserves its Markdown links.

## Install a provider CLI

Converse drives each provider's own command-line tool (*CLI*). You need only one. On a Mac:

- **Anthropic Claude:** `curl -fsSL https://claude.ai/install.sh | bash` ([Claude Code setup](https://code.claude.com/docs/en/setup))
- **OpenAI Codex:** `npm install -g @openai/codex` or `brew install --cask codex` ([Codex CLI](https://developers.openai.com/codex/cli/))
- **Meta Muse:** `mkdir -p ~/.local/bin && curl -fsSL https://api.meta.ai/muse-launcher.sh -o ~/.local/bin/muse && chmod +x ~/.local/bin/muse`

Converse looks in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin` and your login shell's `PATH`. After installing, click **Check again** in App Support.

## Set up your first coding session

A **coding session** connects a conversation to a project folder on your computer. The assistant can inspect or change files there according to the permissions you select. App Support is for help with Converse; create a separate session for your project.

1. Click **+** beside **this device** in the left sidebar and choose Muse, Claude or Codex.
2. Give the session a useful name, such as “Website — Claude,” and select your project folder. Choose the login you already set up, or **New login…** if you want a separate account.
3. Create the session. Creation itself sends no prompt. Use **1** beside its name to display it in the first conversation pane if it is not already visible.
4. Check the footer's **model**, **effort** and **access** settings. Model selects which model answers; effort controls supported reasoning effort; access controls what its tools may do. Begin with restricted access while you learn. Available choices depend on the provider and account.
5. Type: “Read this project and explain how it is organized. Don't change any files yet.” Press **Return** to send. On Mac, **Command-Return** or **Shift-Return** adds a new line instead.
6. Confirm that the response describes the intended project. Then ask for a small change, review it, and continue in the same session.

Muse can show approval questions in the pane. Claude and Codex run without their normal terminal interface here, so their full terminal approval dialogs are not embedded. If a task is blocked by permissions, review the access setting rather than assuming an approval window will appear. When Claude’s access setting blocks a tool, Converse adds a notice to the session naming what was blocked, such as a file path or command, so you can change Access in the footer and send again.

## Use

### Read, type and interrupt

Your editable draft is **blue** at the bottom of the conversation. Sent prompts become *italic* in the normal text color; responses render headings, lists, code and tables. A spinning rainbow indicator means work is in progress. A waiting approval needs your attention; **Stop** interrupts an active turn.

You can type the next request while the assistant works. Sending it adds it to a **queue** (the list of messages waiting to run, shown above the transcript). **Inject now** interrupts the current turn and sends that queued message next. **Inject all** sends the queue together in order. Stop also pauses the queue; use **Resume queue** when ready. Drafts, queued messages and attachments survive relaunch. Quitting preserves the conversation; new work needs its home app or Linux service to be running.

On Mac, transcripts follow new output automatically. Scrolling up pauses this for 30 seconds after your last interaction; clicking into the transcript holds your place until you choose **Jump to latest** or return to the draft. An active Find bar also holds your place. Resizing a window balances its session panes and returns transcripts to the bottom. Right-click a message to copy the whole prompt or response, or select just the text you want.

On Mac, **Command-F** (Edit → Find) searches the current transcript without changing any text. There is no Replace. Use the Find bar’s previous/next buttons, **Command-G** / **Shift-Command-G**, and its close control.

On Mac, agent responses use the same message numbers and timestamp hovers as sessions. Hover over a message number or response text to see its recorded time; responses taking ten seconds or more also show a delay hint.

### Parking Lots

Parking Lots are great ways to work on ideas or save (park) them for later injection. They're persistent, and letting agents and sessions see and edit them is a great way to track and direct development. Integration with Jira and other tracking systems is an idea for future work, not something the app does yet.

Keep ideas, prompts and bugs in named **Parking Lots**, alongside the sessions under their home device. Click the grey starter lot, or choose **Parking Lots…** or **File → New → Parking Lot…** to create another. Right-click a lot in the sidebar to rename or delete it. **P**, **1**, **2** and **3** work just as they do for conversations. **X** deletes the lot after confirmation; a recovery copy stays on its home device.

On Mac, Return creates a separate item, even at the end of a heading; Backspace on an empty item removes it. Shift-Return creates a heading below; ⌘Return adds a line within the current entry. There is always a **New item…** input at the end of each open section and **New Heading…** below the last section. Paste an image into an item with **⌘V** or right-click **Paste** to attach it. Images follow their item when reordered or structurally cut/copied, and Undo restores changes. Right-click an item to remove its images. **File → Export…** includes active Parking Lots; HTML embeds their images, Text lists image filenames, and the Converse format carries the lot itself so it can be imported as a new lot. Headings are dark blue in light mode and light blue in dark mode. Right-click a heading or item to **Mark Done** (grey, struck through) or **Mark Not Done**. Done items stay editable and in place; marking a heading does not change its children. Sessions and authorized agents can read and update the `done` attribute, and Undo restores the previous state. Click a comment-count bubble to read its comments; hovering shows the count. Notes save automatically. Right-click a heading or item for **Cut Heading**, **Copy Heading**, **Cut Item** or **Copy Item**. To file an item somewhere else, right-click it and choose **Move ➞** a heading at the bottom of the menu: it goes to the end of that section, along with anything nested under it. That's the quick way to promote an idea from Future work to Things To Implement Now. Cutting a heading takes its items with it. Paste those words straight into a conversation when you are ready to act on them. Web links (`https://…`) and local file paths (`/Users/…` or `~/…`) turn blue and underlined as you type the space after them. A named link (`[label](https://…)` or `[label](file:///…)`) shows only its label and edits as one piece: Backspace right after it removes the whole link, and ⌘Z brings it back. Click a web link to open it in your browser, or a file link to reveal it in Finder. Right-click a link to edit, remove or copy it; Option-click a label to change its text in place. Sessions can add links the same way. Drop a file from Finder into an item and it becomes a link to that file, even when its name has spaces; press ⌘Z to get the plain path instead.

On Mac, drag across text to select several items or headings, then copy, cut or paste normally. **Tab / Shift-Tab** indent or outdent the selected items; outdenting keeps the item in place and adopts its following siblings as children. **Reorder** shows drag handles; moving a heading moves its items too. Each heading or item with children has its own disclosure arrow. Opening a parent preserves the collapse choices underneath it. **Collapse All** shows just headings; **Expand All** opens every level.

Color tags give items a named red, orange, yellow, green, blue or purple tag. On Mac, use the color circles at the top of the entry’s context menu; on mobile, use its **…** menu. Clear removes the tag. Tags survive export/import and appear in assistant reads. They do not inherit down the outline, and unresolved color counts exclude Done items and headings.

Right-click a Parking Lot on its Mac home and choose **Linked Sessions…** to select the sessions and agents it is for, including conversations on other devices in the current Group. Then ask a taught session or agent, “Which Parking Lots are linked to me?” A conversation can be linked to several lots, and a lot to several conversations. Names can change without breaking links. Unavailable sessions stay listed in the picker so you can remove old links; they are not reassigned by name. Links do not send messages, wake agents or grant access. An agent still needs each lot selected in **Agent Setup**.

Links help conversations choose a relevant lot; an explicit name from you takes priority, and ambiguous choices should prompt a question. The discovery command is `{"command":"parking-lot-list","linkedOnly":true}` in a `converse` fence at the end of the reply. Omit `linkedOnly` to list all local and current-Group lots. Results identify the home, availability and access: read/edit commands still address lots on the executing Mac. iPhone/iPad can take and edit a Mac-hosted lot; Windows can take a read-only view when both devices run 141 or later. Remote agents can use a linked lot only through their separately authorized evidence. Configure links on the Mac home; iPhone and iPad can display the linked conversations hosted there or on Windows.

Ask any taught session, “Look at the Parking Lot and think about how you’d implement this feature.” It can list and read the Parking Lots on its home without a separate Parking Lot permission. A session can propose edits, but Converse shows you the changes for approval before saving. To skip that review for one lot, right-click it and turn off **Confirmation Required for Session Updates**; sessions’ edits to that lot then save immediately, and Undo still works. Agents keep their own Agent Setup access either way. When there are several lots, name the one you mean.

When you ask an agent to add an item, it should choose the most relevant existing section from its meaning—for example, broken behavior under Bugs and praise under Compliments—and tell you where it put it. You can name a section to override that choice. An unclear fit should prompt a question or a proposed new heading, rather than silently placing everything in the last section.

Group members may read your active lots. Agents need explicit access to each lot through their session access list: they act on their own initiative and can send content outside the Group—to a model provider, Discord, or another conversation. Agents you create start with no lot access; the first-run starter agent is set up with the starter lot. Ordinary sessions follow your live requests; an autonomous message cannot use that path to bypass an agent’s scope. Asking a session to read a lot shares that content with its selected provider, too. Stale edits are rejected if the notes change while the assistant is working.

**Talk…** starts a voice conversation about the lot on Mac. Choose a model, then discuss ideas or ask it to organize them. The helper can read this lot; select any other sessions it needs in Agent Setup. You review proposed changes before they are saved. Voice transcription uses your saved Meta key. You can also type in the helper’s conversation. Sessions, agents and this conversational helper can change the notes. And yes, there’s Undo: **⌘Z** reverses the latest content change, including a cut, reorder or assistant edit; **⇧⌘Z** redoes it. Each lot keeps its own undo history while the app is open.

On iPhone and iPad, **take and edit a Mac-hosted Parking Lot**. Use the current release on both devices. Taking parks the lot where it was previously displayed, including a Windows read-only view. Changes save back to the Mac; the pane distinguishes pending changes from the revision saved on home. **P** saves and parks the lot. The car beside its name and blue shoe match the Mac.

Use an entry’s **…** menu for Done, colors, nesting, moving, comments and images. Choose **Select**, then tap entries or drag through a visible range; selected entries share one **…** menu at the top. Right-click or long-press exposes the same actions, including extending a range through an entry. Batch changes have one Undo step, and structural moves/copy/cut keep nested children together. **Outline → Collapse All / Expand All** controls the whole tree. The toolbar also provides Undo/Redo and export.

Pinch with two fingers to resize text on iPhone or iPad. With a text cursor, it changes that pane; with no text cursor, it changes all panes. Sizes are remembered, and the caret and reading position stay in view. Ordinary scrolling remains separate. On Mac, use **View → Bigger / Smaller / Actual Size** (**⌘+ / ⌘− / ⌘0**).

While a phone or iPad holds the lot, session and agent proposals pause typing and drain pending saves before review. If the connection drops, editing pauses. A lot with no unconfirmed edits resumes automatically if nobody else took it. If there are unconfirmed changes, copy them for recovery before taking again; they are never silently replayed into a new owner’s version. Changes not yet saved on home live only in the mobile process, so keep it open until saving finishes.

iPhone and iPad do not host lots yet. Windows supports read-only viewing with take/park ownership, images and reconnect; creating and editing lots on Windows remains future work. Older Windows clients cannot open exclusive lots. Editing a lot on another Mac from the Mac viewer is also not included.

Undo covers saved changes. If a simultaneous edit is rejected because the lot has changed, it never enters the undo history. That can reject a whole paste, not just one keystroke; Undo cannot recover that rejected text.

### Settings and transcript history

On Mac, **Converse → Settings…** opens one window with **General**, **Jolly**, and **New User Experience / Reset** categories; it starts on General. Jolly includes agent access and a bordered message box. A message left there is delivered when Jolly checks its inbox; it is not pushed into an ongoing phone conversation.

General’s **Collapse Parking Lot data and outgoing messages** setting keeps large lot reads and switchboard payloads behind a disclosure arrow. Surrounding prose stays visible. Expanding or copying a message retains its complete content, and delivery status reflects actual receipts.

Choose a session in General to set its transcript limits: age in days and the number of recent prompts and responses. Leave either field blank for **None**. Defaults are no age limit and **1,000 messages**; a prompt and response count as two. Retained turns stay together, so the count may be slightly higher. Limits are checked once a minute while that session is idle, with no draft or pending work. They remove older messages from this Mac’s saved transcript, not attachments or the provider’s own history. Export first if you want an archive.

**New User Experience / Reset** opens the welcome walkthrough and provides **Reset on Quit**. The reset requires typing **YES** and can be cancelled before quitting. Quitting schedules the reset; the next launch backs up and clears this edition’s local profile and setup; ordinary updates preserve them. Production, Demo and TEST editions use separate profiles. Opening Converse Demo in TestFlight will not show your normal Converse Group.

### Text substitutions

On Mac, type a smiley or arrow followed by a space: `:-)` becomes 🙂, `--` becomes an em dash (—), `-->` becomes →, `<--` becomes ←, and `==>` becomes ⇒. Other supported forms include `:)`, `:(`, `;-)`, `:D`, `:P`, `<-->`, `<==`, `<==>`, `<->`, `...`, `(c)`, `(r)` and `(tm)`. These work in conversation drafts and Parking Lots, including drafts for remote sessions displayed on this Mac. Pasted text, Markdown code blocks, inline code, indented code, and lines beginning with `/` or `$` stay literal.

Don't like a substitution? **⌘Z** restores exactly what you typed; **Backspace immediately after the substitution** does the same. A **Turn off substitutions** button appears as soon as text converts, so you do not have to Undo to discover the setting. When substitutions are off, typing a shortcut that would convert shows **Turn on substitutions**. These buttons disappear after ten seconds; another eligible shortcut brings them back. You can also use **Settings → Text substitutions while typing**, or simply ask App Support to turn them on or off. The setting starts on and is saved for this app on this Mac; changing it never rewrites existing text.

### Keep several sessions visible

Create another session with **+** when you want an independent task or a second opinion. **1 / 2 / 3** place a session in a pane. **P** parks it: the pane closes but work continues. **X** closes the session after confirmation and stops its work; Mac **File → Restore Closed Conversation** can restore a saved recovery copy.

Drag the dividers to resize panes. Changing the number of visible session panes redistributes their widths equally without changing the sidebar width. Creating a session, agent or lot never takes over a pane, and clicking a name never moves panes: use 1, 2 or 3 beside a row to show it, P to park it. The pin beside **Conversation** hides or restores the sidebar. Hover a session name for its provider, login, project folder and status; right-click it to rename or configure it (for an agent: **Agent Setup…**, **Show scoreboard**, **Run once**).

To organize the sidebar, click **Reorder** at its top. Drag a device to move its whole section, or drag a session, agent or Parking Lot within its device. This changes display order, not where work runs. Click **Done** when finished; both levels of order survive a restart.

### Add images and filenames

Paste a screenshot or image, or use **Attach** to choose one. Its preview appears in the draft; **×** removes it. Sending supplies the image to the selected provider along with your prompt. You can ask “What is wrong with this layout?” or “Explain this diagram.” Images returned by an assistant appear in the conversation too. A web image in a reply stays a link until you hover it and click **Load image** on the computer running that session; a suspicious-looking link shows a warning and asks before loading.

On **Mac and Windows**, dragging a file or folder from Finder or Explorer into a pane inserts its **fully qualified filename**, quoted when needed. It does not upload the file. This is useful for “Review this file: …” when the assistant works on the same computer. To send image content, use Paste or Attach instead. iPhone/iPad do not insert desktop file paths.

On Mac, an image's context menu offers **Save Image to Photos** and reports whether the import succeeds. Import into Mac Photos and later iCloud synchronization to your other devices are separate steps.

### Describe an image or isolate objects with SAM

**SAM** is Meta's image segmentation service: it finds the pixels belonging to objects so you can extract them without their background. It does not replace your session's model. You can use it in a Claude or Codex session too.

On Mac, right-click an image already in the conversation or still in your draft and choose **Image tools · Describe / SAM…**. The wand beside attached images opens the same tools.

1. Leave the description blank and press **Find Segments** to discover objects, or enter what you want to find, such as “animals” or “red trucks.”
2. Review the numbered outlines. Click an object or its number to select it, enter numbers and press **Toggle**, or choose **All / None**. Selected objects turn yellow.
3. Choose **Add selected to draft** for separate tightly cropped PNG cutouts, or **Copy selected** for one PNG with the selected objects in their original positions on the original-size canvas. Removed pixels are transparent, including holes inside objects.
4. Review the draft and send when ready. Selecting or extracting objects never sends the prompt by itself.

**Describe image** is a separate option: Muse Spark (Meta’s hosted model for these image helpers) writes notes you can edit before adding them to the prompt. Blank object discovery also uses Spark to identify up to six object types, then SAM finds their shapes; a typed object description goes directly to SAM. Discovery may miss objects, so try a more specific description.

Both **Describe image** and **Find Segments** require a **Meta API key** (a credential for Meta’s hosted services), separate from a Muse CLI login. On the Mac, right-click **Converse App Support → Agent Setup** (settings for the support assistant) and use the masked Meta key field and **Test key**. Agent Setup is also where this shared optional credential is stored; you do not have to change your conversation's provider. The image is sent to Meta only when you invoke the tool. Without a key, the SAM item is unavailable. Windows/Linux do not currently process these requests.

## Export transcripts

On Mac, choose **File → Export…** and select one or more sessions. Choose prompts, responses or both, and whether to place sessions one after another or interleave them by message time. Turn on **Only messages from** to export just a window of time, say last Tuesday's design session, by picking a start and end date and time. Older messages without a recorded time are left out when you do; Parking Lots are always exported whole. **Include images** decides whether pasted and generated images come along (HTML and Converse formats).

**HTML** makes one portable document with formatting and embedded images; open it in a browser to read or print. **Text** preserves Markdown and lists attachment filenames. Exports exclude unsent drafts, account configuration and hidden tool activity. Check the content before sharing it.

**Converse** makes a file another Converse can import, so you can hand someone your way of working. Say you have a planning conversation and a Parking Lot of ideas for a project: export both, send the `.converse` file to a teammate, and they choose **File → Import Conversations…** (or double-click the file). They review what's inside, pick what they want, and get the same history and the same lot to start from. Imports always arrive as new sessions and new Parking Lots; nothing they already have is changed.

An imported session isn't connected to a provider yet, so you pick one right at the bottom of its pane: your usual assistant and login are already selected, and you can click another logo or account (or **New login…**) before you click **Use**. Converse then fills in an editable catch-up message ahead of anything you'd typed: the handoff note if there is one, the last 10 messages, and where the full transcript is saved. Trim it, add your question, and press Return. Nothing is sent until you do, and changing your mind about the provider before then just swaps the catch-up part. Agents come across as ordinary sessions: their transcript travels, but not their objective, schedule, connections or logins. Turn on **Include handoff notes** and each selected session's assistant first writes a short note for whoever picks it up next (goals, decisions, where things stand, what's left, the gotchas). The note travels in the file, so the person importing it starts from the handoff, not just the raw transcript.

**Change Assistant or Login…** (right-click a session, or the login name at the bottom of its pane) lets you hand a conversation to another assistant. Say Claude has been designing a feature and you want Codex to build it: pick Codex, and Claude writes a handoff note first. Codex starts fresh but reads that note and the full transcript with your next prompt, and the whole history stays in the pane. Picking the same assistant with a different login, like your second Claude account, just continues the same conversation under that account.

**Remove secrets and personal info** is on by default for the Converse format and available for HTML and Text. It swaps things like API keys, tokens, passwords, email addresses, phone numbers, IP addresses, your name, your home folder and your Group's device names for placeholders such as `[email 1]`, and shows what it removed before saving. It's best-effort, so read the file before you share it. Images can't be checked, so they're left out unless you turn on **Include images (not scrubbed)**.

## Set up your first agent

An **agent** is a conversation with an ongoing objective. You can talk to it like a session, ask it to check once, or let it check periodically. It uses the provider and model you select, and only the extra information you allow it to read.

### App Support is your first example

**Converse App Support is itself an agent.** On a new Mac installation, setup turns the verified support conversation into this agent. Right-click its name and choose **Agent Setup…**, or use **… Agent actions → Agent Setup / Loop…** in its pane.

Look at its settings before making your own:

| Setting | App Support example |
| --- | --- |
| Objective | Keep Converse up to date; identify serious bugs and explain their impact and the next step. |
| Model and login | The provider you verified during setup; it need not be Meta. |
| Repository | `richardkaufmann/converse`, so checks can use GitHub releases and open issues. |
| Automatic loop | Enabled, every **1,440 minutes** (24 hours), with **Auto pacing** on. |
| Sessions it may read/message | None selected by default. |
| Mood art and speech | Off. |

Type “What should I know about the current Converse release?” to ask it directly. Choose **Run once** to have it assess its configured objective now. Read the report and its evidence. App Support reports available updates and serious bugs; it does not silently install an update. It uses installed Help and this exact repository first. Any necessary web searches must identify Richard Kaufmann’s Converse AI coding app, not the bare word “Converse”; unrelated namesakes are not evidence. If it cannot access the repository, it should report that limitation rather than claim there are no bugs.

You can change its objective or pause **Enable automatic loop**. A daily desktop check needs Converse to be open. Restarting preserves the deadline rather than postponing it another day; the scheduling section below explains catch-up behavior.

### Make an agent for your own work

1. Choose **New agent…**. Name it “Project Steward,” for example. New agents start paused.
2. In **Agent Setup**, choose a model from the enabled providers and logins. The dropdown identifies both provider/login and model. A choice using the Meta API needs a saved Meta API key; a choice using Claude, Codex or Muse's CLI uses that provider's login.
3. Review the editable default objective. It asks the agent to clarify success, verify evidence and qualify searches to avoid unrelated namesakes; you may change or delete that guidance. Add a testable outcome: “Watch Website and Code Review. Find blockers, ask for missing evidence, and tell me when the release checklist is satisfied.”
4. Under **Sessions this agent may read and message**, select only the sessions needed. This list starts empty. Selected session excerpts will be sent to the agent's provider, even if those sessions use a different provider.
5. Save, then type a little background into the agent's conversation. Use **Run once**, read its assessment, and adjust its objective or scope until the result is useful.
6. Only then turn on **Enable automatic loop** if you want repeated checks; say how often in the objective. Leave optional integrations off until you need them.

An agent can assess evidence and ask a coding session to act; selecting a CLI-backed model does not give the agent that coding CLI's unrestricted tool environment. If you want it to edit a project, use a coding session for that work and explicitly allow the agent to communicate with it.

## Agents and project scoreboards

### Give the agent evidence for its objective

**GitHub:** enter `owner/repository` in **Repository**, or leave it blank if the job has nothing to do with a repository. Converse fetches repository evidence and supplies it to the selected model. This works with CLI-backed agents as well as Meta API agents. **Test GitHub** checks access without changing the repository. Public polling has limits; private repositories need a GitHub token with appropriate access in the masked field.

**Home Assistant:** enter your Home Assistant URL and up to 32 comma-separated entity IDs in an agent's **Agent Setup**. Save a long-lived token in the masked field on the agent's home computer, select **Let this agent read selected Home Assistant states**, and use **Test HA** (or **Test Home Assistant** on Windows). Each run receives only the selected entities' current state, friendly name, unit and change time. The token never goes to the model. Converse uses this connection only for reads: it cannot turn devices on or off or call services through the connector. The token itself retains the permissions of its Home Assistant account, so keep it private and revoke it there if needed. Each agent has its own entity selection; the saved token is shared by agents on that home computer. Without a configured connection, agent runs continue normally. Use HTTPS when connecting beyond a trusted local network. [Home Assistant's authentication guide](https://contributors.home-assistant.io/core/internals/auth-api/) explains long-lived tokens; [the REST API guide](https://contributors.home-assistant.io/core/internals/rest-api/) documents state reads.

App Support illustrates the distinction: its goal is to notice releases and critical bugs; GitHub supplies the issue/release evidence. A coding-project steward can combine that evidence with the progress reports from the sessions you selected. Neither a healthy model response nor a quiet issue list proves that the app is bug-free.

**Session monitoring:** the selected sessions supply recent submitted conversation and activity status. Unsent drafts and credentials are excluded. The agent can compare what those sessions report against its objective and send messages within its allowed scope. Start with a narrow selection and inspect its first report before enabling a loop.

**Web research:** this currently depends on the agent's execution route:

| Selected agent route | Evidence and research available |
| --- | --- |
| Claude, Codex or Muse CLI login | Conversation, objective, notes and evidence fetched by Converse, including configured GitHub/session information. Native CLI web and shell tools are disabled for these bounded agent runs. |
| Meta Model API | The same configured evidence, plus optional Meta hosted web search when enabled, capped at four searches per run. |

A saved Meta key does **not** automatically add web search to a Claude/Codex/Muse CLI agent. A Muse CLI login alone does not enable hosted agent search, SAM, art or voice transcription. Image tools, artwork and voice have separate Meta requirements; they do not determine which provider reasons about the agent's objective.

### Set a useful rhythm

Say how often to run in the objective, in your own words. A stock tracker might say: “Run every five minutes, and generate new scoreboard art at least every twelve hours or when any stock changes value by more than 0.5%.” When you save, Converse asks the agent's own model once to read the timing, then shows what it understood under the objective, in the footer and when you hover the agent's name: *Runs every 5 min · art: at least every 12 h, or when any metric moves > 0.5%*. It reads the objective again only when you change it. Days and hours work too: “only while the US stock market is open”, “weekdays between 9am and 5pm New York time” or “once a day at 09:00”.

If the objective says nothing about timing, **Auto pacing** decides. It is on for new agents: each run suggests its next check with a short reason, sooner while a release is going out, hours later when nothing is moving, and the footer shows it, for example *Auto · next in 20 min (release in progress)*. It stays between 5 minutes and 72 hours by default, so a quiet agent can sleep through a three-day weekend; change both bounds in Agent Setup. A cadence you state in the objective always wins over the agent's suggestions. If Converse can't read the objective (for example, a Meta model without a Meta key), the summary says so and Auto pacing's defaults apply; save again to retry.

Agents stay quiet when there is nothing to say: a scheduled check with nothing new or relevant adds no reply, though the scoreboard may still update. Ask it for a status and it answers in one short line even when nothing has changed.

Use **Enable automatic loop** and **Maximum turns per loop**. That limit applies to each activation; it is not a lifetime allowance. A newly enabled loop waits one interval before its first check. **Run once** performs a check without enabling a paused loop or moving an already scheduled deadline.

Restarting keeps the saved deadline. Several missed checks produce at most one catch-up check. Days and hours from the objective are still respected, and busy agents and paused queues wait.

Agents keep going through hiccups. A timeout, a dropped connection, a busy provider or a garbled reply doesn't stop the loop: the agent asks again, then retries after one, two, four and eight minutes, never waiting longer than its usual interval. If it keeps failing, a banner says *Having trouble since 3:05 PM: The request timed out. — still retrying (3 tries)* until a good run clears it. A failed side job, such as a Discord alert or a Parking Lot edit, is reported in the reply and the run still counts. Loops pause only for something you must fix (a missing or rejected key, a spent turn limit, a schedule or setting to review) or for your own **Stop**. The reason and time stay visible, even through **Run once** or a Discord question, until you resume the loop or choose **Clear attention banner**. To take charge, open **…** or click the agent's footer status (**Idle**, **Thinking now**, **Loop paused**): **Pause loop** / **Resume loop**, **Stop current run** (just this run; the loop carries on) and **Run once**. In an ordinary session, clicking the status offers **Stop** and, with messages waiting, **Pause queue** / **Resume queue**.

Upgrading an older agent? Its separate schedule text was moved into the objective as a last line, such as “Schedule: every 20 minutes while the US stock market is open”, with a note in the agent's transcript. Edit it there like any other instruction. However the objective is worded, **Stop**, pausing, the turn limit and a one-minute minimum always apply.

A green loop indicator means scheduled checks are enabled and waiting; a rainbow spinner means work is underway; yellow attention means there is something to review. The footer shows the next check. **Reload settings** refreshes a form if another edit made it stale.

For Meta API agents the footer also shows the last turn's tokens, including how much of the input was served from the provider's prompt cache (for example *cached 80% of input*). Cached input costs much less, so repeat checks get cheaper. The account column shows **API Key**, since an API key has no account details to report.

### Read the scoreboard and optionally add art

**Show scoreboard** presents the agent's status and available measurements in **cards** (small labeled panels). With a repository, these can include issues, bugs, pull requests, stars and release downloads. Repository visitors require authorized GitHub access. None of these counts measures actual app users.

For search-backed cards, source links and **observation times** (when the source measured the value) matter: a delayed quote or prior close is not a live price. Unsupported values remain unavailable. **Export widget** saves a portable HTML snapshot with embedded art; it is a snapshot, not a live dashboard.

Optional **mood art** uses Meta's image service independently of the agent's reasoning provider. Supply a Meta key, enable art, and write the desired subject and style in **Scoreboard art direction**. Save and **Run once** to try it. You do not need art for useful reports; App Support leaves it off.

Art changes when the mood or the scoreboard numbers change, but no more often than every 30 minutes, and unchanged art refreshes about every 6 hours. Adjust both next to the art toggle, or say it in the objective, which takes precedence. “New art when any price moves more than 0.5%” compares each number on the scoreboard with its value in the current picture, so the jump at the market open redraws it and small wiggles don't; words such as “Open” or “Halted” don't count. Editing the art direction always updates the picture on the next scoreboard refresh.

### Voice on Mac

**Dictate…** records up to a minute, sends audio to Meta for transcription, and lets you review it before inserting it into the draft. It needs a Meta key and microphone permission.

**Start talking!** explicitly starts a spoken conversation with an agent. Listening pauses while it transcribes, thinks and speaks. **Stop talking**, parking the pane or quitting ends that conversation. Scheduled checks and incoming messages do not start speech. Spoken replies use Apple's speech synthesis; the selected agent provider still generates the answer.

### Connect Discord on a Mac

Discord is optional. It lets an agent read a chosen channel during checks, post alerts, or answer people who mention it. Begin with one agent and one channel:

1. Create a Discord account and a server you control, or ask its administrator for permission to install a bot. Create a dedicated bot in [Discord's Developer Portal](https://discord.com/developers/applications), enable **Message Content Intent**, and invite it to your server with **View Channel**, **Read Message History** and **Send Messages** permission in that channel.
2. In the portal’s **Bot** page, obtain the bot token (reset it if necessary). Use **Installation** with a server install and the `bot` scope to invite it with the permissions above; Administrator permission is not needed. In Discord **User Settings → Advanced**, enable **Developer Mode**, then right-click the destination channel and choose **Copy Channel ID**. The token, application ID and channel ID are different values. [Discord’s setup guide](https://docs.discord.com/developers/quick-start/getting-started) covers bot creation and installation.
3. On the Mac, open the agent's **Agent Setup**. Put the bot token in the masked Discord field and the channel ID in its channel field. The Mac's agents share that saved bot token.
4. Choose reading and/or alerts. **Test Discord** posts a labeled test message and reads it back; it does not send session content. Save the settings after testing.
5. If you want direct questions, enable **Anyone in this channel may @mention this agent**. Use a real bot mention: `@Converse Project Steward: what needs attention?` A **Default agent for this channel** also accepts `@Converse question`.

Anyone able to post in the configured channel can use enabled mentions. By default, replies use the question and public channel context, not private session history. **Share session information** is a separate opt-in requiring a verified private channel; **Share scoreboard and mood image** is another opt-in and needs **Attach Files** permission. Leave both off unless you intend to share that material.

The Mac app must be open. Mention checks run independently of the agent's loop; pausing a daily loop does not disable enabled mentions. Windows/Linux do not host Discord integration yet. [Detailed Discord behavior](docs/agents.md#discord-bot-integration).

## Set up Discord, Jolly, GitHub and Home Assistant

Tell App Support what you want: “Help me connect my own Discord server,” “Let me ask my agent questions from Muse on my phone,” or “Watch my GitHub repository for new issues.” It can walk you through the relevant guide and open supported settings. You supply your own accounts and credentials; installing Converse does not give you access to the developer’s services.

| Connection | What you need | Where to start | How to confirm it works |
| --- | --- | --- | --- |
| Discord | Your server, permission to install a bot, a bot token and a channel ID; a Mac home running Converse | [Discord setup](#connect-discord-on-a-mac), then Agent Setup on the Mac | Test Discord, then send a real bot mention and receive the intended agent’s reply |
| Jolly / Meta Muse phone app | A Muse account with connector access, your Mac, a bridge, your own reachable HTTPS address and a bearer token | [Jolly setup](#jolly-mac); an operator prepares the connection first | List allowed agents, ask one by name, and receive its correlated reply on the phone |
| GitHub | A repository you can access; a token for private access or report submission | [GitHub setup](#connect-your-own-github-repository), then Agent Setup or the report window | Test GitHub, run a check, and inspect the evidence; a submitted report must return an issue URL |
| Home Assistant | Your server URL, a long-lived access token and the entity IDs this agent may read | Agent Setup on the Mac or Windows home | Test the connection, run once, and ask about one selected entity |

Each connection is optional and independent. Start with one agent and one service. GitHub monitoring works on Mac and Windows; Discord and Jolly currently need a Mac home. A paired iPhone/iPad can view desktop work, but does not host these integrations. Keep the home app open and the computer awake and connected when you expect replies.

Credentials go in the app’s masked fields or the connector’s authentication settings, never in a conversation. An agent also needs explicit access to any sessions or Parking Lots you want it to discuss: enable those in Agent Setup. Connecting Discord or Jolly does not grant that access. Start with a harmless question before asking about private work.

### Connect your own GitHub repository

1. Create or choose a repository on GitHub. In your agent’s **Agent Setup**, enter **Repository** as `owner/repository`, for example `your-name/your-project`, and give the agent an objective such as “Watch releases and open bugs; tell me what needs attention.” This does not clone the repository or configure a coding session’s Git login.
2. For public monitoring, try **Test GitHub** without a token first. For private repositories or authenticated access, create a token in GitHub **Settings → Developer settings → Personal access tokens**. Prefer a fine-grained token limited to the intended repository, with an expiry. For repository evidence, grant read access to **Contents**, **Issues** and **Pull requests**, with the required **Metadata** access. Organization approval or SSO authorization may also be required. See [GitHub’s token guide](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) and [endpoint permissions](https://docs.github.com/en/rest/authentication/permissions-required-for-fine-grained-personal-access-tokens).
3. Paste it into the masked **GitHub token** field and save. On Mac, this saved token is shared by the app’s agents; replacing it can affect their repository access. **Test GitHub** checks access without modifying the repository. Run an agent check and inspect its issue/release evidence too: basic repository access does not prove every optional statistic is available. Visitor statistics can require additional repository permissions; missing statistics are not zero activity.
4. Enable the automatic loop only if you want repeated checks. If access fails, check the repository name, account access, token expiry, selected repositories and organization approval. A private repository can look missing to an unauthorized account.

Monitoring does not submit issues or push code. To report a Converse bug, use [Report a bug](#report-a-bug): that separate workflow targets `richardkaufmann/converse`, requires issue-writing permission for direct submission, and lets you review the exact report. A token for your own repository does not automatically grant access to Converse. Coding sessions use their own Git/CLI authentication. Automatic GitHub-to-Parking-Lot synchronization is planned, not available yet.


## Jolly (Mac)

**Connect the Meta Muse iPhone app** means letting Meta's phone assistant, Jolly, send requests to allowed Converse agents on your Mac. For example: “Ask Project Steward what is blocking the release,” or “Ask Converse whether the app is up.” General app-health questions route to an allowed Converse App Support agent, which can report the app's state and the connected devices it knows about. If Jolly addresses one agent but the request names another (“summarize the KAOS Parking Lot” sent to Converse Steward), Converse sends nothing and tells Jolly which agent to ask instead.

This is optional and separate from the **Converse iPhone/iPad app**. Jolly is a conversational connector; the native Converse mobile app displays session panes. Connecting Jolly does not require changing an agent to a Meta reasoning model.

**This integration still needs operator setup.** It requires a **bridge** (a small background service) on the Mac, an **HTTPS endpoint** (a secure web address the phone can reach), a **bearer token** (the secret that authorizes requests), and a **connector schema** (the description of available actions) loaded into the Meta Muse app. Opening **Converse → Settings → Jolly** alone does not create that infrastructure. The current [bridge installer](scripts/install-jolly-bridge.py) is intended for an operator who has prepared the token and endpoint; it does not provision a tunnel or a Muse account.

### Preparing your own Jolly connection

Ask App Support to walk through this with the person administering your Mac. First confirm that your Meta Muse account actually offers connector configuration; Converse cannot enable that service-side capability. The steps below describe what the operator must supply, rather than promise a particular Muse settings screen.

1. Obtain the matching Converse source scripts and a Python 3.9 or newer runtime. Generate a long random bearer token and store it in a private file readable only by your user (mode `0600`). Use a different token from your Meta API key, Discord bot token or GitHub token.
2. Arrange an HTTPS reverse proxy or tunnel on an address you control, forwarding to the bridge on `127.0.0.1:4691`. Keep the local listener on loopback. The phone must reach that address even when it is off your home Wi-Fi. Converse does not supply a hosted endpoint, domain or tunnel account.
3. Run the bridge with your own public address. From the source checkout, this example uses placeholders for the token file and HTTPS address:

   ```sh
   python3 scripts/jolly_bridge.py \
     --root "$HOME/Library/Application Support/Converse/Jolly" \
     --token-file /absolute/path/to/your-private-token-file \
     --public-base https://your-bridge.example
   ```

   Keep the process running for the first test, then have the operator arrange a persistent service. **Always set `--public-base` to your address**: the script’s current default is the developer’s endpoint, used for returned image links. The existing `install-jolly-bridge.py` is a migration helper and does not pass a custom public address; it is not a complete new-user installer. Do not run it unchanged for someone else’s endpoint.
4. In Muse’s connector configuration, load `https://your-bridge.example/openapi.json` and set its server/base URL to your HTTPS address. The schema does not supply a server URL. Configure bearer authentication using your private token in the connector’s secure credential field. The schema names the integration **Ask Converse**.
5. Open Converse, allow the intended agents in **Converse → Settings → Jolly**, then follow the test below. `/health` can verify the bridge and reports `appAvailable`; bridge health alone does not prove an agent can answer. Authenticated `/v1/agents` should list the agents you allowed. A `401` means authentication failed; an unavailable app requires the correct Mac/profile to be open. If text works but art does not, check the public base address and tunnel image route.

Treat the bearer token as access to the enabled agents. Limit their scope before sharing the connector. Returned artwork uses opaque image URLs that can be retrieved without the bearer token; anyone with such a URL can view that image. To stop new agent requests, disable its Jolly access. To revoke the connector itself, stop the bridge or rotate the token and update the connector’s credential; disabling an agent does not erase saved replies or images.

Once that bridge is configured:

1. Open **Converse → Settings → Jolly** and allow the local agents the phone may address.
2. Load or refresh the connector schema in Muse so it exposes **Ask Converse**.
3. Ask it to list the available agents, then address one by exact name. If a choice is ambiguous, it should ask which one rather than broadcast.
4. Confirm the request appears in the intended agent's conversation and the reply returns to the phone. Pending is not a completed answer.

The bridge runs in the background as the launchd agent `local.converse.jolly.bridge`, and launchd restarts it if it stops, so it keeps running after you quit Converse. That way Jolly can still reach your Mac and learn whether Converse is available. To stop it, run `launchctl bootout gui/$UID/local.converse.jolly.bridge`.

Converse must remain open to do new work. The bridge can report that it is offline and serve previously saved replies. A message you explicitly leave for the phone is retrieved when Jolly checks; it is not pushed into a Muse conversation automatically. [Bridge protocol and recovery](docs/agents.md#jolly-routing-mac).

## Messaging between sessions

The **switchboard** lets conversations send messages to each other. Use it when, for example, one coding session should ask another to review a change.

Right-click a session and choose **Teach Session To Talk To Other Sessions**. That enables messaging and gives the model the current rules. Teach each participating coding session. Then type naturally: “Ask Code Review to review this change and report any blockers.”

**Tell** is one-way; **Ask** expects an answer, blocker or decline. Delivery means a message was queued, not that the work was done. Traffic appears as compact orange lines that you can expand or inspect. “Reply needed” means an Ask still needs its matching response; refreshing teaching alone does not resolve it.

Behind the scenes, a session sends a message or edits a Parking Lot by ending its reply with a short command block. A line of explanation before it is fine. If anything follows the block, or a reply holds more than one, nothing is sent and Converse adds a notice saying so; ask the session to resend.

On Mac, a message's receipt advances from **Queued** to **Processing**, then **Completed** for a tell or **Awaiting reply / Answered** for an ask. The receiving pane shows its delivery status above the transcript; **Delivery details** shows recent messages. A completed tell needs no acknowledgement. Remote transport receipts confirm acceptance on the home system; they do not prove the remote turn completed.

A supervising agent can request recovery for a stalled message in a selected session on the same Mac. Converse checks the delivery ID and current progress before acting: queued work must be at least two minutes old, with no recent output if the session is busy; a finished unanswered ask gets a 30-second grace period. Recovery injects the existing message, or one reminder to answer the ask. The agent and automatic supervisor share **one attempt per delivery**, followed by a visible alert if it still needs attention. Paused queues, approvals, sign-in and unsent drafts are respected. Normal one-way tells never create reply deadlines. Agent-requested recovery of remote sessions is not yet supported.

App Support receives switchboard teaching during onboarding. Agents retain the session scope you selected in Agent Setup. You can disable session messaging from the context menu. The [switchboard reference](docs/switchboard-reference.md) describes command formats, delivery tracking and recovery; you do not need to type that protocol to use it.

## Connect your devices into a Group

A **Group** connects your Converse installations. You can display and control a session from another device while it continues running on its **home** computer—the computer with its provider login, tools and project folder. A Mac or Windows PC can be both a home and a viewer. iPhone and iPad are viewers/controllers.

1. Open Converse on both devices. Start on the same local network with compatible current builds.
2. On your desktop, open **Converse Groups** below the sidebar or in the Converse menu. Choose **Create Group**, name it and press **Create**. Create it only once.
3. On the other device, open Groups/pairing, find the Group and choose **Join**. On iPhone these controls are in the session picker opened by the stacked-rectangles button; on iPad use its Converse menu.
4. The joining device shows an eight-part verification number. On an existing member choose **Review**. Compare **all eight parts**, then press **Pair** on both devices.
5. Choose a session to display. Use **1 / 2 / 3** on desktop/iPad, or check it in the iPhone session picker. Joining does not automatically select a session.
6. Send a simple request and confirm the reply. The tools and files remain on the home computer. Parking the pane or disconnecting the viewer does not stop work there.

Only one device displays a given session at a time. Taking it on another device moves its display there; it does not duplicate the work. Drafts and attached images travel with it. After reconnecting, **Check home** resolves an uncertain send without blindly sending it again. A conflicting draft asks you to choose which copy to keep.

Repeat pairing for additional computers, phones or tablets; multiple iPhones and iPads are supported. Any member may review a new join. Each installation belongs to one Group at a time. Pair only devices you trust: membership grants access to conversation history and control under the home computers' logins.

### Use a remote computer

The sidebar lists devices and their sessions. **+** beside an online computer creates a session there, using that computer's installed provider and login. Its project folder must be on that computer.

A filename dropped into a remote session is labeled `file from <device name>: <full path>`. It identifies the source; it does not copy the file or make that path readable on the home. Use an actual attachment when you need to send image content. Mac transcript export includes remote sessions when their homes support it; offline or incompatible homes report an error rather than exporting incomplete history.

Hover a device heading for details. Right-click it, or use mobile actions, to **Rename device…**. The display name is shared with the Group, including devices that are offline and reconnect later. It does not change operating-system hostnames or internal identities.

**Groups remember you.** Quit, restart, or take a device offline: its membership survives. When Converse is running again and the systems can reach each other, they reconnect without pairing again. This includes iPhone and iPad; reopen Converse after returning to the network. Leaving or dissolving the Group is different—it deliberately ends membership.

**Take your Group on the road.** A [UniFi Travel Router (UTR)](https://store.ui.com/us/en/category/wifi-special-devices/collections/unifi-travel-router/products/utr) is a great tool for this. Set up its VPN tunnel into your home or office network, connect your devices to it, and work remotely wherever that tunnel can reach your Converse systems. Ubiquiti provides Teleport/Site Binding and WireGuard options. If discovery does not cross the tunnel, use **Host or IP** and the port shown in Converse Groups. You still approve pairing on both sides the first time; the router does not admit devices to your Group.

If discovery is empty, check local-network permission, firewalls and reachability. **Host or IP** plus **Port** lets you join over a reachable VPN or a network without discovery; the same verification is required. **Leave** affects only this installation and preserves its local sessions. **Dissolve** ends the Group after confirmation. Groups do not merge.

### Use the native iPhone or iPad app

On iPhone, the stacked-rectangles button opens **Sessions**. Select one or two; two stack vertically. **Show keyboard / Hide keyboard** controls editing explicitly. Tapping the draft opens the keyboard; tapping history selects a pane without starting editing. While typing, the other session becomes a tappable title strip. The picker also contains pairing, New session, Help and About.

On iPad, the sidebar and up to three panes use the desktop-style placement controls. Use **Send** to submit a draft. Session actions include agent settings, **Run once**, and **Teach / Refresh Switchboard Instructions**. Tap an orange traffic summary to read the full message.

Image tools on iPad require an updated **Mac home** with a saved Meta key, independent of the session provider. Its image menu offers **Use in draft · Image tools…** for a historical image. Tap objects or their numbered outlines to select segments; keyboard input is optional. Neither mobile app hosts provider CLIs or background agent loops: its home computer does that work.

You now have the concepts needed to add a Linux home if you want one. Otherwise, the remaining sections are privacy and reference material.

## Connect a Linux computer

A Linux computer can be a **headless Converse home**: an always-on box in a closet, a cloud server, or a VM. It runs real Claude Code, Codex, and Muse sessions under its own logins, with no Converse window. You drive those sessions from your Mac, Windows PC, or iPad. The walkthrough below uses SSH from a Mac. Windows also offers **Converse → Set up Linux**. Allow time for provider installation and sign-in as well as pairing.

> **Let Converse do it for you.** Copy this whole Help topic (click in the text, press **⌘A**, then **⌘C**) and paste it into a Converse session on your Mac that can run shell commands, such as Claude Code or Codex with permission to run the commands you review. Add a line like *"Set up my Linux computer `you@my-linux.local` using these steps."* The session runs the commands for you and skips any step that's already done. It stops and hands you a command whenever it needs you: anything with `sudo` (you run it yourself in Terminal, for example `ssh -t mylinux 'sudo loginctl enable-linger $USER'`), approving the SSH host key, signing in to Claude, Codex, or Muse, and comparing the pairing number and pressing **Pair**. Those steps stay with you on purpose.

**What you need**

- A Linux computer with systemd (tested on Ubuntu 26.04), 64-bit Intel/AMD (`x86_64`) or ARM (`aarch64`), on the same network as your Mac.
- Your own user account on it, with `sudo` rights for a few one-time steps. Converse itself runs as you, never as root.
- A Mac that is already in a Converse group (see [the Group setup steps above](#connect-your-devices-into-a-group)).
- This repository's source on the Mac. Get it once:
  ```sh
  git clone https://github.com/richardkaufmann/converse.git ~/Developer/Converse
  cd ~/Developer/Converse
  ```
  If you already have a checkout, use it instead. In the steps below, “your Converse source folder” means this checkout.
- For now, the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) on that Mac. Linux builds aren't published as downloads yet, so you build the Linux program on the Mac (Step 4). The build finds .NET on your `PATH` or in `~/.dotnet`; check with `dotnet --version` or `~/.dotnet/dotnet --version`.

In the steps below, replace `you@my-linux.local` with your Linux user name and computer name. The `.local` name works on most home networks; you can use the computer's IP address instead. `mylinux` is the short SSH nickname you create in Step 1; if you already have one for this computer, use it instead. Already did some steps? Skip them. Reuse existing SSH keys and configuration; do not overwrite them when repeating setup.

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

### Step 3: Install and sign in to at least one: Claude Code, Codex or Muse

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
5. Sign in to each one you installed. You're in SSH with no browser on the Linux side, so each tool gives you a link to open on your Mac:
   - **Claude Code:** run `claude`, choose your account type, and open the link it prints on your Mac. After you approve, copy the code from the browser and paste it back into the terminal. Type `/exit` when you're done.
   - **Codex:** run `codex login --device-auth`. Open the link on your Mac and enter the code it shows. (Plain `codex login` waits for a browser on the Linux computer, so it doesn't work over SSH.)
   - **Muse:** run `muse`. It shows a meta.com link and a code. Approve it on your Mac, and Muse finishes downloading. Exit when it's ready.
6. Check the ones you installed (skip lines for tools you don't use):
   ```sh
   ls ~/.local/bin
   claude auth status
   codex login status
   muse usage
   ```
   You only need one provider; `muse usage` applies only if you installed Muse.

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

## Security and privacy

**The basic deal: reach it, pair it, trust it.** If your Converse app can reach another system’s Converse port, it can ask to join that system’s Group. Compare the verification number and approve on both sides, just like pairing a phone to a car. Being on the same network—or knowing the port—is not enough to get in. Once you pair, that device can see and control sessions in the Group. Only pair systems you trust with that access.

**Groups are persistent.** Devices remember their membership and reconnect when Converse is running and the network is reachable again. That includes iPhones and iPads. A VPN back to your own network lets you use the Group away from home; see [Take your Group on the road](#connect-your-devices-into-a-group) for the UniFi travel-router option.

**What goes over the wire?** Group messages use ChaCha20-Poly1305 authenticated encryption, with the Noise XX handshake (`Noise_XX_25519_ChaChaPoly_SHA256`) and remembered device identities. Desktop and Linux homes normally listen on **TCP 48721**. Mobile apps and Demo editions can use an automatically selected port; check Converse Groups for the actual port. Discovery helps devices find each other, but **Host or IP** works across a routed network or VPN too. For remote access, use a VPN into your trusted network rather than exposing the Converse port directly to the internet.

That’s the posture. Pairing is an invitation into your workspace, not just permission to look at one window. Read on to decide whether it fits how you want to work.

You also choose which AI provider receives each conversation and what extra material an agent may read. Start with one provider and one project. Add access when you need it. Enter secrets in the app’s masked credential fields, never in a conversation.

Desktop Converse runs sessions and agents on their **home system** while the app is open. A Linux home runs them in its background user service while that service is running, without a desktop window. Local storage does not mean local AI: your prompts and the context needed to answer them are sent to the **provider selected for that session or agent**. That provider's account terms, retention settings and privacy policy apply. Converse does not make a blanket promise that providers never retain data.

**Choose what an agent can see.** An agent receives its conversation, objective and working notes. If you select other sessions in Agent Setup, relevant excerpts from those sessions are also sent to the agent's selected provider—even when those sessions use a different provider or live on another Group member. Agents you create start with no watched sessions; the first-run starter agent watches only the starter coding session and Parking Lot. Repository checks send the repository name to GitHub and supply returned issue/release information to the selected model. Treat private repository content as private data. App Support's daily check uses the Converse repository while the app is open, with Auto pacing on (so it may check sooner or later within its bounds), and starts without watched sessions or mood art. You can pause its loop in Agent Setup. App Support does not hold up Quit: if it is the only active session or scheduled agent, Converse saves its state and quits without a warning.

**Images in agent chat (Mac).** Paste or attach a screenshot to an agent's chat and ask about it. The image goes to that agent's selected provider along with your message. Up to eight recent user-attached images are included from the last 24 conversation messages, resized to at most 2048 pixels per side. Agent-generated artwork and images in watched sessions or Discord are not automatically included. Missing or oversized attachments in your latest message produce an error; attach them again in a new message to retry. Unavailable older attachments are explicitly labeled as omitted. Use the image tools' Describe command when you want to turn an image into reusable text context.

**Integrations have their own sharing boundaries.** Enabling Discord reading supplies the configured channel's messages to the agent. Alerts and mention replies can send content back to that channel; public mention handling excludes private session history by default. Sharing session information requires an explicit setting and a verified private channel. Enabling Jolly lets the authenticated Meta Muse phone connector submit requests to permitted agents and retrieve replies/images. General Converse health questions route to App Support and may include the Group name and host display names/status. Disable an agent's Jolly access to remove it from this routing. Voice and image tools—including SAM—use Meta services independently of the conversation's selected model; the relevant audio/image is sent when you invoke those features. Pasting a key into a credential field does **not** send it to a model.

**Keys and logins.** On Mac, API tokens entered into Agent Setup are saved in macOS Keychain; the app's device identity also uses Keychain. On Windows, agent API keys and GitHub tokens use Windows Credential Manager (`PasswordVault`). Credential fields mask typed and pasted values with bullets, and saved credentials are not filled back into the form. A blank field preserves the saved credential; removal is explicit. These credentials belong to the home system and are not included in Group agent-settings messages. CLI login tokens are managed by Muse, Claude Code or Codex in their own account stores; their storage protection depends on that provider and platform. Converse saves account labels and store locations, not a copy of the login token in the transcript. Never paste passwords or API tokens into a chat: chat text becomes conversation context. Masking a field protects against casual viewing; it does not erase the system clipboard or protect against software already running as your user.

**Group connections and local data.** Pair only devices you trust and compare the displayed pairing code. Group traffic uses authenticated encryption and pinned device identities. A Group can carry transcripts, drafts and attachments to its authorized viewers; it is not a permission boundary between mutually untrusted people. Removing a member prevents future authorized access but cannot retract data it already received. Conversation archives, attachments, exported files and diagnostic/recovery snapshots are local files and may contain private information; they are not all individually encrypted by Converse. Protect your OS account, enable FileVault/BitLocker as appropriate, and protect backups. In the current Windows implementation, the device identity is also a file in the user profile; it does not yet have the Keychain-equivalent protection used on Mac. Do not share an application profile or include it in a public source archive.

**Agent control is scoped, not infallible.** Teaching a session app control enables a defined set of validated operations; it is separate from switchboard messaging permission. Quoted instructions, repository issues and remote messages are data, not permission to change settings. Background runs cannot execute setup changes. A provider error or incomplete response must not execute partial actions. Ordinary coding sessions can still run tools under the access mode you select; use restrictive permissions for unfamiliar projects. App Support reports critical bugs and available releases; it does not silently install an update. Automated tests cover these boundaries, but this is not a claim of an independent security audit.


## Local slash commands

On Mac these commands are handled by Converse without sending a prompt:

| Command | Purpose |
| --- | --- |
| `/help` | Show local command help. |
| `/model`, `/models` | Show model, effort and access details. |
| `/usage`, `/status` | Show or refresh usage and session details. |
| `/login` | Open the login picker. |
| `/stop` | Interrupt the current turn. |
| `/clear`, `/unclear` | Hide or restore the displayed history without erasing model context or teaching. |

Unrecognized commands remain ordinary prompts. These are not the providers' complete terminal command menus. [Detailed desktop controls](docs/desktop-reference.md).

## Accounts

Use **Settings → Models & sessions**, the login identity in a session footer, or **/login** on Mac to choose a login. Additional named Claude and Codex accounts have separate provider configuration stores. Muse uses its CLI sign-in. The provider owns its authentication flow; a Claude desktop login is not the same thing as a Claude Code login.

Changing one session's login preserves its identity, visible history and draft, and does not sign other sessions out. If authentication fails, complete the native login, return and retry or resume the held queue. A timeout in the account-status probe does not by itself prove that your login expired.

On Mac, **Account**, **Limits**, **/usage** and **/status** read provider metadata without submitting a model prompt. Missing values and probe failures are shown explicitly. **Compact** on supported Mac-hosted Claude/Codex sessions summarizes or reduces the conversation history retained by the model (its *context*) while retaining the visible transcript and draft; it is different from clearing the display.

## Build and run

For developers, the [development reference](docs/development-reference.md) covers local Mac builds, signed releases, installation, isolated testing and the session adapters. Platform projects live under [windows/](windows/README.md), [iPad/](iPad/README.md) (including iPhone), and [linux/](docs/linux.md).

A local Mac build requires Apple's Command Line Tools and a checkout of this repository. From that checkout:

```sh
./build.sh
open .build/Converse.app
```

Building does not update an installed copy. Do not replace a running bundle or launch test instances against a live profile. Use the isolated testing instructions in the development reference. The [Meta integration reference](docs/meta-integrations.md) records exact model names and calling code. See the [testing strategy](docs/testing.md) for automated coverage, real-device checks and known gaps.

## Preview limitations

Features depend on both the viewing device and the computer doing the work. Matching build numbers do not guarantee identical platform support. App Support onboarding ships on Mac; Windows onboarding is still an isolated preview. Context compaction (the **Compact** control), Discord, Jolly and voice require a Mac home. SAM processing currently requires a Mac home and a Meta API key. Linux setup and recovery remain newer paths with real-device acceptance work still in progress.

Agents support multiple provider logins, but hosted web research currently requires the Meta Model API route. A provider model appearing in a catalog does not guarantee that your account has access to it. These previews do not include full Claude/Codex interactive terminal approval dialogs.

## Feedback

Questions and ideas are welcome in [Discussions](https://github.com/richardkaufmann/converse/discussions). Please use the [bug-report form](https://github.com/richardkaufmann/converse/issues/new/choose) for problems. Pull requests are by invitation; see [contribution guidelines](CONTRIBUTING.md).

## License

Copyright 2026 Richard Kaufmann. Converse-owned code is licensed under the [GNU General Public License, version 3 or (at your option) any later version](LICENSE), with the narrow SAM codec permission in [LICENSING.md](LICENSING.md). That notice defines the grant and third-party scope. GPL permits commercial copies and forks subject to its terms; earlier Apache-licensed versions retain their existing grants.

The SAM mask codec in [Sources/SAMMask.swift](Sources/SAMMask.swift) is adapted from Meta’s parser and is distributed under the [SAM License](Resources/ThirdParty/SAM-LICENSE.txt), included with the Mac and iOS apps. The additional permission allows combining that codec with Converse; it does not relicense Meta’s code. Provider-logo notices are in [Resources/ProviderLogos](Resources/ProviderLogos/).
