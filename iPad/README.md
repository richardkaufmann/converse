# Converse for iPhone and iPad

The universal iOS app is a viewer/controller for sessions homed on a Mac (and, after interoperability testing, Windows). Models, CLI logins, working folders and execution stay on their home computer. No CLI or vendor API key is installed on the iPad.

The single-scene SwiftUI app uses the same physical protocol, Noise crypto, Keychain identity, trust, lease, outbox and draft-store source files as the Mac. Its Xcode project references `../Sources`; the existing Mac `swiftc` build stays intact. `VERSION.json` stamps both apps, and `scripts/build-help.py` builds the same offline README Help artifact on both platforms.

## iPhone layout

The same app and pairing protocol now support iPhone. Portrait is the primary layout: one session fills the screen; selecting a second stacks the two vertically. The quiet stacked-rectangles button in the top bar has a 44-point touch target and opens **Sessions**. Check or uncheck up to two sessions, grouped by home. Unchecking parks that display without stopping work on the home. A third session cannot silently replace one already selected.

The sheet also contains New session, Groups / Pair a computer, Help, About, message numbers and the private GitHub README link. Per-session actions remain in each pane's ellipsis button. There is no permanently visible phone sidebar. The iPad retains its sidebar and three-pane layout.

Opening the software keyboard gives the editing session the available height and collapses the other session to a tappable title strip. Hide the keyboard to return to the two-session stack. Landscape remains supported; short windows show one expanded session and the other title strip to preserve readable transcript space. Drafts, selected sessions and device identity survive backgrounding through the existing stores and lease recovery protocol.

Each fresh mobile installation has a stable default label such as **Converse iPhone · A1B2C3** or **Converse iPad · D4E5F6**, while an explicitly configured device name takes precedence. Pairing uses cryptographic device identity, never the display name; multiple phones and tablets can join the same group. Taking the same session on another device still follows the existing exclusive display-lease rules.

## Install wirelessly

TestFlight internal testing is the preferred path:

1. Sign in to the Apple Developer account in **Xcode → Settings → Apple Accounts**.
2. In App Store Connect create an **iOS** app named Converse using bundle ID **app.kaoslabs.Converse.iPad**. Select the registered bundle ID for your team, or register it first under Certificates, Identifiers & Profiles.
3. Open `iPad/Converse.xcodeproj`, choose the Converse scheme and **Any iOS Device (arm64)**, and select your signing team. Archive with **Product → Archive**.
4. In Organizer choose **Distribute App → App Store Connect → TestFlight internal testing**, allowing Xcode to manage signing. The generated Info.plist sets `ITSAppUsesNonExemptEncryption` to false: the current implementation uses Apple CryptoKit for Noise and Apple’s HTTPS stack. Revisit that declaration if the cryptographic dependencies change.
5. After Apple processes the build, add it to an internal testing group and invite the developer account. Install Apple's TestFlight app on the iPad and accept the invitation. Subsequent builds install wirelessly through TestFlight.

A Developer ID certificate and the Mac notarization Keychain profile do not provision iPad apps. iPad distribution needs the Apple account, iOS signing assets and an App Store Connect app record. No private key or password belongs in this repository.

For an earlier direct-device test, connect the iPad once by cable, trust the Mac, enable Developer Mode if iPadOS requests it, select the iPad in Xcode and Run. Xcode's Devices and Simulators window can then enable network connection for later wireless development runs. TestFlight avoids that development-device pairing requirement.

### Automated signing and uploads

Use `python3 iPad/distribute.py` with an App Store Connect **team API key** to avoid depending on Xcode's cached Apple Account login. Create the key in App Store Connect → Users and Access → Integrations → Team Keys. Our automatic cloud-signing workflow uses Admin access; team keys have access across apps. Keep the downloaded `.p8` outside the checkout with mode `0600`, in a private directory with mode `0700`.

The default configuration is `~/.config/converse/app-store-connect/config.json` (also keep it private):

```json
{
  "keyID": "YOUR_KEY_ID",
  "issuerID": "YOUR_ISSUER_UUID",
  "keyPath": "/absolute/private/path/AuthKey_YOUR_KEY_ID.p8",
  "teamID": "YOUR_DEVELOPER_TEAM_ID",
  "appID": "YOUR_NUMERIC_APP_ID"
}
```

```sh
# Read-only API authentication check; requires Python's cryptography package.
python3 iPad/distribute.py verify
# Sign an existing archive locally without uploading it.
python3 iPad/distribute.py export .build/Converse-iPad.xcarchive .build/iPadExport
# Explicitly upload an existing archive for internal TestFlight testing.
python3 iPad/distribute.py upload .build/Converse-iPad.xcarchive .build/iPadUpload
```

`export` and `upload` use Xcode directly and do not need the Python cryptography package. Version/build numbers are preserved. API verification proves app access; a successful export separately proves signing access. Upload success still requires Apple processing before TestFlight availability. Never commit keys, tokens, or the local configuration; keep any credential backup separate from source archives.

## Parking Lots

