# Switchboard reference

The [user guide](../README.md#messaging-between-sessions) introduces teaching, Tell and Ask. This page describes the command and delivery contract.

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

Tells do not acquire a display lease. The recipient must have session messaging enabled on its home; ordinary tells preserve paused queues and drafts. Acceptance means **persisted in the recipient queue**, not read or answered. Duplicate delivery IDs do not enqueue twice. Offline/out-of-group targets fail visibly; an unconfirmed send is not automatically replayed. See [the wire contract](../docs/participant-control.md) and [agent design](../docs/agents.md).
