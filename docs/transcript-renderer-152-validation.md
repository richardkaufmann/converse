# Transcript renderer acceptance for 152

Base: release/152 `f79f8f0`. This branch includes the attributed-prefix work and duplicate-ID occurrence tracking from PR36, plus front-trim reuse and the local-image fallback fix.

## Behavior and focused checks

- Unchanged attributed message runs survive streaming updates and leading retention trims. A retained prefix is invalidated by changed message content, numbering, disclosure state, font, locale, resolved names or image size/mtime. Repeated imported message IDs use occurrence-indexed boundaries.
- The native layout suite passed 166 checks. Front-trim output (text, attributes, Copy Message, shading and numbering) matches a fresh render. Trimming a stable-numbered leading range assembles zero retained messages; trimming plus an append assembles only the new message. Incompatible numbering falls back to a full rebuild.
- Bug22: a local image that cannot be imported now retains a clickable fallback. Clicking reveals the file in Finder on its home Mac. Remote viewers receive an explanation without probing their filesystem; missing files get a useful notice. Ordinary file links remain unlinked, and attachment import roots are unchanged. The image suite passed 106 checks, including the native link delegate with a recording reveal callback for paths with spaces, missing files and remote views. This verifies routing without opening Finder in the automated run.
- IN7: six actual saved messages (three Parking Lot reads, 87,197–91,468 characters, and three outgoing commands, 1,946–2,512 characters) passed 31 native acceptance checks. Each renders collapsed, expands through the disclosure link, preserves full Copy Message and stored source, and responds to the existing collapse setting without changing the draft. No parser change was needed for these fixtures. Private fixture contents stay outside version control. The optional `--payload-fixture-self-test` requires an isolated test profile and `CONVERSE_PAYLOAD_FIXTURE` pointing to a JSON array of Message records.

## Full gate

The build passed. The initial full run with a new CombinedQA identity stopped at Bonjour discovery (`ServiceNotRunning`, -65563), after the previously failing export-owned handoff cancellation check passed. The same binary passed Bonjour discovery in the existing isolated RendererQA identity, with a separate test data directory and QA-only agent Keychain service, but the full run then stopped at the twelve-device fabric convergence assertion. Failure diagnostics and a focused fabric command were added without changing timeouts or acceptance criteria. The subsequent build, focused fabric test (6 checks), and full `./test.sh` all exited 0; the final Mac run has 3,584 PASS lines and the Python suites passed. Export-owned handoff cancellation, Bonjour discovery and twelve-device convergence all passed in that run. The earlier intermittent convergence failure has not been root-caused; this is not a claimed transport fix. Local evidence: `.build/fabric-diagnostic.status`, `.build/fabric-diagnostic-focused.log`, and `.build/fabric-diagnostic-full.log`. No production profile, running TEST app, or production app was replaced.

## Mixed-version lot review

This review did not modify the lot lane. Schema 4 decoding refuses newer documents on the old source. Both versions still advertise lot-edit-v2. To inspect operation behavior, standalone harnesses compiled the actual ParkingLotDocument and LotEditing sources before and after the lot-feature merge. The old home accepted the ordinary setText control but refused new top-level outdent, first-item indent, and an inserted row carrying extra indent before applying them (the latter fails the payload digest check). Comparing 34 valid schema-3 tree shapes found no differing results for indent/outdent operations accepted by both versions. This is model/wire validation, not a real old-home/new-iPad transport acceptance test; that remains for the platform round.

## Remaining acceptance

The focused native checks and synthetic assembly counters do not prove Richard’s captured production stutter is fixed. Visible long-transcript interaction and the combined platform/Demo round remain required before release. Cold full transcript layout is still expensive; no retention hysteresis was added.
