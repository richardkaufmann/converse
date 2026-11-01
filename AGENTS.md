# Converse development

The user has authorized committing and pushing changes to this GitHub repository as work progresses. After each completed, verified change, commit it and push `main` to `origin`. The user has authorized making it public and publishing downloadable Mac releases. Never include credentials, personal settings, transcripts, or attachments.

Build with `./build.sh`. Run `./test.sh` for session engine, adapter, timing, persistence, and text behavior changes. Reversible visual-only changes can be checked by building and inspecting the native app. Generated app and icon bundles are ignored by Git.

Keep the UI minimal: dense sidebar, plain scrolling native text, blue draft, italic default-color submitted input, subtle input-block separators, optional line-number gutter, clickable links and pasted images. Return sends; Command-Return inserts a newline. Preserve active sessions and drafts when updating the app.

For each new user-facing preview/update, advance the patch version and the monotonically increasing build number in `VERSION.json` (for example, 0.5.1 build 26, then 0.5.2 build 27). Rebuilds or upload retries of the same release keep its version; ordinary local test builds do not bump it. Mac and iPad must read this shared source.

Publishing a release does not update an installed app. When updating the local installation, identify the actual running bundle path and use `./install.sh /exact/path/Converse.app`; it waits for quit before replacement. Report a queued update as pending until its status says INSTALLED and the destination version is independently verified. Never replace a running bundle or quit an active development conversation to install an update.

Richard requires shortcut repair on every local app update. Verify the pinned Converse Dock target resolves to the installed app, update obsolete targets when migrating paths, and retain its Dock position. Updating the app alone is incomplete. Keep the current conversation running while preparing this; do not launch a second production instance against the live archive.

Richard requires a matching **Converse Demo** edition for every user-facing release on every supported platform. Use `scripts/build-round.sh` (Mac, iPhone/iPad, Linux) and `windows/build-round.ps1`, then `scripts/verify-round.py`. Demo must use separate application/profile/credential/device identities and must never import production sessions, trust or secrets. Keep both editions on the same VERSION.json and source revision; install each into its own destination, preserving both profiles. See `docs/demo-editions.md` for the recording/reset workflow and mobile distribution prerequisite. Never redirect the production shortcut to Demo.

For user-facing writing, preserve Richard’s conversational voice. Lead with what people can do, give concrete cross-system examples, and keep the introduction short on machinery. The invitation is “let AI read the details”: users tell App Support what they want; it works through the detailed guide with them. Put platform, authentication and operational qualifications in the relevant later sections rather than weighing down every introductory claim. App Support and GitHub reporting must not require Discord. Recommend the managed GitHub token for direct report submission; manual copy/paste submission is a fallback.
