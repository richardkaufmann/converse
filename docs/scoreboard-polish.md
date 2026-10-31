# Scoreboard polish checklist

Requested by Richard, 2026-10-31. Keep distinct from the iPad image tools.

- [ ] Ship and verify a separate, persistent **Scoreboard art direction** field in Agent Setup. Forward it directly to Muse Image, preserve it through remote editing and reload, and regenerate on the next scoreboard refresh after a change. In scope for 0.5.48 (73).
- [ ] Replace static repeated status with a compact account of meaningful changes since the last successful observation. Show current blockers and next actions first; preserve their age and evidence.
- [ ] Make GitHub and Discord summaries smaller. Omit unchanged “Quiet/Good” boilerplate; collapse routine counts into optional detail. Silence must not erase unresolved problems, and unavailable/stale evidence must never be described as healthy.
- [ ] Give art a recognizable visual identity that reflects real changes while honoring the owner's style. Avoid random novelty on every tick; retain a generation budget and expose refresh progress/failure.
- [ ] Check narrow panes, remote viewers, exported scoreboard HTML and Discord images for the same priorities and timestamps.
- [ ] Test a quiet run, a new blocker, a resolved blocker, unavailable evidence, and art-direction edits during an in-flight generation.

Current implementation evidence: the objective and recent conversation can influence the model's generated `artPrompt`, but there was no dedicated persisted owner art-direction field. Existing Mac art generation is gated by scoreboard cadence plus mood change or one-hour age. A new explicit direction needs its own refresh condition. The broader layout/delta work above remains pending; do not mark it shipped merely because art direction is available.
