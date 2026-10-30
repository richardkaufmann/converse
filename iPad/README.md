# Converse for iPad

The iPad app is a viewer/controller for sessions homed on a Mac (and, after interoperability testing, Windows). Models, CLI logins, working folders and execution stay on their home computer. No CLI or vendor API key is installed on the iPad.

The single-scene SwiftUI app uses the same physical protocol, Noise crypto, Keychain identity, trust, lease, outbox and draft-store source files as the Mac. Its Xcode project references `../Sources`; the existing Mac `swiftc` build stays intact. `VERSION.json` stamps both apps, and `scripts/build-help.py` builds the same offline README Help artifact on both platforms.

## Install wirelessly

TestFlight internal testing is the preferred path:

1. Sign in to the Apple Developer account in **Xcode → Settings → Apple Accounts**.
2. In App Store Connect create an **iOS** app named Converse using bundle ID **app.kaoslabs.Converse.iPad**. Select the registered bundle ID for your team, or register it first under Certificates, Identifiers & Profiles.
3. Open `iPad/Converse.xcodeproj`, choose the Converse scheme and **Any iOS Device (arm64)**, and select your signing team. Archive with **Product → Archive**.
4. In Organizer choose **Distribute App → App Store Connect → TestFlight internal testing**, allowing Xcode to manage signing. Answer the export-compliance questions accurately: Converse uses application-level Noise encryption, so this build deliberately does not assert that it uses no non-exempt encryption.
5. After Apple processes the build, add it to an internal testing group and invite the developer account. Install Apple's TestFlight app on the iPad and accept the invitation. Subsequent builds install wirelessly through TestFlight.

A Developer ID certificate and the Mac notarization Keychain profile do not provision iPad apps. iPad distribution needs the Apple account, iOS signing assets and an App Store Connect app record. No private key or password belongs in this repository.

For an earlier direct-device test, connect the iPad once by cable, trust the Mac, enable Developer Mode if iPadOS requests it, select the iPad in Xcode and Run. Xcode's Devices and Simulators window can then enable network connection for later wireless development runs. TestFlight avoids that development-device pairing requirement.

## Use

Open **Setup** from the top-right Converse menu. Connect on one device, compare all eight code groups on both screens, then Pair on the initiator and Approve on the receiver. This admits the device to the entire fabric: other members connect automatically, and any member can admit the next device. The sidebar shows all reachable homes' sessions. Remove from Fabric propagates a membership removal to connected devices. Tap 1, 2 or 3 to take a session into that pane; P parks its display. Tool execution continues on home when parked.

The pin left of Conversation hides the sidebar without parking sessions or interrupting heartbeats. The restore pin remains in the top bar. Its previous width returns, bounded to half the current window. At narrow widths the pane picker shows one assigned pane at a time without releasing other assignments.

The native text document has protected selectable history and a blue editable tail. Return sends or queues; Command-Return inserts a newline. Queue rows offer Inject now, with Inject all at the top. Switchboard and JSON traffic is orange. Permission requests are yellow. Model, effort and access controls send changes to home. Photo/file attachments are re-encoded as real PNG bytes, at most 2048 pixels on the long side and 8 MB, with metadata removed before hashing.

Backgrounding saves drafts and outgoing command IDs and releases display leases best-effort. Home TTL is the backstop. Foregrounding reconnects and conditionally restores the saved panes. A persisted display epoch prevents restore if any newer take occurred, even if the other viewer subsequently disconnected or parked. Explicit Park cancels restore. Older homes without lease-resume-v1 still require Take here. Uncertain sends require Check home; they are never silently replayed. A recovered draft that differs from home requires choosing which draft to edit. If an image upload was interrupted, the verified cached PNG is resent once per new lease when home reports it missing. Restoring a failed send preserves any newer text or image edits in the composer.

## Build and check

```sh
xcodebuild -project iPad/Converse.xcodeproj -scheme Converse \
  -sdk iphonesimulator -derivedDataPath .build/iPad CODE_SIGN_IDENTITY=- build
./iPad/test.sh
CONVERSE_APP_OUTPUT="$PWD/.build/PinAndHelp/Converse.app" ./build.sh
./iPad/test.sh --interop
```

`test.sh --interop` starts an isolated Mac home on an ephemeral TCP port, with disposable data and no CLI execution. It tests the actual Mac and simulator transports, mutual code verification, lease/snapshot, draft patch, bounded PNG storage, queued submit acknowledgment, rename and park/reacquire. Other tests cover offline draft persistence, late completion, conflicts, editor/history protection, pin state, image normalization and Help loading.

Real-device gates remain: BigPad installation, LAN permission denial/recovery, Bonjour discovery across physical devices, background for 60 seconds, rotation during a lease, HEIC Photos import and Mac/Windows-home interoperability. A simulator run is not evidence that these physical-device checks passed.


## Agents (0.5.22)

Use + beside a capable remote home to create an agent there. Agent Setup / Loop is available in the agent pane and its sidebar context menu. Settings include objective, optional repository, explicit session scope, fixed or text schedule, maximum turns per loop and scoreboard cadence. The editor previews the schedule; home validates it and rejects stale revisions. Creation and control do not change display leases. The agent’s loop status, attention and flexible scoreboard arrive in transcript snapshots, with images fetched by verified content hash. Execution and secrets stay on the desktop home; iPad suspension does not stop the home loop.

Agent reports render Markdown headings, bullets and fenced code. Pipe tables become wrapping labelled records suitable for narrow panes; archived Markdown stays unchanged.
