// Network check for published Help videos; not part of the offline test gate.
// Usage: swift scripts/check-help-videos.swift [docs/videos.json]
// Loads each manifest mediaURL the way Help does (AVURLAsset with the MP4 MIME
// override, following GitHub's redirect), waits for readyToPlay, plays about
// one second, seeks to 15 s, confirms the playhead moved, then tears down.
import AVFoundation
import Foundation

struct Manifest: Decodable { struct Video: Decodable { let id: String; let mediaURL: String; let durationSeconds: Double }; let videos: [Video] }

func spin(_ seconds: TimeInterval, until done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    return done()
}

let path = CommandLine.arguments.dropFirst().first ?? "docs/videos.json"
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
var failures = 0
for video in manifest.videos {
    func fail(_ reason: String) { print("FAIL \(video.id): \(reason)"); failures += 1 }
    guard let url = URL(string: video.mediaURL) else { fail("invalid mediaURL"); continue }
    print("\(video.id): \(url.absoluteString)")
    autoreleasepool {
        let started = Date()
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"]))
        var player: AVPlayer? = AVPlayer(playerItem: item)
        defer { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
        guard spin(60, until: { item.status != .unknown }), item.status == .readyToPlay else {
            let error = item.error as NSError?
            let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
            fail("status \(item.status.rawValue), error \(error.map { "\($0.domain) \($0.code) \($0.localizedDescription)" } ?? "none"), underlying \(underlying.map { "\($0.domain) \($0.code)" } ?? "none")")
            return
        }
        print(String(format: "  readyToPlay after %.1f s; item duration %.2f s (manifest %.2f s)", Date().timeIntervalSince(started), item.duration.seconds, video.durationSeconds))
        player?.play()
        _ = spin(10, until: { item.currentTime().seconds >= 1 })
        let played = item.currentTime().seconds
        print(String(format: "  played to %.2f s, rate %.1f", played, player?.rate ?? 0))
        if played <= 0 { fail("playback did not advance") }
        let target = min(15, max(0, video.durationSeconds - 2))
        var finished: Bool?
        item.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished = $0 }
        _ = spin(30, until: { finished != nil })
        let landed = item.currentTime().seconds
        print(String(format: "  seek to %.1f s finished=%@, current time %.2f s", target, String(describing: finished ?? false), landed))
        if finished != true || abs(landed - target) > 1.5 { fail("seek did not reach \(target) s") }
    }
}
print(failures == 0 ? "PASS: \(manifest.videos.count) Help video(s) stream, play and seek" : "FAIL: \(failures) problem(s)")
exit(failures == 0 ? 0 : 1)
