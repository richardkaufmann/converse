# Agent plan: sessions with initiative

Status: approved design, with a Mac-only implementation. The Mac
harness now contains home-run bounded loops, selected local/group session evidence
and messaging, remote agent creation/configuration, file events, attention and
scoreboard art. Validation and release status belong to the release notes. Windows
and iPad work is explicitly deferred. Remote creation of ordinary CLI sessions
remains future work; this change adds agent creation only. The original broader
cross-platform design follows below.

## Sessions, creation and groups

An agent is a **session with initiative**: the same transcript, human conversation,
queue, pane placement, persistence, export and switchboard identity as a normal
session, plus a loop and external stimuli that can initiate work. Group is the
fabric heading; agents remain participants associated with their home device.

Any device can initiate creation of a session or agent. Creation associates the
new participant with the creating device's current Converse group. Its execution
home is explicit: default to the creating device when it has the required runtime,
or select a capable home in that same group. For example, a viewer can create a
CLI session on a desktop home. An ungrouped device can create local participants.
Execution capability, OS lifecycle and credentials still belong to the selected
home; creating or viewing remotely does not migrate the runtime.

An agent's group membership follows its home device's current group, rather than
keeping a stale copy of the group selected at creation. Leaving a group preserves
the home agent and its local work while removing old-group visibility and routing.
Joining another group makes it available there under the same home/session identity.

## Messaging and visibility

Agents use Converse's existing **tell switchboard** to ask questions, report
progress and poke other sessions or agents. Eligible targets are local sessions
and participants in the current group. Explicit watched/allowed-target settings
further restrict that scope; new agents do not automatically read every session.

Use live directory discovery and globally identified participants
`homeDeviceID/sessionUUID`, rather than a static list of titles or bare UUIDs.
Group membership and target scope are enforced by the host on lookup and delivery,
including queued delivery. Stale targets from a former group cannot receive a
message through remembered names or automatically replayed requests. Tell queues
normally, preserving recipient drafts and paused queues. Existing interruption
semantics and message-chain limits apply.

Mac supervisory actions use `recover: [{target, delivery}]` in the normal agent response object, with at most one recovery per activation. `switchboardDeliveries` supplies authenticated local delivery IDs, current state, `canRecover`, and a blocker reason for selected sessions. The host rechecks scope and eligibility at execution, so stale model evidence cannot interrupt a session that has since made progress. It injects the existing queued item or a host-written reminder for an unanswered ask, never arbitrary model-supplied text. This shares the automatic supervisor's persisted single-attempt allowance and two-minute cooldown. Pauses, approvals, sign-in, compaction and spoken conversations prevent intervention. Successful tells are complete without a return message. Remote targets are explicitly refused by this action in the current Mac release.

A parked agent can work and receive tells. Sending a tell does not acquire a
display lease or steal its pane. An agent's transcript can be displayed on any
device in its group, using the same single-view/controller and takeover rules as
other sessions. Moving the view leaves the loop and execution on its home.

## Initiative and conversation

Humans talk to agents in their normal session pane; agents reply there. Voice
input and emotionally directed speech output are optional interfaces to that same
conversation. Goals, success criteria and permitted session scope are configurable
through conversation and Agent Setup.

The home runs the loop while Converse is running, with an explicit per-activation turn
limit, interval, pause/run-once controls and no overlapping runs. External stimuli
can schedule work through the same bounded queue: initially file-drop or URL events,
with authenticated webhooks/connectors as later adapters. Inputs from other agents
or external systems retain their provenance. Attention uses the existing yellow
scheme, including a highlighted parked row, with optional Discord notifications.

## Widgets and inline images

An optional separate widget window **defaults to the agent's home device**. Viewing
its session on another device does not automatically move, duplicate or reopen
that widget. Any future remote-widget placement is an explicit choice separate
from transcript placement.

