# Developer TEST apps on Mac

Use a separate app to test welcome/setup (NUX), import, and daily development without changing your normal Converse or Demo profile:

```sh
scripts/build-test-app.sh Codex
# Other developer sessions use Claude or Muse instead.
```

This installs `~/Applications/Codex Converse TEST.app` (or the selected provider's name). The provider names the developer's test seat, not a restriction on which models it can run. These are local test builds of the current checkout, not published releases. `ConverseTestSource` in the bundle's Info.plist records the source revision, including a dirty suffix when applicable.

Each seat has its own bundle/settings domain, Application Support folder, provider account directories, agent credential service, device identity, and available network port. Nothing is copied from production. Log in separately if testing a live provider; importing conversations does not need a provider login. TEST apps register as alternate `.converse` file handlers; choose File → Import Conversations inside the target app.

Codex TEST uses the original red Converse shoe icon so it is easy to distinguish from the blue production app in the Dock. The build script regenerates this icon on each update.

Imports and settings persist across ordinary launches and updates. Choose **Converse → Settings → New User Experience / Reset**, type `YES`, and click **Reset on Quit**. Quit normally and reopen to test first run again. You can cancel the scheduled reset before quitting. Reset backs up that TEST profile before clearing its files, saved app credentials, logins, and Group pairing. It does not touch project files, production, Demo, or another developer's TEST profile.

Re-run the script from the intended checkout whenever handing Richard an updated feature to try. It refuses to replace a running TEST app: quit only that TEST app, then retry. The production app can remain running. Previous TEST bundles are retained as verified ZIP archives under `~/Library/Application Support/<Provider> Converse TEST Builds`; reset data backups are under `<Provider> Converse TEST Backups`. The old bundle is unregistered before removal and the installed copy is registered, so Launch Services cannot reopen a launchable backup with the same identity. No production Dock target is changed.

To convert an older, stopped TEST backup, run `python3 scripts/archive-test-backup.py Codex '/exact/path/Previous Codex Converse TEST.app'`. It refuses running apps, other editions, symlinks and existing archive destinations. It verifies the archive against the original files before removing the old bundle. To recover it later, extract the ZIP explicitly.
