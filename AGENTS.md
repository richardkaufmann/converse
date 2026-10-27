# Converse development

The user has authorized committing and pushing changes to this GitHub repository as work progresses. After each completed, verified change, commit it and push `main` to `origin`. The user has authorized making it public and publishing downloadable Mac releases. Never include credentials, personal settings, transcripts, or attachments.

Build with `./build.sh`. Run `./test.sh` for session engine, adapter, timing, persistence, and text behavior changes. Reversible visual-only changes can be checked by building and inspecting the native app. Generated app and icon bundles are ignored by Git.

Keep the UI minimal: dense sidebar, plain scrolling native text, blue draft, italic default-color submitted input, subtle input-block separators, optional line-number gutter, clickable links and pasted images. Return sends; Command-Return inserts a newline. Preserve active sessions and drafts when updating the app.

Publishing a release does not update an installed app. When updating the local installation, identify the actual running bundle path and use `./install.sh /exact/path/Converse.app`; it waits for quit before replacement. Report a queued update as pending until its status says INSTALLED and the destination version is independently verified. Never replace a running bundle or quit an active development conversation to install an update.
