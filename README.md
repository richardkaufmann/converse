<p align="center">
  <img src="docs/converse-icon.png" width="160" alt="Converse robot logo">
</p>

# Converse

Converse is one app for conversations with **Muse, Claude Code, and Codex** (AI assistants from Meta, Anthropic and OpenAI). Each conversation is a **session**: a place to give a model a task, read its answers, and keep working with it. Answers appear as formatted, selectable text, with images alongside them.

its standout features

1. **It’s multi-session.** You can have many sessions open simultaneously, and have up to three of them up, side by side, in each of the app’s desktop windows.
2. **It’s multi-provider.** Meta, OpenAI, Anthropic can be mixed and matched as desired.
3. **It’s multi-system.** Sessions can run on Mac, Windows and Linux. The app UI runs on Mac, Windows, iPads and iPhones.
4. **It’s distributed.** Systems running Converse can join peer-to-peer **Groups**. Each app instance can “take” (display) sessions from any system in the Group. Groups are persistent. Systems rejoin when they come back online, including iPhones and iPads, as long as they can reach the other systems.
5. **It hosts agent sessions.** These sessions have initiative and can start periodically or via an external stimulus.
6. **It’s chatty.** Sessions can talk to each other. “Tell” sends a message; “Ask” expects a response. Agents can supervise groups of sessions, and Converse can “force inject” prompts to break logjams. Agents also have rich tooling to assess progress toward shared goals.
7. **It talks to the outside world.** Agents interact with GitHub (to track PRs, issues, updates), Discord (to send and receive messages), and Meta’s Muse mobile app (“Jolly” can talk to agents and get updates). They can do outbound searches and assess sentiment too.
8. **It has polish.** Images can be pasted into sessions—and even analyzed with a right click using Meta’s segmentation toolkit—allowing only pertinent content to be passed to session prompts. Responses’ Markdown output is converted to tables, headings, etc., providing a pleasing experience. Right-click to copy entire prompts and responses, or export traffic across sessions and systems in a consolidated, well-formatted document. Quit and restart the app: your sessions survive!
9. **You can enter into spoken conversations with your agent.**
10. **It has an “opinionated” security posture.** The basic thesis: if you can reach another system’s Converse port (normally TCP 48721), you can ask to join its Group. Messages are encrypted with ChaCha20-Poly1305, and both sides approve pairing—it feels like pairing a phone to a car! Once paired, you’re trusting that system with your sessions. You’ve been warned, though! Read the [security section](#security-and-privacy) to make sure this app is for you!

These features combine in interesting ways. There’s a built-in support agent that knows this README, and can help you avoid fiddly UIs to configure providers, agents, etc. You can talk with this support agent via Discord or Muse Jolly. And it checks daily for bugs and version updates of the app! This uses a teaching prompt injected into a normal Converse agent.

You can build an app that is multi-system. One session on a Mac, for example, can “tell” a Windows session to finish producing a Windows version of the app and install it. That’s how we build Converse!

You can build Linux apps and services on a Mac or PC without multiple windows, or having to deal with complex different UIs. Since Linux is headless, you log into it to set up Converse and its providers. From there you can start sessions on those providers from your Mac or PC.

The cross-system session support also greatly eases development. Ask a session to generate an image, paste it into another session running on a different system. It just works!

The rest of this README walks through installing Converse, and then using it. A friendly suggestion: AI wrote what follows (it’s kind of grim, to be honest). Let AI read the details! You tell App Support what you want to do; it can work through the instructions with you. Install the app on a Mac or Windows PC, and the support agent will walk you through provisioning your first provider on that system. From there you can just chat and have it help set up multiple systems (including headless Linux), agents, whatever. It’ll ask for what it needs. You can give feedback too: “File a bug about blah blah blah” gets a report ready for GitHub. You review it and send it. No Discord account needed.

Enjoy.

This guide is also bundled as searchable, offline **Converse Help**: open **Help → Converse Help** on desktop, or **Help** in the mobile menu. The [security and privacy section](#security-and-privacy) explains data sharing and key storage.

## Download

**On Mac:** [download the latest Mac preview](https://github.com/richardkaufmann/converse/releases/latest), unzip it, drag **Converse.app** into **Applications**, and open it. Current release downloads are Developer ID signed and notarized by Apple. The universal app targets macOS 14 or later on Apple Silicon and Intel; direct hardware testing has been on Apple Silicon.

**On Windows:** use a Windows preview supplied by the project, or build the Windows app from source. There is not yet a general-purpose Windows installer. The [Windows build instructions](windows/README.md#build-and-test-on-the-windows-box) are for developers, not a required step for someone who already has a preview.

**On iPhone or iPad:** install an invited Converse build through Apple's TestFlight app. There is no public testing link at present. These apps display and control work running on a computer; get your first desktop session working, then follow the Group setup section below to connect the phone or tablet. Developers can also [build the iOS app](iPad/README.md#install-wirelessly).

The repository and release links currently require access to the private repository. A 404 can mean your GitHub account does not have access; it is not a reason to enter credentials into a chat. If you need repository access or a TestFlight invitation, ask Richard Kaufmann, the project owner, through the channel where you received the preview. No accounts, keys or conversations are included in a download.

## First launch

You do not need Discord to use App Support, set up Converse or report a bug. App Support lives right in Converse. Discord and Jolly are optional ways to reach agents later.


You need **one working provider** before you can ask an assistant for help. A provider is the service behind the model: Meta Muse, Anthropic's Claude, or OpenAI's Codex. Its account and usage charges are separate from Converse.

On a new Mac or Windows installation, Converse shows **Converse App Support** (the built-in assistant for help with this app) and asks you to pick a provider. Choose just one:

1. **Install its command-line tool if needed.** Converse uses the provider's installed program, often called its *CLI*, to connect. Follow the installation link shown by setup, return, and retry the provider choice. You do not need all three tools.
2. **Complete that provider's sign-in.** Converse opens its login flow in Terminal and/or your browser. Finish there, then return to Converse. Do not put passwords, API keys or login codes into the conversation.
3. **Wait for the connection check.** Converse asks the model for one short response. This may use provider quota. A successful login alone is not enough: setup waits until the model actually answers. Failed or cancelled setup stays on this step so you can retry.
4. **Meet App Support.** After the check, setup and teaching text disappear from view, and the support conversation is ready. Try: “What can I do in Converse?” or “Help me create a session for my project.”

For a problem involving another Group system, App Support can find its support agent and ask for a scoped, read-only health report. It uses live session IDs, reports unavailable peers, and does not turn a peer message into permission to change settings.

Ask App Support to “open a Muse coding session” and it creates and displays one, using your saved login. Ask how to do it and it explains the steps. It can also read installed Help, inspect safe settings, and open setup controls. It can perform supported setup actions you request and report their result. You still complete provider sign-in and enter secrets yourself. A saved setting is not proof that an external service is connected.

**Existing installations:** upgrading preserves your sessions and does not rerun onboarding. On Windows, choose **Help → Converse App Support…** to open or set up your support agent. Existing sessions keep their logins. New sessions and agents default to the provider login verified during setup; you can choose another login in setup. Demo and the normal app keep separate credentials. On either desktop, App Support can use any enabled provider; it does not require Meta or Discord.

### Report a bug

Tell App Support what went wrong and ask it to file a bug. It prepares a title and description and opens a report you can edit. You can also choose **Help → Report a Bug on GitHub…** on desktop, or **Report a Bug on GitHub…** in the mobile menu.

**Recommended: save a GitHub token once.** A token is an access credential you create on GitHub. Paste it into the masked **GitHub token** field in the report window or Agent Setup, then save. Converse manages it with your other credentials. After that, review your report and click **Submit report**; Converse files it and gives you the issue link. You do not need to leave the app or sign in each time.

The token needs access to `richardkaufmann/converse` and permission to create issues. For a fine-grained token, select the repository and **Issues: read and write**. Read-only monitoring access is not enough. [GitHub’s token guide](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens) explains creation and expiry. GitHub currently limits fine-grained tokens for outside collaborators and contributions to other owners’ public repositories; in those cases a classic token may be needed. A classic token’s `public_repo` scope covers public repositories; private-repository access needs `repo`, which is broader. Choose the smallest access that works for your account and repository.

**Fallback: submit it yourself.** Without a token, Converse still prepares the report. Use **Copy description**, open GitHub, sign in, paste the text and submit. **Continue on GitHub…** can prefill a short report for you. This is the backup path; saving a token makes regular reporting easier. Mobile currently opens GitHub’s report form directly.

Reports go to `richardkaufmann/converse`. While the repository is private, your GitHub account needs access; a login alone does not grant it. A report window or browser draft is not yet a filed issue. If sending fails or times out, check the issue list before trying again: Converse does not automatically repost. For a description too long for a browser link, use **Copy description** and paste it into a new issue on GitHub.

**Help us reproduce it without sharing your life.** In the desktop report window, **Add diagnostic summary** adds app/OS versions and Group/session counts. It leaves out Group and device names, IDs, addresses, file paths and conversations. **Remove likely secrets** locally removes common token/key patterns, email addresses, home paths and IPv4 addresses from the draft. This is a useful first pass, not a guarantee of anonymity: read the whole report, edit or remove anything private, then approve it with **Submit report**. The report may become public. An agent can help summarize symptoms, using Host A/Host B instead of real names; do not paste keys or raw logs into a model just to ask it to scrub them.

Only the report text you review is included. Logs, screenshots, attachments and other conversations are not added automatically. If you use the browser route, its prefilled report link contains that text and may appear in browser history. Keep secrets and unrelated private information out of reports. Saved GitHub credentials stay in the Mac Keychain or Windows Credential Manager; they are never given to the model or placed in a report. Discord is not involved.

Copying a selected passage on Mac, iPhone or iPad preserves link destinations in plain-text paste—for example, `Cursor Agent (https://cursor.com/docs/agent/overview)`. Copying a whole response also preserves its Markdown links.

## Set up your first coding session

A **coding session** connects a conversation to a project folder on your computer. The assistant can inspect or change files there according to the permissions you select. App Support is for help with Converse; create a separate session for your project.

1. Click **+** beside **this device** in the left sidebar and choose Muse, Claude or Codex.
2. Give the session a useful name, such as “Website — Claude,” and select your project folder. Choose the login you already set up, or **New login…** if you want a separate account.
3. Create the session. Creation itself sends no prompt. Use **1** beside its name to display it in the first conversation pane if it is not already visible.
4. Check the footer's **model**, **effort** and **access** settings. Model selects which model answers; effort controls supported reasoning effort; access controls what its tools may do. Begin with restricted access while you learn. Available choices depend on the provider and account.
5. Type: “Read this project and explain how it is organized. Don't change any files yet.” Press **Return** to send. On Mac, **Command-Return** or **Shift-Return** adds a new line instead.
6. Confirm that the response describes the intended project. Then ask for a small change, review it, and continue in the same session.

Muse can show approval questions in the pane. Claude and Codex run without their normal terminal interface here, so their full terminal approval dialogs are not embedded. If a task is blocked by permissions, review the access setting rather than assuming an approval window will appear.

## Use

### Read, type and interrupt

Your editable draft is **blue** at the bottom of the conversation. Sent prompts become *italic* in the normal text color; responses render headings, lists, code and tables. A spinning rainbow indicator means work is in progress. A waiting approval needs your attention; **Stop** interrupts an active turn.

You can type the next request while the assistant works. Sending it adds it to a **queue** (the list of messages waiting to run, shown above the transcript). **Inject now** interrupts the current turn and sends that queued message next. **Inject all** sends the queue together in order. Stop also pauses the queue; use **Resume queue** when ready. Drafts, queued messages and attachments survive relaunch. Quitting preserves the conversation; new work needs its home app or Linux service to be running.

Scroll up to read earlier messages without being pulled back down by an idle timer. Typing in that pane or choosing **Jump to latest** returns you to the draft. Right-click a message to copy the whole prompt or response, or select just the text you want.

### Keep several sessions visible

Create another session with **+** when you want an independent task or a second opinion. **1 / 2 / 3** place a session in a pane. **P** parks it: the pane closes but work continues. **X** closes the session after confirmation and stops its work; Mac **File → Restore Closed Conversation** can restore a saved recovery copy.

Drag the dividers to resize panes. Changing the number of visible session panes redistributes their widths equally without changing the sidebar width. The pin beside **Conversation** hides or restores the sidebar. Hover a session name for its provider, login, project folder and status; right-click it to rename it.

### Add images and filenames

Paste a screenshot or image, or use **Attach** to choose one. Its preview appears in the draft; **×** removes it. Sending supplies the image to the selected provider along with your prompt. You can ask “What is wrong with this layout?” or “Explain this diagram.” Images returned by an assistant appear in the conversation too.

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

On Mac, choose **File → Export…** and select one or more sessions. Choose prompts, responses or both, and whether to place sessions one after another or interleave them by message time.

**HTML** makes one portable document with formatting and embedded images; open it in a browser to read or print. **Text** preserves Markdown and lists attachment filenames. Exports exclude unsent drafts, account configuration and hidden tool activity. Check the content before sharing it.

## Set up your first agent

An **agent** is a conversation with an ongoing objective. You can talk to it like a session, ask it to check once, or let it check periodically. It uses the provider and model you select, and only the extra information you allow it to read.

### App Support is your first example

**Converse App Support is itself an agent.** On a new Mac installation with build 84 or later, setup turns the verified support conversation into this agent. Right-click its name and open **Agent Setup / Loop…**, or use **… Agent actions → Agent Setup / Loop…** in its pane.

Look at its settings before making your own:

| Setting | App Support example |
| --- | --- |
| Objective | Keep Converse up to date; identify serious bugs and explain their impact and the next step. |
| Model and login | The provider you verified during setup; it need not be Meta. |
| Repository | `richardkaufmann/converse`, so checks can use GitHub releases and open issues. |
| Automatic loop | Enabled, every **1,440 minutes** (24 hours). |
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
6. Only then enable a schedule if you want repeated checks. Leave optional integrations off until you need them.

An agent can assess evidence and ask a coding session to act; selecting a CLI-backed model does not give the agent that coding CLI's unrestricted tool environment. If you want it to edit a project, use a coding session for that work and explicitly allow the agent to communicate with it.

## Agents and project scoreboards

### Give the agent evidence for its objective

**GitHub:** enter `owner/repository` in **Repository**, or leave it blank if the job has nothing to do with a repository. Converse fetches repository evidence and supplies it to the selected model. This works with CLI-backed agents as well as Meta API agents. **Test GitHub** checks access without changing the repository. Public polling has limits; private repositories need a GitHub token with appropriate access in the masked field. The Converse repository currently requires that access.

App Support illustrates the distinction: its goal is to notice releases and critical bugs; GitHub supplies the issue/release evidence. A coding-project steward can combine that evidence with the progress reports from the sessions you selected. Neither a healthy model response nor a quiet issue list proves that the app is bug-free.

**Session monitoring:** the selected sessions supply recent submitted conversation and activity status. Unsent drafts and credentials are excluded. The agent can compare what those sessions report against its objective and send messages within its allowed scope. Start with a narrow selection and inspect its first report before enabling a loop.

**Web research:** this currently depends on the agent's execution route:

| Selected agent route | Evidence and research available |
| --- | --- |
| Claude, Codex or Muse CLI login | Conversation, objective, notes and evidence fetched by Converse, including configured GitHub/session information. Native CLI web and shell tools are disabled for these bounded agent runs. |
| Meta Model API | The same configured evidence, plus optional Meta hosted web search when enabled, capped at four searches per run. |

A saved Meta key does **not** automatically add web search to a Claude/Codex/Muse CLI agent. A Muse CLI login alone does not enable hosted agent search, SAM, art or voice transcription. Image tools, artwork and voice have separate Meta requirements; they do not determine which provider reasons about the agent's objective.

### Set a useful rhythm

Use **Enable automatic loop**, an interval or supported text schedule, and **Maximum turns per loop**. That limit applies to each activation; it is not a lifetime allowance. A new or deliberately re-enabled interval starts with one interval of waiting. **Run once** performs a check without enabling a paused loop or moving an already scheduled deadline.

Restarting keeps the saved deadline. Several missed intervals produce at most one catch-up check, followed by the next interval from that check. Calendar schedules still respect their days and time windows. Busy agents and paused queues wait; a failed run pauses the loop and raises attention. Turning a loop off stops future checks but leaves a current turn alone; use **Stop** to interrupt it.

A green loop indicator means scheduled checks are enabled and waiting; a rainbow spinner means work is underway; yellow attention means there is something to review. The footer shows the next check. **Reload settings** refreshes a form if another edit made it stale.

### Read the scoreboard and optionally add art

**Show scoreboard** presents the agent's status and available measurements in **cards** (small labeled panels). With a repository, these can include issues, bugs, pull requests, stars and release downloads. Repository visitors require authorized GitHub access. None of these counts measures actual app users.

For search-backed cards, source links and **observation times** (when the source measured the value) matter: a delayed quote or prior close is not a live price. Unsupported values remain unavailable. **Export widget** saves a portable HTML snapshot with embedded art; it is a snapshot, not a live dashboard.

Optional **mood art** uses Meta's image service independently of the agent's reasoning provider. Supply a Meta key, enable art, and write the desired subject and style in **Scoreboard art direction**. Save and **Run once** to try it. You do not need art for useful reports; App Support leaves it off.

### Voice on Mac

**Dictate…** records up to a minute, sends audio to Meta for transcription, and lets you review it before inserting it into the draft. It needs a Meta key and microphone permission.

**Start talking!** explicitly starts a spoken conversation with an agent. Listening pauses while it transcribes, thinks and speaks. **Stop talking**, parking the pane or quitting ends that conversation. Scheduled checks and incoming messages do not start speech. Spoken replies use Apple's speech synthesis; the selected agent provider still generates the answer.

### Connect Discord on a Mac

Discord is optional. It lets an agent read a chosen channel during checks, post alerts, or answer people who mention it. Begin with one agent and one channel:

1. Create a dedicated bot in [Discord's Developer Portal](https://discord.com/developers/applications), enable **Message Content Intent**, and invite it to your server with **View Channel**, **Read Message History** and **Send Messages** permission in that channel.
2. Enable Discord Developer Mode and copy the channel's numeric ID.
3. On the Mac, open the agent's **Agent Setup**. Put the bot token in the masked Discord field and the channel ID in its channel field. The Mac's agents share that saved bot token.
4. Choose reading and/or alerts. **Test Discord** posts a labeled test message and reads it back; it does not send session content. Save the settings after testing.
5. If you want direct questions, enable **Anyone in this channel may @mention this agent**. Use a real bot mention: `@Converse Project Steward: what needs attention?` A **Default agent for this channel** also accepts `@Converse question`.

Anyone able to post in the configured channel can use enabled mentions. By default, replies use the question and public channel context, not private session history. **Share session information** is a separate opt-in requiring a verified private channel; **Share scoreboard and mood image** is another opt-in and needs **Attach Files** permission. Leave both off unless you intend to share that material.

The Mac app must be open. Mention checks run independently of the agent's loop; pausing a daily loop does not disable enabled mentions. Windows/Linux do not host Discord integration yet. [Detailed Discord behavior](docs/agents.md#discord-bot-integration).

## Jolly (Mac)

**Connect the Meta Muse iPhone app** means letting Meta's phone assistant, Jolly, send requests to allowed Converse agents on your Mac. For example: “Ask Project Steward what is blocking the release,” or “Ask Converse whether the app is up.” General app-health questions route to an allowed Converse App Support agent, which can report the app's state and the connected devices it knows about.

This is optional and separate from the **Converse iPhone/iPad app**. Jolly is a conversational connector; the native Converse mobile app displays session panes. Connecting Jolly does not require changing an agent to a Meta reasoning model.

**This integration still needs operator setup.** It requires a **bridge** (a small background service) on the Mac, an **HTTPS endpoint** (a secure web address the phone can reach), a **bearer token** (the secret that authorizes requests), and a **connector schema** (the description of available actions) loaded into the Meta Muse app. Opening **Converse → Jolly…** alone does not create that infrastructure. The current [bridge installer](scripts/install-jolly-bridge.py) is intended for an operator who has prepared the token and endpoint; it does not provision a tunnel or a Muse account.

Once that bridge is configured:

1. Open **Converse → Jolly…** and allow the local agents the phone may address.
2. Load or refresh the connector schema in Muse so it exposes **Ask Converse**.
3. Ask it to list the available agents, then address one by exact name. If a choice is ambiguous, it should ask which one rather than broadcast.
4. Confirm the request appears in the intended agent's conversation and the reply returns to the phone. Pending is not a completed answer.

Converse must remain open to do new work. The bridge can report that it is offline and serve previously saved replies. A message you explicitly leave for the phone is retrieved when Jolly checks; it is not pushed into a Muse conversation automatically. [Bridge protocol and recovery](docs/agents.md#jolly-routing-mac).

## Messaging between sessions

The **switchboard** lets conversations send messages to each other. Use it when, for example, one coding session should ask another to review a change.

Right-click a session and choose **Teach Session To Talk To Other Sessions**. That enables messaging and gives the model the current rules. Teach each participating coding session. Then type naturally: “Ask Code Review to review this change and report any blockers.”

**Tell** is one-way; **Ask** expects an answer, blocker or decline. Delivery means a message was queued, not that the work was done. Traffic appears as compact orange lines that you can expand or inspect. “Reply needed” means an Ask still needs its matching response; refreshing teaching alone does not resolve it.

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
- Access to this repository. On the Mac, sign in to an authorized GitHub account and obtain the source once:
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

## Security and privacy

**The basic deal: reach it, pair it, trust it.** If your Converse app can reach another system’s Converse port, it can ask to join that system’s Group. Compare the verification number and approve on both sides, just like pairing a phone to a car. Being on the same network—or knowing the port—is not enough to get in. Once you pair, that device can see and control sessions in the Group. Only pair systems you trust with that access.

**Groups are persistent.** Devices remember their membership and reconnect when Converse is running and the network is reachable again. That includes iPhones and iPads. A VPN back to your own network lets you use the Group away from home; see [Take your Group on the road](#connect-your-devices-into-a-group) for the UniFi travel-router option.

**What goes over the wire?** Group messages use ChaCha20-Poly1305 authenticated encryption, with the Noise XX handshake (`Noise_XX_25519_ChaChaPoly_SHA256`) and remembered device identities. Desktop and Linux homes normally listen on **TCP 48721**. Mobile apps and Demo editions can use an automatically selected port; check Converse Groups for the actual port. Discovery helps devices find each other, but **Host or IP** works across a routed network or VPN too. For remote access, use a VPN into your trusted network rather than exposing the Converse port directly to the internet.

That’s the posture. Pairing is an invitation into your workspace, not just permission to look at one window. Read on to decide whether it fits how you want to work.

You also choose which AI provider receives each conversation and what extra material an agent may read. Start with one provider and one project. Add access when you need it. Enter secrets in the app’s masked credential fields, never in a conversation.

Desktop Converse runs sessions and agents on their **home system** while the app is open. A Linux home runs them in its background user service while that service is running, without a desktop window. Local storage does not mean local AI: your prompts and the context needed to answer them are sent to the **provider selected for that session or agent**. That provider's account terms, retention settings and privacy policy apply. Converse does not make a blanket promise that providers never retain data.

**Choose what an agent can see.** An agent receives its conversation, objective and working notes. If you select other sessions in Agent Setup, relevant excerpts from those sessions are also sent to the agent's selected provider—even when those sessions use a different provider or live on another Group member. New agents start with no watched sessions. Repository checks send the repository name to GitHub and supply returned issue/release information to the selected model. Treat private repository content as private data. App Support's daily check uses the Converse repository, runs every 1,440 minutes while the app is open, and starts without watched sessions or mood art. You can pause its loop in Agent Setup. App Support does not hold up Quit: if it is the only active session or scheduled agent, Converse saves its state and quits without a warning.

**Integrations have their own sharing boundaries.** Enabling Discord reading supplies the configured channel's messages to the agent. Alerts and mention replies can send content back to that channel; public mention handling excludes private session history by default. Sharing session information requires an explicit setting and a verified private channel. Enabling Jolly lets the authenticated Meta Muse phone connector submit requests to permitted agents and retrieve replies/images. General Converse health questions route to App Support and may include the Group name and host display names/status. Disable an agent's Jolly access to remove it from this routing. Voice and image features—including SAM—use Meta services independently of the conversation's selected model; the relevant audio/image is sent when you invoke those features. Pasting a key into a credential field does **not** send it to a model.

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
