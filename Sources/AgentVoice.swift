import AppKit
import AVFoundation
import SwiftUI

extension AgentAPI {
    func transcribe(_ wav: Data, key: String) async throws -> String {
        guard wav.count > 44, wav.count <= 4_000_000, wav.prefix(4) == Data("RIFF".utf8),
              wav[8..<12] == Data("WAVE".utf8) else { throw AgentFailure.message("The recording is empty or invalid. Please record again.") }
        let boundary = "Converse-" + UUID().uuidString
        var body = Data()
        func add(_ text: String) { body.append(Data(text.utf8)) }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n")
        add("{\"mode\":\"PUSH_TO_TALK\",\"model\":\"muse-voice-transcribe-1.0\",\"audioEncoding\":\"WAV\"}\r\n")
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"recording.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav); add("\r\n--\(boundary)--\r\n")
        var req = URLRequest(url: URL(string: "https://api.meta.ai/v1/asr/transcribe")!)
        req.httpMethod = "POST"; req.timeoutInterval = 60; req.httpBody = body
        req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        let (data, response) = try await request(req)
        guard (200..<300).contains(response.statusCode) else { throw AgentFailure.message("Voice transcription failed (HTTP \(response.statusCode)). Check the Meta key in Agent Setup or try again.") }
        guard data.count <= 1_000_000, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let transcript = object["transcript"] as? String, transcript.count <= 16_000,
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentFailure.message("No speech was recognized. Please record again.")
        }
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// No modal session or responder-chain dictation action. Cancellation fences even
// a late microphone-permission callback. Manual dictation always reviews first.
@MainActor final class AgentDictation: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum Phase: Equatable { case idle, permission, recording, transcribing, review, failed }
    @Published var phase: Phase = .idle
    @Published var status = "Record up to 60 seconds. Audio is sent to Meta for transcription; review before inserting."
    @Published var transcript = ""
    var api = AgentAPI()
    var permission: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    var keyReader: () throws -> String? = { try AgentSecrets.read("meta") }
    var onTranscript: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    private static weak var microphoneOwner: AgentDictation?
    private var endpoint = VoiceEndpointDetector()
    private var meter: Timer?
    private var autoStop = false
    private var recorder: AVAudioRecorder?
    private var file: URL?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var key = ""
    var active: Bool { [.permission, .recording, .transcribing].contains(phase) }
    func record(autoStop: Bool = false) {
        Self.microphoneOwner?.cancel()
        cancel(); transcript = ""; self.autoStop = autoStop; endpoint = VoiceEndpointDetector()
        Self.microphoneOwner = self
        let token = generation
        phase = .permission; status = "Waiting for microphone permission… You can cancel and keep using Converse."
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let key = try keyReader(), !key.isEmpty else { throw AgentFailure.message("Add a Meta API key in Agent Setup first.") }
                let allowed = await permission()
                guard generation == token, !Task.isCancelled else { return }
                guard allowed else { throw AgentFailure.message("Microphone access is off. Enable Converse in System Settings → Privacy & Security → Microphone, then try again.") }
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("converse-voice-" + UUID().uuidString + ".wav")
                file = url; self.key = key
                let audio = try AVAudioRecorder(url: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsFloatKey: false])
                recorder = audio; audio.delegate = self; audio.isMeteringEnabled = autoStop
                guard audio.prepareToRecord(), audio.record(forDuration: 60) else { throw AgentFailure.message("The microphone could not start. Check the selected audio input and try again.") }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                phase = .recording
                status = autoStop ? "Listening… · pause 1½ seconds to send · Stop talking ends the conversation" : "Recording · maximum 60 seconds. Press Stop & transcribe when finished."
                if autoStop {
                    meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.sampleAudio() }
                    }
                }
            } catch { guard generation == token else { return }; fail(error.localizedDescription) }
        }
    }
    func stop() {
        guard phase == .recording, let file else { return }
        meter?.invalidate(); meter = nil
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        let token = generation, savedKey = key
        phase = .transcribing; status = "Transcribing… You can cancel; other sessions remain available."
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let audio = try Data(contentsOf: file)
                cleanupFile()
                let text = try await api.transcribe(audio, key: savedKey)
                guard generation == token, !Task.isCancelled else { return }
                transcript = text; phase = .review; status = "Review your words, then insert them into the blue draft. Nothing has been sent."
                key = ""
                if autoStop { onTranscript?(text) }
            } catch { guard generation == token else { return }; fail(error.localizedDescription) }
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder, phase == .recording else { return }
            if flag {
                if autoStop, endpoint.sample(power: -160, at: 60) != .send { fail("No speech detected. Press Start talking to try again.") }
                else { stop() }
            } else { fail("Recording was interrupted. Please try again.") }
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.recorder === recorder else { return }
            fail("The microphone could not record audio. Please try again.")
        }
    }
    private func sampleAudio() {
        guard phase == .recording, let recorder else { return }
        recorder.updateMeters()
        switch endpoint.sample(power: recorder.averagePower(forChannel: 0), at: recorder.currentTime) {
        case .send: stop()
        case .noSpeech: fail("No speech detected for 20 seconds. Microphone off; press Start talking to try again.")
        case .keepListening: break
        }
    }
    private func cleanupFile() { if let file { try? FileManager.default.removeItem(at: file) }; file = nil }
    private func fail(_ text: String) { cancel(); phase = .failed; status = text; onFailure?(text) }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; meter?.invalidate(); meter = nil
        if Self.microphoneOwner === self { Self.microphoneOwner = nil }
        recorder?.delegate = nil; recorder?.stop(); recorder = nil; cleanupFile(); key = ""; phase = .idle
        status = "Ready to record. Audio goes to Meta; review the transcription before inserting."
    }
    static func inserting(_ words: String, into draft: String) -> String {
        draft + (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + words
    }
}

struct AgentDictationView: View {
    @ObservedObject var voice: AgentDictation
    @ObservedObject var session: Session
    var close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dictate · " + session.title).font(.headline)
            Text(voice.status).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if voice.phase == .review { TextEditor(text: $voice.transcript).frame(height: 110).border(Color.secondary) }
            HStack {
                if !voice.active { Button("Record") { AgentConversation.shared.stop(); voice.record() } }
                if voice.phase == .recording { Button("Stop & transcribe") { voice.stop() } }
                if voice.phase == .review {
                    Button("Insert into draft") {
                        session.draft = AgentDictation.inserting(voice.transcript, into: session.draft)
                        Store.shared.save(); close()
                    }.disabled(voice.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer(); Button(voice.active ? "Cancel" : "Close") { voice.cancel(); close() }
            }
        }.padding(16).frame(width: 410).onDisappear { voice.cancel() }
    }
}