Group members can open Mac-hosted Parking Lots as read-only panes on iPhone and iPad. The viewer draws numbered items, blue headings with collapse chevrons, grey struck-through done items, comment-count bubbles (tap to read) and item image thumbnails (tap for full size). Opening shows the latest copy; later Mac edits show a **Refresh** button instead of replacing what you are reading. The viewer renews its nonexclusive lot subscription on open, reconnect and foreground, so it never needs Take and never moves anything on the Mac. A row that does not parse is shown as plain text. Renames update the sidebar, and deleted lots disappear from it. Creation, editing and Talk remain on the Mac. Mobile viewers cannot send a draft or take an editing lease for a Parking Lot.

`./iPad/test.sh --interop` exercises the real isolated Mac Group connection, including Parking Lot discovery, opening, attached-image transfer, live updates, the Refresh flow, subscription renewal and reopening. Set `CONVERSE_APP_OUTPUT` to the built Mac app and `CONVERSE_IPAD_SIMULATOR` to an iPad or iPhone simulator UUID. The snapshot tests also verify read-only behavior, rename and deletion. Simulator results do not replace physical-device discovery and reconnect testing.

## Use

Open **Setup** from the top-right Converse menu. Connect on one device, compare all eight code groups on both screens, then Pair on the initiator and Approve on the receiver. This admits the device to the entire fabric: other members connect automatically, and any member can admit the next device. The sidebar shows all reachable homes' sessions. Remove from Fabric propagates a membership removal to connected devices. Tap 1, 2 or 3 to take a session into that pane; P parks its display. Tool execution continues on home when parked.

The pin left of Conversation hides the sidebar without parking sessions or interrupting heartbeats. The restore pin remains in the top bar. Its previous width returns, bounded to half the current window. The sidebar divider has a visible grab handle and a wider drag area; a mouse or trackpad shows a left/right resize pointer over it. VoiceOver can adjust it in steps. At narrow widths the pane picker shows one assigned pane at a time without releasing other assignments.

The native text document has protected selectable history and a blue editable tail. Typing while history is selected moves to the editable draft and reveals it without changing history. Image lines keep a normal text-sized caret. Return sends or queues; Command-Return inserts a newline. Queue rows offer Inject now, with Inject all at the top when more than one item is queued. Switchboard and JSON traffic is orange. Permission requests are yellow. Model, effort and access controls send changes to home. Photo/file attachments are re-encoded as real PNG bytes, at most 2048 pixels on the long side and 8 MB, with metadata removed before hashing.

Use **Session actions (⋯) → Teach / Refresh Switchboard Instructions** in a pane to send the current messaging rules. Tapping or long-pressing a session name in the sidebar opens the same stable actions panel; live status updates do not rearrange its choices. Teaching preserves the draft and queues behind current work; use **Inject now** on that queue item when you want to interrupt a busy turn. Agents receive instructions for their structured response format and keep their configured session scope. “Reply needed” marks an unanswered tracked request: refreshing rules does not resolve it; the session must send a matching answer, blocker, or decline. Orange transcript summaries open the full message when tapped, in both light and dark mode.

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

## Editable Parking Lot development preview

The native editor is currently gated off by default. The isolated `./iPad/test.sh --lot-editing` path enables it against a disposable Mac home and exercises ordered saves, image transfer, exclusive handoff and recovery. It includes per-level disclosure, outline numbering, text, comments, Done, tags, structural editing, Undo/Redo and `.converse` export. See [the preview notes](../docs/mobile-lot-editor-preview.md) for activation prerequisites; the shipped viewer remains unchanged until those checks are complete.


## Agents (0.5.22)

Use + beside a capable remote home to create an agent there. Agent Setup / Loop is available in the pane’s fixed-width **⋯ Session actions** menu and its sidebar actions panel. The menu also offers Run once and Scoreboard. Settings include objective, optional repository, explicit session scope, fixed or text schedule, maximum turns per loop and scoreboard cadence. The editor previews the schedule; home validates it and rejects stale revisions. Creation and control do not change display leases. The agent’s loop status, attention and flexible scoreboard arrive in transcript snapshots, with images fetched by verified content hash. Execution and secrets stay on the desktop home; iPad suspension does not stop the home loop.

Agent reports render Markdown headings, bullets and fenced code. Pipe tables become wrapping labelled records suitable for narrow panes; archived Markdown stays unchanged.

## Image assistance (0.5.48 / 73)

The wand beside attached images opens Image tools. Describe drafts editable Spark notes; tap an object and Find region uses SAM 3.1, then Add focused crop retains the original alongside a rectangular crop. Processing uses the updated Mac home's Meta key, independently of the session provider. Windows/Linux homes do not yet advertise image assistance. No result sends a prompt automatically. A changed lease, removed image, draft conflict or pending send prevents applying a stale result. Home operation receipts prevent retrying an uncertain paid request as a second API call.

Agent Setup now includes Scoreboard art direction. Save and run once to try it; changed direction bypasses the normal hour/mood art refresh gate on the next scoreboard refresh. Older homes require an update before accepting this field.
