# Feedback invitation

Parking Lot “Things To Implement Now” item 21 (4DA9EA09-6809-4647-8ADA-D81316712F94), revised at lot revision 30314.

After twenty successful, uninterrupted human-directed ordinary session turns in this installed release, the Mac app shows a blue **Thoughts About Converse?** banner beneath its local App Support sidebar row and in the App Support pane. Opening it shows the blue shoe and a **Thoughts About Converse** window. **Open GitHub** opens the public repository in the browser, where the human may choose to click Star. **File an Issue…** opens the GitHub new-issue page; **File a Bug…** opens Converse's existing report form. **Not Now** closes the window.

There is no automated starring, star-status check, GitHub token, OAuth flow, reward, feature gate or agent call for this invitation. The repository action consists only of opening https://github.com/richardkaufmann/converse. The existing bug-report form retains its own explicit submission flow.

The banner expires after five active minutes and has a dismiss control. Foreground time counts only with recent human input; sleeping or a stalled run loop adds no expiry time. The release is persisted as asked before showing, so quitting cannot repeat it. Unless feedback has already been acknowledged, installing another version/build starts a fresh twenty-turn count. Previously shown releases remain consumed after downgrades. No thirty-minute usage threshold remains.

The local profile's `feedback-invitation.json` contains version/build identifiers, a turn count, and asked-release identifiers (the per-release feedback_ask state). It is not sent to providers, GitHub, other devices, or analytics. Nothing is added to transcripts. No background disk writes occur on a timer; completed human turns and consuming the invitation are persisted. Dismissal stops the timer and input observer; a consumed release does not install them on restart. Demo, TEST, Setup Preview and automation never start the invitation. Admission requires an actually visible App Support row or pane in a visible, non-minimized window; a clipped sidebar row does not consume it.

This branch implements the Mac surface; other platforms remain separate integration work. Headless Linux has no invitation UI.

Validation covers nineteen versus twenty turns, exclusion of failed/interrupted/autonomous turns, persistence, upgrade, downgrade and profile independence. Native previews cover the feedback window in light and dark appearances.

Permanent suppression: `feedbackGiven` is a local per-profile flag, preserved across upgrades and downgrades. The invitation stays open when opening GitHub or the bug form, so the human can return and choose “I’ve given feedback”. A confirmed successful direct bug submission also sets the flag. Opening a URL, cancelling, a failed/uncertain submission, or dismissing the banner does not. There is no GitHub activity lookup or automatic starring. Older state files without the flag retain the per-release reminder behavior.

Turn counting excludes queued app-generated teaching/welcome prompts and provider handoff-note requests. Human submits from iPad/other viewers count at the execution home just like local submits. Mixed queues containing switchboard traffic are conservatively excluded. Visibility subtracts all higher visible Converse window frames from the actual clipped target rectangle; several covering windows may jointly prevent consumption. Explicit CONVERSE_DATA_DIR automation is excluded.
