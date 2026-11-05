# Developer TEST apps on Mac

Use a separate app to test welcome/setup (NUX), import, and daily development without changing your normal Converse or Demo profile:

```sh
scripts/build-test-app.sh Codex
# Other developer sessions use Claude or Muse instead.
```

This installs `~/Applications/Codex Converse TEST.app` (or the selected provider's name). The provider names the developer's test seat, not a restriction on which models it can run. These are local test builds of the current checkout, not published releases. `ConverseTestSource` in the bundle's Info.plist records the source revision, including a dirty suffix when applicable.

Each seat has its own bundle/settings domain, Application Support folder, provider account directories, agent credential service, device identity, and available network port. Nothing is copied from production. Log in separately if testing a live provider; importing conversations does not need a provider login. TEST apps register as alternate `.converse` file handlers; choose File → Import Conversations inside the target app.

Codex TEST uses the original red Converse shoe icon so it is easy to distinguish from the blue production app in the Dock. The build script regenerates this icon on each update.

Imports and settings persist across ordinary launches and updates. Use the app menu's **Reset TEST…**, confirm Reset and Quit, then reopen to test first run again. Reset backs up that TEST profile before clearing its files, saved app credentials, logins, and Group pairing. It does not touch project files, production, Demo, or another developer's TEST profile.

Re-run the script from the intended checkout whenever handing Richard an updated feature to try. It refuses to replace a running TEST app: quit only that TEST app, then retry. The production app can remain running. Previous TEST bundles are retained under `~/Library/Application Support/<Provider> Converse TEST Builds`; reset data backups are under `<Provider> Converse TEST Backups`. No production Dock target is changed.
