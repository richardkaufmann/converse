# README walkthrough review — draft, October 31

This is a review request, not a release announcement. The proposed guide is in
`README.md` and builds the in-app Help. Developer details moved to
`docs/desktop-reference.md`, `docs/development-reference.md`,
`docs/switchboard-reference.md` and `docs/meta-integrations.md`.

## Editorial goal

Treat the guide as a dependency graph: explain concepts before relying on them.
Minimize forward links and especially unexplained forward mentions. The intended
path is install → first login → first coding session → everyday use/images/SAM →
App Support as the first agent example → create/run/configure agents → optional
integrations → messaging → Groups/mobile → Linux → privacy and reference.
Early navigation to privacy and platform installation is intentional, but should
not make a beginner learn advanced concepts to finish their first session.

## Request for Muse

Review the actual draft for accuracy, missing steps, unexplained prerequisites,
provider assumptions and readability. Then start a fresh subagent with **no app
or conversation context**. Give it only the README and permission to follow the
links it needs. Do not supply a product explanation, this review brief, or your
own findings first. This must be a comprehension review, not a live installation
that signs into accounts, changes services or sends provider requests.

Ask that reader to explain, citing the steps it found:

1. How would you install on a Mac and get the first model response? What access
   or accounts do you need, and what would block you?
2. How would you make a coding session for an existing project, send an image,
   and refer to a file without uploading it?
3. What is App Support? How would you inspect its objective, ask it a question,
   run one check, or pause daily checks?
4. Can a Claude-backed agent check GitHub? Can it search the web? Which optional
   features still require a Meta key, and is a Muse login that key?
5. How would you create your own agent and decide what it is allowed to read?
6. Are the Meta Muse iPhone connector and Converse's iPhone app the same thing?
   What setup is actually available, and what remains an operator task?
7. How would you pair a second computer/phone, and where would its work run?
8. At which first sentence did you need a term or fact that had not been
   explained? List the other blockers, guesses and confusing jumps in order.

Please return your own prioritized findings and the independent reader's report,
keeping the two separate. A successful reading is not evidence of a successful
installation. We need honest blockers, not invented setup steps.

## Known implementation boundaries for the primary reviewer

- As of this October 31 review, the repository was not yet public and no public release/TestFlight access was promised.
- Mac App Support onboarding ships; Windows onboarding is isolated-preview only.
- Agent reasoning can use CLI logins or Meta API. CLI agent runs have native web
  and shell tools disabled. GitHub/session evidence is supplied by Converse.
- Meta API agent runs can use hosted search. A Meta key is not a search fallback
  for CLI-backed agents. Image/voice/art services have separate requirements.
- The Jolly UI does not provision its HTTPS endpoint, token or tunnel.
- Startup scheduling is being fixed with this work: retain the saved deadline,
  coalesce overdue intervals into one check, then wait the next interval. It is
  not installed in production yet. Paused queues/loops stay paused.
- Help's topic IDs are native link targets. The first-session/first-agent/Group,
  security, agents-and-project-scoreboards, jolly-mac and accounts IDs remain.

## Review received and revisions

MuseConverse returned its critique and a separate fresh-reader report on October
31. It reports the subagent received only README and linked documentation, with
no app context, brief or prior findings. The reader could answer all eight
workflow questions and distinguished provider login from optional Meta services.
It flagged first-use jargon, access prerequisites and operator-only Jolly setup.
This establishes comprehension evidence, not a performed installation.

Revisions made after that review:

- Define the assistants, agent, CLI, queue, Spark, API key, scoreboard cards,
  observation times, bridge, endpoint, token and schema at first use.
- State where Help lives and whom to ask for private-repository/TestFlight access.
- Replace beginner-facing “headless adapter” terminology with the visible limitation.
- Explain that both Describe and SAM need a Meta key, unlike a CLI login.
- Add the missing source checkout prerequisite to the Linux walkthrough and
  distinguish Linux's service lifetime from an open desktop app.
- Put slash commands before the Accounts section that uses them.
- Link Discord's portal; retain explicit operator prerequisites for Jolly rather
  than invent a turnkey installation flow.
- Keep a brief startup-cadence explanation in the App Support example and the
  full semantics in the scheduling subsection.
- Add Richard's scoped-search teaching and the editable new-agent objective.

Two flags did not reproduce: the README had “bearer authentication,” not a
literal redaction placeholder; VERSION.json confirmed 0.5.59/build84. The bridge
terminology was defined anyway. No claim is made that Muse re-reviewed this
revised draft.
