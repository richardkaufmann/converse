# Production and demo editions

Build both editions for each release from the same commit and `VERSION.json`. Demo is the real app with separate state, not a fake screenshot or a second writer on a production profile. Never copy the production archive, Group membership, keys, transcripts or attachments into a demo.

| Platform | Demo identity and storage | Walkthrough |
| --- | --- | --- |
| Mac | `local.richard.Converse.Demo`; `~/Library/Application Support/Converse Demo`; separate Keychain services and CLI account folders | Fresh provider login and App Support onboarding; create a demo Group |
| Windows | `ConverseDemo=true`; `%LOCALAPPDATA%\Converse Demo`; separate process mutex, Credential Manager resource and CLI account folders | Isolated provider setup, sessions and Group |
| iPhone / iPad | `app.kaoslabs.Converse.Demo`; its own application sandbox and Keychain access group | Join the demo Group and view/control its desktop sessions |
| Linux | `converse-demo` launcher; `~/.local/share/converse-demo-home`; separate identity, sockets, credentials and provider folders | Foreground Linux home; connect through the demo Group |

The desktop Demo editions use an available network port so they can run alongside production. They advertise a Demo device name. Group admission still requires explicit pairing; do not join Inside Air during a recording. Demo sessions can make real provider requests after login, and those requests may cost money. Work in a disposable demo project, not your production checkout.

## Build the pair

- Mac: `./scripts/build-round.sh mac`
- iPhone/iPad archives: `./scripts/build-round.sh ios`. Both target phone and tablet. Archives are unsigned until export; export production and demo separately using their matching Apple app records.
- Linux x64 and ARM64: `./scripts/build-round.sh linux`. Launch the demo using `./converse-demo serve`; leave that terminal open. This demo does not install or control the production systemd service.
- Windows ARM64: `powershell -File windows/build-round.ps1`. The build performs core tests and emits a hash manifest for each edition. Generate `Assets/help.json` with `scripts/build-help.py` first if Python is unavailable on Windows.

Artifacts are kept under `.build/round<build>` (Windows: `C:\dev\converse-round\<build>`). The normal release installer still waits for a normal quit. Demo installs must target **Converse Demo**, and must never replace production shortcuts or packages. A demo update preserves its demo progress, just as a normal update preserves production progress.

## Rehearse a fresh first launch

On Mac or Windows, choose **Converse → Reset Demo…**, then **Reset and Quit**. Reopen **Converse Demo** to start the welcome walkthrough again. Reset stops Demo’s work and clears its active sessions, provider logins, managed API tokens and Group pairing. It is available only in Demo. Your normal Converse app, its sessions and keys, and your project files are untouched.

The old Demo profile is kept locally in **Converse Demo Backups**, next to the Demo data folder (`~/Library/Application Support` on Mac; `%LOCALAPPDATA%` on Windows). Backups can contain demo transcripts and provider-login files; they are not uploaded. Keychain/Credential Manager tokens are removed, not backed up. Reset takes effect before any sessions or peer connections start on the next launch. You will need to log in and pair again.

For iPhone/iPad, use a fresh simulator for a completely fresh device and credentials; deleting a mobile app does not guarantee deletion of Keychain entries. Reset a Linux demo by stopping its foreground process and moving only `~/.local/share/converse-demo-home` aside. Do not reset the entire simulator or any real device containing production data.

Before recording: check the **Demo** name, confirm the demo Group, hide notifications, and use sample files. Record real behavior; label any shortened loop interval as a demonstration setting. A 24-hour health check can be demonstrated immediately with **Run once**, without pretending a day elapsed.
