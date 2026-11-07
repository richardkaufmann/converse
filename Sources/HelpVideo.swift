import AVFoundation
import Foundation

// One entry from docs/videos.json, carried in the Help artifact. sha256 is
// publication metadata only; playback streams and does not verify it.
struct HelpVideo: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let durationSeconds: Double
    let mediaURL: String
    var watchURL: String? = nil
    var posterURL: String? = nil
    let sha256: String
    let description: String
    var transcript: String? = nil
    var helpTopic: String? = nil
    let recordedWith: String

    var durationLabel: String {
        let seconds = max(1, Int(durationSeconds.rounded()))
        if seconds < 60 { return "\(seconds) s" }
        return "\(seconds / 60) min" + (seconds % 60 == 0 ? "" : " \(seconds % 60) s")
    }
    // The page a person can open when in-app playback fails.
    var browserURL: URL? { URL(string: watchURL ?? mediaURL) }

    // Pure routing: a manifest mediaURL or watchURL opens the player; any
    // other link, including a redirected or signed asset URL, does not.
    static func route(_ url: URL, in videos: [HelpVideo]) -> HelpVideo? {
        func key(_ url: URL) -> String? {
            guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme?.lowercased() == "https",
                  let host = parts.host?.lowercased(), parts.query == nil else { return nil }
            return host + parts.path
        }
        guard let wanted = key(url) else { return nil }
        return videos.first { video in [video.mediaURL, video.watchURL].contains { $0.flatMap(URL.init(string:)).flatMap(key) == wanted } }
    }
}

// Loads one video for the in-app player. GitHub answers the stable asset URL
// with a redirect to application/octet-stream; the MIME override lets
// AVFoundation follow it and still treat the stream as MP4.
@MainActor final class HelpVideoPlayback: ObservableObject, Identifiable {
    enum State: Equatable { case loading, ready, failed(String) }
    let video: HelpVideo
    let url: URL?
    @Published private(set) var state = State.loading
    @Published private(set) var player: AVPlayer?
    private var status: NSKeyValueObservation?
    nonisolated var id: String { video.id }

    init(video: HelpVideo, url: URL? = nil) { self.video = video; self.url = url ?? URL(string: video.mediaURL) }

    func load(autoplay: Bool = true) {
        stop()
        guard let url else { state = .failed("This video link is not valid."); return }
        state = .loading
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"]))
        let player = AVPlayer(playerItem: item)
        self.player = player
        status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            let current = item.status, error = item.error
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item else { return }
                switch current {
                case .readyToPlay where self.state == .loading: self.state = .ready; if autoplay { self.player?.play() }
                // Also reached mid-stream, for example when the connection drops.
                case .failed: self.state = .failed(Self.message(for: error)); self.stop()
                default: break
                }
            }
        }
    }
    func retry() { load() }
    // Every dismissal path ends here: stop the audio and release the player.
    func stop() {
        status?.invalidate(); status = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
    }

    nonisolated static func message(for error: Error?) -> String {
        var next = error as NSError?
        while let current = next {
            if current.domain == NSURLErrorDomain, current.code == NSURLErrorNotConnectedToInternet {
                return "You appear to be offline. Connect to the internet, then try again. The written Help works offline."
            }
            next = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let reason = (error as NSError?)?.localizedDescription ?? "The video did not load."
        return "The video could not play here: \(reason)"
    }
}

// Shared by the Mac and iPad Help windows. Replacing or clearing the current
// playback (Done, Escape, swipe-down or closing Help) stops it.
@MainActor final class HelpVideoPresenter: ObservableObject {
    let videos: [HelpVideo]
    private nonisolated let resolve: @Sendable (HelpVideo) -> URL?
    @Published var playback: HelpVideoPlayback? { didSet { if oldValue !== playback { oldValue?.stop() } } }

    nonisolated init(videos: [HelpVideo], resolve: @escaping @Sendable (HelpVideo) -> URL? = { URL(string: $0.mediaURL) }) { self.videos = videos; self.resolve = resolve }

    // Returns false for links Help should hand to the system as usual.
    func open(_ url: URL) -> Bool {
        guard let video = HelpVideo.route(url, in: videos) else { return false }
        let playback = HelpVideoPlayback(video: video, url: resolve(video))
        self.playback = playback
        playback.load()
        return true
    }
    func close() { playback = nil }
}

// Test fixture: a short silent H.264 MP4 written locally, so player tests
// need neither the network nor a committed binary.
enum HelpVideoFixture {
    static func writeMP4(to url: URL, seconds: Int = 2) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 10) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { throw CocoaError(.fileWriteUnknown) }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 12 % 256), CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
