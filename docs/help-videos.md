# Help videos

`docs/videos.json` lists the narrated Help videos. `scripts/build-help.py` copies it into the offline Help artifact (`videos`, optional in Help schema 1) and adds a **Videos** topic. Mac and iPad Help play a manifest video in place when someone clicks its `mediaURL` or `watchURL`; every other link opens as usual. Windows Help shows the text for now.

## Add a video

1. Upload the MP4 (H.264/AAC, `moov` at the front) and a PNG poster to the public `help-videos` release. Never mark that release Latest.
2. Give each file a new versioned name, such as `converse-first-run-v2.mp4`. Published files are immutable; a changed video is a new file and usually a new entry.
3. Add an entry: `id`, `title`, `durationSeconds`, `mediaURL` (the stable `releases/download/help-videos/…` URL, never a redirected or signed URL), optional `watchURL`, `posterURL`, `sha256` (publication metadata, not checked while streaming), `description`, optional `transcript`, optional `helpTopic` (a Help topic id), and `recordedWith`.
4. Link it from the README beside its topic as `[▶ Watch: Title (25 s)](mediaURL)`. The label must match the manifest; `Tests/help_content_test.py` checks it.
5. Run `swift scripts/check-help-videos.swift`. It needs the network: it loads each video the way Help does, plays about a second, seeks to 15 s and reports the result.