The agent can generate artistic, sentiment-driven progress images for its widget,
with real metrics rendered legibly alongside them. Art generation happens at the
home and follows the configured budget and refresh policy. A separate widget is
optional: an agent can also display an **ordinary inline image in its text pane**.
That uses the app's normal image/attachment rendering and cross-device transfer;
it needs no separate agent-image protocol.

## Implementation order

1. Extend participant references and agent watched targets from local UUIDs to
   home/session IDs; migrate existing local references without changing identity.
2. Add capability-advertised, authenticated, idempotent session/agent creation on
   a selected home, accessible from any group device. Reference home-local login
   or API credential profiles without copying secrets into session metadata.
3. Extend switchboard discovery, tell delivery and scope checks across the group,
   independent of display leases. Preserve the current local path.
4. Add home scheduling/external-event adapters, shared attention presentation and
   remote agent settings; retain limits, saved drafts and existing queue behavior.
5. Keep widget windows at home by default, reuse ordinary inline-image flow, and
   finish optional voice/Discord controls.

The first demonstration remains **Converse working on Converse**: a user-scoped
project steward watches Converse Development and MuseConverse, checks their work
against stated success criteria, asks for evidence, and reports repository status
with sentiment-driven art. Distinguish measured visitors/downloads from actual
app users, which are not currently measured.

## Acceptance checks

- Create from another group device; exactly one participant appears under the
  selected home, and retries never duplicate it or move credentials.
- A loop or external event starts work without a human prompt, obeys its budget,
  and preserves a separately edited draft.
- An agent can tell an allowed local or same-group participant, including while
  parked, without taking its display. Other-group targets are rejected.
- Leaving/changing/dissolving a group immediately removes old-group routing and
  visibility; stale queued messages cannot leak into that or a new group.
- Take the agent's session on another device: the transcript moves, the home loop
  continues, and its widget stays on the home by default.
- An inline progress image renders through the ordinary transcript pipeline on
  local and remote panes, with the same attachment behavior as any session.

## Web research and general scoreboards (Mac)

Agents may use enabled Muse, Claude or Codex CLI logins, or Meta Model API credentials. CLI-backed agent runs receive Converse-supplied evidence with native web/shell tools disabled. Only the Meta Model API route enables hosted `web_search`, with at most four built-in calls. Saving a Meta key does not add search to a CLI-backed agent. No extra search credential is required. Users can disable research in
Agent Setup. Tool output remains untrusted evidence; selected session scope and
host-enforced messaging limits still apply. Progress messages emitted during
search are not treated as the actionable final JSON.

Scoreboards can contain user-requested metric labels, values, source URLs,
source-reported observation times, a short summary, and sentiment. The host
accepts metric URLs only when returned by that run's search results/citations;
unavailable or unsupported values stay Unavailable. This is source-grounded
model extraction, not an independently verified exchange feed. Observation
times and retrieval time are distinct. Summaries/art are model interpretations.
Requested logos and humor are allowed; data stays in legible overlay cards.

## Jolly routing (Mac)

Converse owns the authenticated connector bridge and its file journal. No other
application is a fallback. The bridge lists eligible local agents, accepts an
explicit name/ID, and asks for clarification when ambiguous. Agent selection
does not acquire a display lease. Each admission receives a fresh per-activation limit;
busy/paused agents refuse without interrupting or changing the draft. Only the
agent's already-authorized session scope is available to its run.

Stable request IDs prevent repeat execution. The app stores its active request
before starting a model call; after restart it reports an interrupted request
as uncertain instead of replaying it. Replies remain available for polling.
Closing the app withdraws its directory heartbeat. Explicit phone messages
use the Converse-owned outbox; GET is non-consuming, and acknowledgements are
separate. The existing tunnel and bearer credential are retained at handoff;
the old service is disabled and its unread outbox is imported without deleting
the original. No automatic fallback is installed.

## Hands-free conversation (Mac)

