# Group participant control, version 1

Capability: `participant-control-v1`. This first implementation is Mac-only; Mac homes additionally advertise
`agent-host-v1`. Old homes remain viewable but cannot receive these operations;
the directory reports `canTell: false`. No iPad or Windows release is part of this change.
These envelopes are independent of display leases and never carry an epoch.

All operations require the existing authenticated Noise connection, active
membership in the same current group on both ends, a non-control-only peer, and
this capability. Dissolved/left/removed groups cannot send requests or accept
responses. Unknown optional fields must be ignored. Request and response payloads
are ordinary JSON encoded into DeviceEnvelope.payload (base64 by envelope JSON).

## Tell

`participant.tell`, commandID = delivery UUID, payload:

```
{"groupID":"...","source":"homeID/sessionUUID","sourceTitle":"...",
 "target":"homeID/sessionUUID","text":"...","hop":1,"urgent":false}
```

The authenticated peer must own source.home, the receiving home must own target,
text is 1–32768 UTF-8 bytes, sourceTitle is at most 1000 bytes and hop is 1–8.
The live recipient must have messaging enabled. Agent senders are further fenced
by their own home to explicitly selected targets, at most two tells per model
response, with no urgent sends.

The recipient queue, visible attribution, and receipt are atomically written in
the same sessions archive before acceptance or execution. Dedup binds delivery
UUID to authenticated origin and canonical decoded payload, with no second queue
insert on retry. JSON property ordering cannot change request identity.
`participant.tell.ack` returns `{outcome:"queued"|"rejected",detail:"..."}`.
Queued means persisted, not read or answered. Drafts and paused ordinary queues
are preserved. A timeout is unconfirmed, with no automatic replay.

Pending inputs retain group/home provenance. Validate it again before running
and before injection; combining prompts preserves every contributing origin.
A departed origin/group discards the stale queued input with a visible notice.

`list-sessions` includes local sessions and the union of current-group home
shards, including offline metadata. Local UUID addressing remains compatible;
remote `id` is the full global ID. Entries include home identity/name, online,
messagingEnabled and canTell. No display lease is acquired for discovery/tell.

## Evidence, creation and agent controls

`participant.request`, commandID = operation UUID, payload:

```
{"groupID":"...","action":"agent.create","title":"Converse Steward"}
```

Actions:

- `inspect`, target = global session ID: last 20 submitted messages, each capped
  at 4000 characters, title, busy and status. No editable draft, attachment paths or credential stores. Submitted text is
  sent as explicitly selected evidence and can itself contain user-provided paths. The agent's home requests only selected
  scope and rechecks scope and group membership after awaits before model input.
- `agent.create`, title = 1–200 UTF-8 bytes: one paused agent, empty scope,
  home-local API credentials; response.target is its full global ID.
- `agent.settings`, target: return configuration without secrets.
- `agent.configure`, target + settings: validate current revision and scope,
  save only on home. A stale revision is rejected without resetting spent runs.
- `agent.run`, target: persist one reserved run and queued prompt, respecting
  paused queues; repeated operation IDs cannot spend twice.
- `agent.widget`, target: show the optional scoreboard window on its home.

`participant.response`:

```
{"groupID":"...","outcome":"completed|rejected|uncertain","detail":"...",
 "target":"homeID/sessionUUID","evidence":null,"settings":null}
```

Evidence is `{globalID,title,busy,status,messages:[{id,role,text,imageHashes:[]}]}`.
Settings are `{objective,repository,model,watched:[globalID],intervalSeconds,
remainingRuns,enabled,generateArt,speak,discord,fileTriggers,revision}`.
Revision is an unsigned integer. It advances for configuration/control changes
and autonomous budget consumption. Interval is >=60 seconds, budget is 0–1000,
scope is <=64 valid local/current-group participants, objective <=16000 bytes.

Mutations atomically persist both result receipt and effect in the home archive.
The origin persists operation identities and requests before sending in
`participant-outbox.json`. Unconfirmed identical requests reuse the saved UUID,
including after restart; nothing replays automatically. Responses must match the
authenticated home, operation UUID and current group. Read operations are not
persisted. No keys or login stores are transferred.

## Agent runtime constraints

Scheduled runs reserve and persist budget before enqueue. Incoming agent tells,
Run once and opt-in file events share that autonomous budget; direct human chat
is still available with no automatic runs left. Queues and busy state prevent
overlap. App restart schedules the next interval rather than replaying missed
ticks. Model output cannot execute a second switchboard command from its prose.

File input is opt-in at `Agents/<sessionUUID>/Inbox/*.json`, under Converse's
application-data folder. A regular non-symlink file <=16 KB contains
`{"id":"event-UUID","text":"1–8000 UTF-8 bytes"}`. Event UUID, provenance and
pending prompt are saved before the file is consumed. Duplicate UUIDs do nothing.
An invalid event or persistence failure pauses file input and raises attention.
No inbound network webhook listener is added.

The widget stays on its execution home; taking a transcript elsewhere does not
move it. Normal inline images and blob transfer carry generated art to viewers.
