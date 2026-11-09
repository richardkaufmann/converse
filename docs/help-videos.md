# Help videos

`docs/videos.json` lists the narrated Help videos. `scripts/build-help.py` copies it into the offline Help artifact (`videos`, optional in Help schema 1) and adds a **Videos** topic. Mac and iPad Help play a manifest video in place when someone clicks its `mediaURL` or `watchURL`; every other link opens as usual. Windows Help shows the text for now.

## Add a video

1. Upload the MP4 (H.264/AAC, `moov` at the front) and a PNG poster to the public `help-videos` release. Never mark that release Latest.
2. Give each file a new versioned name, such as `converse-first-run-v2.mp4`. Published files are immutable; a changed video is a new file and usually a new entry.
3. Add an entry: `id`, `title`, `durationSeconds`, `mediaURL` (the stable `releases/download/help-videos/…` URL, never a redirected or signed URL), optional `watchURL`, `posterURL`, `sha256` (publication metadata, not checked while streaming), `description`, optional `transcript`, optional `helpTopic` (a Help topic id), and `recordedWith`.
4. Link it from the README beside its topic as `[▶ Watch: Title (25 s)](mediaURL)`. The label must match the manifest; `Tests/help_content_test.py` checks it.
5. Run `swift scripts/check-help-videos.swift`. It needs the network: it loads each video the way Help does, plays about a second, seeks to 15 s and reports the result.

## Build 154 video handoff

The new manifest entries are prepared from Video 2 draft 6 (lot revision 15526). The existing first-launch asset stays unchanged. The full movie and five additional sections each have a versioned MP4 and a matching PNG poster. The source file for the portrait section still has the old scoreboard filename; its published name and content use assessments and portraits.

These six entries must not reach a public release before their assets are uploaded. The release driver should publish them to the existing `help-videos` release as part of the authorized promotion, keep that release away from Latest, verify the downloaded hashes against the manifest, then run `swift scripts/check-help-videos.swift docs/videos.json` against the public URLs. Do not overwrite an existing versioned asset with different bytes. Local AVFoundation playback and seeking have passed; that does not verify the eventual GitHub redirects or remote streaming.

The YouTube and Drive links recorded for draft 5 are deliberately not used for draft 6. The README retains the original hackathon demo as a separate historical link.

| Asset | Duration | SHA-256 |
| --- | ---: | --- |
| `converse-overview-v1.mp4` | 338.50 s | `9cebffb7469b0c250f306f220f8b7603df17f771450cac33fc81168377dfb7df` |
| `converse-hello-world-v1.mp4` | 83.80 s | `54322c2c1410d35c9d3fad6d686eb38b78c913cf8672e68aa351557c9baf521f` |
| `converse-real-project-v1.mp4` | 37.30 s | `4d56c6d7937025b22a56e86999c643f2896a7f74be72540df97d49af4333c18d` |
| `converse-building-a-video-v1.mp4` | 45.60 s | `71077380b92fd4c35bae9c3cbc11e0a15fce510450d3cccb2feee90a68348cf1` |
| `converse-assessments-and-portraits-v1.mp4` | 48.00 s | `36168315fc25d1ecf3cbfe52743cea9c05f70c01c7ef5a0ea2332eadbfe4cd4d` |
| `converse-development-team-v1.mp4` | 83.17 s | `09e285d392300e809a219a6a63731596d5d01e1313992f2e66e5cf25ec2c6db6` |
