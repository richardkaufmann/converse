# Meta integration reference

**Reach your coding workspace from Muse mobile through Jolly.** Ask for a Converse agent by name, get the current status of its selected sessions, and receive its response and available scoreboard art on your phone. The phone is Meta’s Muse client; Converse supplies the authenticated bridge to the agent on your Mac. This is the same multi-provider workspace: a Meta-powered agent can monitor authorized Muse, Claude Code, and Codex sessions together.

Meta also powers work inside Converse itself. Muse coding sessions run through **Muse Code**, and agents selected to use the Meta API call **Meta Model API** directly. Other agents use their selected Muse, Claude or Codex CLI login, with native research tools disabled; there is no automatic Meta search fallback. These are distinct integration paths:

| Feature | Model and transport | Calling code |
| --- | --- | --- |
| Muse coding sessions | Muse Code’s selected Spark/Wonder model via `muse serve` and MSP `turn/start`; the footer reports the resolved model from the CLI | [Muse connection](../Sources/MuseConnection.swift), [status and model catalog](../Sources/MuseStatus.swift) |
| Meta API agent reasoning and optional web search | Configurable model, default `muse-spark-1.3`; `POST https://api.meta.ai/v1/responses` | [Mac API client](../Sources/Agents.swift), [Mac agent runtime](../Sources/AgentRuntime.swift), [Windows/Linux agent runtime](windows/src/Converse.Core/AgentRuntime.cs) |
| Scoreboard art | `muse-image-1.0`; `POST https://api.meta.ai/v1/images/generations` | [Mac API client](../Sources/Agents.swift), [Windows/Linux agent runtime](windows/src/Converse.Core/AgentRuntime.cs) |
| Mac speech recognition | `muse-voice-transcribe-1.0`; `POST https://api.meta.ai/v1/asr/transcribe` | [Voice input](../Sources/AgentVoice.swift) |
| Muse mobile / Jolly access | Named-agent routing, request status, and returned art through Converse’s own bridge; the selected agent then uses the reasoning path above | [Jolly routing](../Sources/Jolly.swift), [bridge and connector schema](../scripts/jolly_bridge.py) |

For a demo, keep the Muse session’s resolved model visible while it completes a task. Spark’s current API model ID is `muse-spark-1.3`; Wonder’s is `muse-wonder-1.0`. Wonder Full is a Muse Code subscription option, not a Model API model. The installed CLI’s catalog and the model shown for the actual turn are authoritative; do not label one run as both Spark and Wonder. See [Meta’s model catalog](https://dev.meta.ai/docs/models).

Voice input uses Meta transcription; spoken replies use Apple speech synthesis. Jolly’s mobile access is a connector integration, not an embedded Muse mobile SDK or a replacement phone app. Art is returned when available, and pending work remains pending until the home produces a result. See [Jolly setup](../README.md#jolly-mac) for deployment and access details.

The [demo storyboard and implementation evidence](../docs/demo-storyboard.md) distinguish the original Mac prototype from the agent, voice, art, mobile bridge and distributed work added during the build period. The iPad image tools also use `muse-spark-1.3` for editable descriptions and `sam-3.1` for text-prompted object masks and transparent cutouts through the Responses endpoint, independently of the session model ([calling code](../Sources/ImageAssist.swift)). Spark Open and Glimmer are not implemented integrations.

