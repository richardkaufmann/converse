# Converse demo plan and implementation evidence

Working plan, 2026-10-31. Richard selected Indie. Final capture, submission and publication still need verification.

## Three-minute cut

| Time | Show | Point to establish |
| --- | --- | --- |
| 0:00–0:20 | Muse mobile/Jolly addresses a Converse agent by name and asks for desktop status | The coding workspace is reachable from Meta's native mobile assistant. |
| 0:20–0:50 | Mac workspace with Muse, Claude and Codex; perform a real Muse task with the resolved Spark or Wonder model visible | Meta is prominent in a multi-provider workspace. Label the model actually running. |
| 0:50–1:15 | Tell and Ask between sessions; show queued versus answered state | Sessions cooperate without losing delivery and reply state. |
| 1:15–1:35 | Take the same live session on iPad; show its Linux or Windows home | Display and execution can live on different devices. |
| 1:35–2:05 | Dictate a request, review the transcript, then run an agent | Meta Voice handles input; Apple speech synthesis handles spoken output. |
| 2:05–2:35 | Agent scoreboard, owner art direction, generated Muse Image art and a meaningful change/blocker | A useful project monitor with configurable visual expression. |
| 2:35–2:50 | Optional iPad image-tool beat: tap an object, SAM highlights a region; Spark provides editable notes | Separate geometry and description, independent of the session model. Include only after build acceptance. |
| 2:50–3:00 | Jolly status/art response; repository and credits | Close the mobile-to-desktop loop. Use the actual publication status. |

## Models and endpoints

The README lists the calling code. Agents use `muse-spark-1.3` by default through `POST https://api.meta.ai/v1/responses`. Scoreboard art calls `muse-image-1.0` at `/v1/images/generations`. Voice input calls `muse-voice-transcribe-1.0` at `/v1/asr/transcribe`. Image assistance calls `sam-3.1` and `muse-spark-1.3` through `/v1/responses`. Muse Code sessions use the installed CLI/MSP model catalog; Wonder Full is a CLI subscription option, not a Model API model. Do not credit Meta with Apple's spoken-output synthesis.

## Build-period boundary

The Mac prototype predated October 26: baseline `7788f40a75320f776468ed5c6979793dd68cd241` is dated October 25, 2026, 19:04 PDT. The first October 26 commit is `3561027` at 09:31 PDT. Do not claim that the whole app was built during the competition window.

Period evidence includes `1c413ba` (October 27: agents and scoreboard art), `d2de45b` (October 29: voice transcription, research and Jolly bridge), and `9acfd23` (October 29: hands-free voice). Group messaging, Windows, iPad and Linux work should be tied to their actual commits in the final submission. Days after October 31 remain future work, not completed evidence.

## Acceptance checklist

- [ ] Assign recording/editing owner and capture the final numbered builds.
- [ ] Verify every shown integration live; label any edit or time compression honestly.
- [ ] Record model footers and retain exact model/endpoint evidence with the submission.
- [ ] Richard reviews narration, three-minute cut, eligibility and final build-period diff.
- [ ] Verify repository publication and remove private data before showing its URL as public.
- [ ] Confirm portal track, deadline and successful submission separately from this plan.
