# Switchboard supervision (build 65)

Mac and Windows homes advertise `switchboard-supervision-v1`. This is additive; the device protocol version does not change. iPad displays traffic but does not execute sessions or supervise hosts.

`tell` and agent `tell[]` accept optional `replyExpected: bool` and `inReplyTo: UUID`. A request uses its delivery UUID as the correlation ID. A reply must come from the expected authenticated session. Acceptance means persisted on the target home, not read. Older homes explicitly reject tracked deliveries at the sending home; ordinary tells continue to work.

Receiving homes persist obligations with their queued prompt IDs. Starting a prompt changes its request to submitted; a correlated reply resolves it after local persistence or a remote queued receipt. Successful completion without a reply gets 30 seconds of grace, one corrective prompt, and then one notification to agents watching either participant if still unresolved after another two minutes. Watcher scope and paused queues are preserved. Recovery notices do not ask for replies. Restart cancels uncertain running submissions, retains queued work and consumed recovery attempts, and does not replay an external turn.

For reciprocal queued tells, including ordinary tells without replyExpected, both sessions must have been quiet for two minutes and have eligible queues. The home injects an existing item, preserving draft and attachment state. Recovery is persisted before injection. Local pairs mark both queue entries; distributed pairs elect the lexicographically smaller canonical global session address so only one home acts. Human-paused queues, provider input/approval waits and recently active sessions are excluded.

`participant.queue-watch` carries `{groupID, entries:[{target,source,delivery}]}` with at most 128 entries/64 KB, no prompt text. Each entry describes an eligible queued delivery on the reporting home, destined to a session on the receiving home. Reports are accepted only from authenticated, non-control group peers advertising the capability; the sender home of every target and local home of every source are checked. Evidence expires after 15 seconds and is cleared on disconnect. Empty reports withdraw eligibility. Reports carry no authority to unpause a queue or approve provider input.

Traffic summaries are a presentation layer; stored text, provider input, copies and exports retain full content. Desktop hover and iPad transcript tap disclose the original message. Desktop local message-number hover uses recorded timestamps; no time is invented for legacy or remote messages without timestamps.

## Linux integration

This change is on canonical main, separate from feature/linux-home. When integrating its C# host, bind `DeviceSyncService.CanSuperviseSwitchboard` to the same admission/shutdown gate as ordinary work, and run AgentRuntime.Tick on its serialized state executor. Do not start corrective turns during update drain or probation. Linux release/acceptance is not claimed by this change.

## Tell versus ask

Natural language “tell MuseConverse …” sends a one-way message. “Ask MuseConverse …” requests a correlated answer, blocker, or explicit decline. CLI sessions emit `command: "tell"` or `command: "ask"` in the existing whole-reply converse fence. Ask always enables `replyExpected`, even if false was supplied. Existing `tell` plus `replyExpected: true` remains supported. Agent JSON uses its existing `tell` array with `replyExpected: true` for asks.

Transport acknowledgements still report acceptance or failure; they never count as an answer and do not create an acknowledgement turn. A receiver answers using `tell` with `inReplyTo` set to the request UUID. Teaching instructions and subsequent CLI turns explain the distinction, so existing enabled sessions learn it without a separate teaching turn. Names are resolved from the live directory, never guessed.
