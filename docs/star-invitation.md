# Appreciation invitation

Parking Lot “Things To Implement Now” item 21 (4DA9EA09-6809-4647-8ADA-D81316712F94).

The Mac app shows a blue **Happy With Converse?** banner beneath its local App Support sidebar row and in the App Support pane. Clicking opens a small window with the blue shoe, **Star on GitHub**, **File a Bug…**, and **Not Now**. Star opens the public repository; File a Bug opens Converse's existing report form. Closing any of these consumes the invitation; it never waits for a GitHub response or checks for a star.

Eligibility is deterministic, without agent calls: thirty minutes of foreground use with input within the last minute, plus five successful, uninterrupted human-directed ordinary session turns in this installed release. Background agents, switchboard traffic, setup probes, failed turns, time asleep, and an unattended foreground window do not qualify. A five-second timer counts active time; a run-loop gap over ten seconds contributes no time.

The banner expires after five further active minutes and has its own dismiss control. The app persists the release as asked **before** showing the banner, so a quit or crash cannot re-prompt. Installing a different version/build starts new usage qualification. Previously shown releases remain consumed even after a downgrade. The local profile's `star-invitation.json` contains only version/build identifiers, bounded usage counters, and asked-release identifiers. It is not sent to providers, GitHub, other devices, or analytics. No prompts or transcripts are modified.

This branch implements the Mac surface. The Foundation eligibility state is portable; iOS and Windows presentation/hooking remain separate integration work. Headless Linux has no invitation UI. Demo/TEST profiles have independent files and do not inherit production eligibility.

Validation: deterministic checks cover new installation, time and turn thresholds, successful consumption, encode/decode across restart, upgrade, downgrade, invalid elapsed time, exclusion of failed/interrupted/autonomous turns, and profile independence. The normal suite invokes these checks. Settings previews render the invitation window in both appearances.
