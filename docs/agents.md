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

A parked agent can work and receive tells. Sending a tell does not acquire a
display lease or steal its pane. An agent's transcript can be displayed on any
device in its group, using the same single-view/controller and takeover rules as
other sessions. Moving the view leaves the loop and execution on its home.

## Initiative and conversation

Humans talk to agents in their normal session pane; agents reply there. Voice
input and emotionally directed speech output are optional interfaces to that same
conversation. Goals, success criteria and permitted session scope are configurable
through conversation and Agent Setup.

The home runs the loop while Converse is running, with an explicit remaining-turn
budget, interval, pause/run-once controls and no overlapping runs. External stimuli
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
