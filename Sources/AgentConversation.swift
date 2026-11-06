import AppKit
import AVFoundation
import Combine

// Energy-based endpoint detection. Require sustained sound, not a single click;
// initial silence never becomes a query. All durations use monotonic audio time.
struct VoiceEndpointDetector {
    enum Decision { case keepListening, send, noSpeech }
    var silenceSeconds = 1.5
    private var voicedDuration: Double = 0
    private var heardSpeech = false
    private var lastSpeech: Double?
    private var previousTime: Double = 0
    mutating func sample(power: Float, at time: Double) -> Decision {
        let delta = min(0.2, max(0, time - previousTime)); previousTime = time
        if power.isFinite && power > -42 {
            voicedDuration += delta; lastSpeech = time
            if voicedDuration >= 0.2 { heardSpeech = true }
        } else { voicedDuration = 0 }
        if heardSpeech, let lastSpeech, time - lastSpeech >= silenceSeconds { return .send }
        if time >= 20 && !heardSpeech { return .noSpeech }
        if time >= 59.5 { return heardSpeech ? .send : .noSpeech }
        return .keepListening
    }
}

@MainActor final class AgentVoiceSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var current: AVSpeechUtterance?
    private var completion: ((Bool) -> Void)?
    override init() { super.init(); synth.delegate = self }
    func say(_ text: String, intent: String, done: @escaping (Bool) -> Void) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = intent == "urgent" ? 0.55 : (intent == "celebratory" ? 0.5 : 0.43)
        utterance.pitchMultiplier = intent == "celebratory" ? 1.12 : (["concerned", "urgent"].contains(intent) ? 0.9 : 1)
        current = utterance; completion = done; synth.speak(utterance)
    }
    func stop() { current = nil; completion = nil; synth.stopSpeaking(at: .immediate) }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.ended(utterance, success: true) }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.ended(utterance, success: false) }
    }
    private func ended(_ utterance: AVSpeechUtterance, success: Bool) {
        guard current === utterance else { return }
        let done = completion; current = nil; completion = nil; done?(success)
    }
}

// One explicit conversation owns the microphone. It never listens during a
// model turn or speech playback, and a late result cannot reopen a stopped mic.
@MainActor final class AgentConversation: ObservableObject {
    static let shared = AgentConversation()
    enum Phase { case stopped, listening, thinking, speaking, cooldown }
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var sessionID: UUID?
    @Published private(set) var detail = ""
    @Published private(set) var lastHeard = ""
    let audio = AgentDictation()
    private let speaker = AgentVoiceSpeaker()
    private weak var session: Session?
    private weak var store: Store?
    private var responseID: UUID?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var observer: AnyCancellable?
    private var spokenTurns = 0
    // Injected hardware seams keep the state-machine tests microphone/network free.
    var startRecording: (() -> Void)?
    var speakReply: ((String, String, @escaping (Bool) -> Void) -> Void)?
    var stopPlayback: (() -> Void)?
    var resumeDelay: UInt64 = 500_000_000
    var active: Bool { phase != .stopped }
    var statusPresented: Bool { sessionID != nil }
    var status: String { phase == .listening ? audio.status : detail }
    func dismissStatus() {
        guard !active else { return }
        sessionID = nil
    }
    func owns(_ session: Session) -> Bool { active && sessionID == session.id }
    func isVoiceTurn(_ session: Session, responseID: UUID) -> Bool { owns(session) && self.responseID == responseID }
    init() {
        observer = audio.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        audio.onTranscript = { [weak self] text in self?.transcribed(text) }
        audio.onFailure = { [weak self] message in self?.stop(message) }
    }
    func start(_ session: Session, store: Store) {
        stop()
        self.session = session; self.store = store; sessionID = session.id; lastHeard = ""; spokenTurns = 0
        guard ready(session, store: store) else { detail = "Agent is busy or its queue is paused. Try Start talking when it is ready."; return }
        listen()
    }
    private func ready(_ session: Session, store: Store) -> Bool {
        session.agent != nil && store.sessions.contains { $0 === session } && !session.busy && !session.changingSetting && session.pending.isEmpty && !session.queuePaused
    }
    private func listen() {
        guard let session, let store, ready(session, store: store) else { stop("Conversation paused: the agent has other work. Press Start talking when ready."); return }
        guard spokenTurns < 20 else { stop("Twenty spoken turns completed. Press Start talking to continue."); return }
        responseID = nil; phase = .listening
        if let startRecording { startRecording() } else { audio.record(autoStop: true) }
    }
    func transcribed(_ words: String) {
        guard phase == .listening, let session, let store else { return }
        audio.cancel(); lastHeard = words
        guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { stop("No speech recognized. Please try again."); return }
        guard ready(session, store: store) else {
            session.draft = AgentDictation.inserting(words, into: session.draft); store.save()
            stop("Agent became busy. Your words are in the draft; nothing was sent."); return
        }
        let draft = session.draft, images = session.attachments
        session.draft = words; session.attachments = []
        phase = .thinking; detail = "Thinking… · microphone off"
        store.send(session, preservingAgentDraft: (draft, images))
        session.draft = draft; session.attachments = images; store.save()
        guard session.busy, let response = session.messages.last, response.role == "assistant" else {
            session.draft = AgentDictation.inserting(words, into: draft); store.save()
            stop("Question could not start. Your words are in the draft."); return
        }
        spokenTurns += 1; responseID = response.id
    }
    func completed(_ session: Session, responseID: UUID, text: String, intent: String, success: Bool) {
        guard phase == .thinking, isVoiceTurn(session, responseID: responseID) else { return }
        guard success else { stop("Agent stopped or failed. Check its transcript; microphone is off."); return }
        let text = Self.spokenText(text)
        guard !text.isEmpty else { stop("No spoken answer was available. Check the transcript."); return }
        phase = .speaking; detail = "Speaking… · microphone off"
        let token = generation
        let done: (Bool) -> Void = { [weak self] success in
            guard let self, generation == token, phase == .speaking else { return }
            task?.cancel()
            guard success else { stop("Speech playback stopped. Press Start talking to resume."); return }
            phase = .cooldown; detail = "Listening again shortly…"
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                do { try await Task.sleep(nanoseconds: resumeDelay) } catch { return }
                guard generation == token, phase == .cooldown else { return }
                listen()
            }
        }
        // A missing OS speech callback must not wedge the conversation forever.
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard !Task.isCancelled, let self, generation == token, phase == .speaking else { return }
            stop("Speech playback timed out. Press Start talking to resume.")
        }
        if let speakReply { speakReply(text, intent, done) } else { speaker.say(text, intent: intent, done: done) }
    }
    func stop(_ message: String = "Conversation stopped · microphone off", resumeQueued: Bool = true) {
        generation = UUID(); task?.cancel(); task = nil; audio.cancel(); speaker.stop(); stopPlayback?()
        responseID = nil; phase = .stopped; detail = message
        if resumeQueued, let session, let store, !session.pending.isEmpty {
            DispatchQueue.main.async { store.runNext(session) }
        }
    }
    static func spokenText(_ text: String) -> String {
        let prose = text.components(separatedBy: "\nSources:").first ?? text
        return String(MarkdownText.render(prose).string.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200))
    }
}