Start talking explicitly owns one local agent’s microphone turn. Sustained audio plus 1.5 seconds of silence produces one transcribed human prompt; idle silence never submits. Thinking and speech playback keep capture off. Only the correlated response can speak and re-arm capture, after a short echo guard. Stop, pane removal, failure, and app exit fence all late permission, transcription, model, and speech callbacks. Spoken turns preserve the separately edited draft and do not consume future scheduled checks. Loop ticks, file events, Jolly requests, and queued messages cannot take over that listening session. Dictate remains a review-before-send alternative.


## Deterministic schedules

Loop settings accept either a numeric interval (minutes in the UI, seconds on the wire) or a supported text schedule. The editor shows the interpreted rule and the next three runs before saving. Examples: `every 20 minutes while the US stock market is open`, `every 2 hours on weekdays between 9am and 5pm`, and `daily at 09:00 in America/New_York`. Unknown conditions are rejected, never silently ignored or evaluated by a model.

Calendar windows anchor intervals at their opening time. The NYSE regular-session calendar uses New York time, holidays and early closes from the [official calendar](https://www.nyse.com/trade/hours-calendars), verified October 29, 2026 and bounded through 2028. It does not detect emergency closures or individual trading halts. An exhausted calendar pauses the loop visibly. Daily schedules skip nonexistent DST times and use the first occurrence of repeated times.

There are no overlapping runs or catch-up bursts. Relaunch preserves the saved deadline. An overdue enabled agent runs once when its queue and schedule window permit; fixed intervals then count from that catch-up check. Future deadlines retain their remaining wait. The last reserved loop time is persisted to recover a missing deadline, and unrelated settings saves preserve the deadline. Paused loops stay paused. Queued loop checks revalidate their window before starting; a skipped check does not consume a future activation. Human requests, Run once, and allowed external stimuli are not restricted by the timer window. Text schedules require the home capability `agent-schedule-v1`; older editors cannot silently erase them. Settings are revision checked.


## Cross-platform release boundary (0.5.22)

Mac and Windows host agents; iPad controls them on a desktop home. All three display attention, loop status, transcript images and scoreboards. Windows uses Windows Credential Manager for its Meta key and the same bounded direct Responses/Image APIs, with synthetic API and live loopback coverage. Voice, Discord and file triggers remain Mac-home features for this release; Windows explicitly rejects enabling unsupported options. Jolly continues to use the existing Mac bridge. No iPad background execution is promised.


## Discord bot integration

Mac homes use one `discordBot` credential in the Converse Agent Keychain service,
shared by all local agents. No KAOS credential, config, service or cursor is used.
The former webhook credential is no longer read; it is not converted to a bot token.
Each agent selects a numeric channel ID plus separate read and alert permissions.
Other devices can view these agents; bot credentials and channel configuration are
set on the Mac home. Windows hosting remains unsupported for Discord in this release.

Create a dedicated Converse application/bot in Discord's Developer Portal, enable
Message Content Intent, and invite it to the desired server with View Channel,
Read Message History, and Send Messages for the chosen channel. Store its bot token
in Agent Setup, never in a transcript. With Discord Developer Mode enabled, use
Copy Channel ID for the destination. Test Discord checks the bot identity/history,
posts one labeled non-mention test message and finds its exact text through channel
history. It leaves that marker visible and does not advance agent cursors or save
credentials. Reading the bot's own test does not prove access to all human content;
the UI states the Message Content Intent requirement separately.

Ordinary monitoring reads during manual/loop runs; mention routing has its own
independent listener described below. Its first read includes up to 50 recent messages; later reads
request up to 100 after its saved message ID. A full batch is explicitly marked
as potentially incomplete. Cursors advance only after a successful run and are
stored with the agent. Each agent has its own cursor; concurrent identical reads
share one host request. Bot and webhook messages are excluded from model evidence,
and channel text is untrusted evidence, not permission to operate other sessions.
Alerts use the same bot token, are labeled with the agent name, and disable mentions.
HTTP 429 starts a client cooldown; uncertain posts are never automatically retried.
The app must remain open for agent runs and Discord reads to occur.

### Mention routing

Mac Agent Setup adds an explicit per-agent mention opt-in and channel default.
Anyone able to post in that configured channel may address it. A real bot mention
must start the message; bot/webhook authors and incidental mentions are ignored.
`@Converse question` uses the default (or the sole enabled agent). Exact names work
as `@Converse Agent Name: question` or `@Converse ask Agent Name question`; UUID
plus colon disambiguates duplicate names. Ambiguous/unknown targets get a usage
reply and are never broadcast or silently sent to the default.

One Mac-host listener polls each distinct enabled channel about every five seconds
while the app is open. This is REST polling, not a Gateway connection. Token
identity and channel access use the existing client and rate-limit cooldown.
New enablement establishes a start boundary; old mentions are not replayed.
Reads paginate full history batches rather than jumping over bursts. DMs and
threads with no explicit channel-ID configuration are out of scope.

`Discord/mentions.json` is a local, atomic request journal, separate from ordinary
monitoring cursors. Accepted requests survive restart, are deduplicated by Discord
message ID, and wait until the target is idle with an unpaused, empty local queue.
Each starts outside the loop schedule with a durable reservation and a fresh activation limit. At most
20 commands can wait/run at once; waiting requests expire after ten minutes.
Scope and budget are checked again at dispatch. Completed receipts are retained
for a day and cursors provide the permanent duplicate barrier.

Public mention turns receive only their question and up to 20 recent channel
messages, plus optional public web research. They receive no private objective,
notes, transcript/session evidence, GitHub credentials or agent action permissions.
Their accepted output is a public reply and, only with the per-agent sharing opt-in, a host-rendered scoreboard or existing mood image. Arbitrary model-selected files cannot be uploaded. Thus they can discuss publicly posted
progress but cannot reveal unpublished agent context or trigger switchboard tells.
The reply references its source message and disables all pings. The host persists
the send attempt first and uses Discord's enforced nonce as an additional duplicate
barrier. An interrupted model run reports uncertainty without replaying it; an
uncertain POST is not automatically repeated. The session shows a delivery notice.

Protocol reference: [Discord message API](https://docs.discord.com/developers/resources/message)
and [rate limits](https://docs.discord.com/developers/topics/rate-limits).

### Per-loop limits and iPad controls

Schedules continue until paused; `maxTurnsPerLoop` is an optional archive/wire field replacing the lifetime meaning of `remainingRuns`. Old counters remain decodable, with an exhausted counter becoming a minimum one-turn cap, but disabled loops stay disabled. Each activation currently makes one model response with bounded hosted search and output tokens. It never automatically chains another response. The cap is a ceiling, not a request to repeat the objective N times. Queue capacity, message deduplication, the 100-hop switchboard bound, and pause-on-error remain in force.

iPad Agent Setup uses explicit Save/Cancel. Save and run once persists the edited schedule first, and only requests the run after home acknowledges it. Unsupported text schedules display the parser error. The clipboard button uses the system clipboard; the adjacent Photos button opens the library.

### Sharing session information in a private channel

**Share session information** is a separate per-agent opt-in, available in Mac and iPad Agent Setup. It allows a mention response to use that agent's objective, working notes, scoreboard and recent submitted conversation. It excludes unsent drafts, credentials and other sessions' transcripts. The host checks Discord's channel and guild-role permissions before supplying the context, then rechecks privacy and the option before posting a generated reply. Missing permissions, API errors, public channels and unsupported channel types do not grant sharing. Turning the option off also blocks already-generated private replies awaiting delivery.

For this feature, a private channel is a guild text or announcement channel where the `@everyone` role lacks effective `VIEW_CHANNEL`, following Discord's [permission rules](https://docs.discord.com/developers/topics/permissions). The bot does not change channel permissions. The existing **Share scoreboard and mood image** option remains separate and explicitly allows those artifacts to be requested without sharing conversation context.

Natural requests such as `@Converse ask converse agent for current status` use the channel's configured default. Explicit agent names take precedence; unknown names are not guessed. Editing an already-processed Discord message does not trigger it again: send a new mention.
