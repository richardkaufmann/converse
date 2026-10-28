import Foundation

// One interactive MSP host per conversation. All state and callbacks run on main.
// The host owns sandbox/approval policy; this client only returns server-minted choices.
final class MuseConnection {
    let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private var nextID = 0
    private var callbacks: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    var event: ((String, [String: Any]) -> Void)?
    var disconnected: ((String) -> Void)?
    var sessionID: String
    var turnID: String?
    private(set) var settingWarning: String?
    private var ready = false
    private var closing = false
    private var errorTail = ""
    init(sessionID: String) { self.sessionID = sessionID.lowercased() }
    func start(entry: Entry, arguments: [String] = [], completion: @escaping (Result<[String: Any], Error>) -> Void) {
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        let quote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        process.arguments = ["-lc", "exec " + entry.command + " serve " + arguments.map(quote).joined(separator: " ")]
        process.currentDirectoryURL = URL(fileURLWithPath: NSString(string: entry.directory).expandingTildeInPath)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env["TZ"] = TimeZone.current.identifier; env["NO_COLOR"] = "1"; process.environment = env
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        do { try process.run() } catch { completion(.failure(error)); return }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.errorTail = String(((self?.errorTail ?? "") + text).suffix(2000)) }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var buffer = Data()
            while true {
                let chunk = self.output.fileHandleForReading.availableData
                if chunk.isEmpty { break }; buffer.append(chunk)
                while let end = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                    guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    DispatchQueue.main.async { self.receive(obj) }
                }
            }
            DispatchQueue.main.async { self.closed() }
        }
        rpc("initialize", ["clientInfo": ["name": "converse", "version": "0.4"], "capabilities": ["userInputDialogs": true, "experimentalApi": true]]) { result in
            switch result {
            case .failure: completion(result)
            case .success:
                self.write(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
                self.ready = true; completion(result)
            }
        }
    }
    func rpc(_ method: String, _ params: [String: Any], completion: @escaping (Result<[String: Any], Error>) -> Void = { _ in }) {
        nextID += 1; let id = nextID; callbacks[id] = completion
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let callback = self?.callbacks.removeValue(forKey: id) else { return }
            callback(.failure(NSError(domain: "Muse", code: -1, userInfo: [NSLocalizedDescriptionKey: "Muse did not acknowledge \(method). The operation may still be running; check session status before retrying."])))
        }
    }
    private func write(_ object: [String: Any]) {
        do { var data = try JSONSerialization.data(withJSONObject: object); data.append(10); try input.fileHandleForWriting.write(contentsOf: data) }
        catch { closed() }
    }
    func receive(_ object: [String: Any]) {
        if let method = object["method"] as? String {
            let params = object["params"] as? [String: Any] ?? [:]
            if let session = params["sessionId"] as? String, session.lowercased() != sessionID { return }
            event?(method, params)
            if let id = object["id"], ["approval/request", "userInput/request"].contains(method) {
                write(["jsonrpc": "2.0", "id": id, "result": [:]]) // presentation receipt only
            }
        } else if let id = object["id"] as? Int, let callback = callbacks.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                let detail = error["data"] as? [String: Any] ?? [:]
                callback(.failure(NSError(domain: "Muse", code: error["code"] as? Int ?? -1, userInfo: [NSLocalizedDescriptionKey: error["message"] as? String ?? "Muse rejected the request", "kind": detail["kind"] as? String ?? ""])))
            } else { callback(.success(object["result"] as? [String: Any] ?? [:])) }
        }
    }
    func load(entry: Entry, choices: SessionChoices, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        settingWarning = nil
        func finish(_ result: Result<[String: Any], Error>) {
            guard case .success = result, let id = choices.model else { completion(result); return }
            self.changeSetting(.model(MuseModelChoice(id: id, label: id, provider: choices.modelProvider ?? "", profile: choices.modelProfile, efforts: []))) { applied in
                if case .failure(let error) = applied {
                    self.settingWarning = "Saved model selection could not be applied: " + error.localizedDescription + ". Continuing with the session's current model."
                }
                completion(result)
            }
        }
        rpc("session/read", ["sessionId": sessionID, "excludeItems": true]) { result in
            var params: [String: Any] = ["commandId": MuseStatusProbe.commandID(), "sessionId": self.sessionID]
            if let access = choices.access { params["permissionProfile"] = access }
            switch result {
            case .success:
                params["excludeItems"] = true
                self.rpc("session/resume", params, completion: finish)
            case .failure(let error):
                guard (error as NSError).userInfo["kind"] as? String == "sessionNotFound" else { completion(.failure(error)); return }
                if self.sessionID.split(separator: "-").dropFirst(2).first?.first != "7" {
                    self.sessionID = MuseStatusProbe.commandID(); params["sessionId"] = self.sessionID
                }
                params["workspaceRoot"] = NSString(string: entry.directory).expandingTildeInPath
                if let model = choices.model { params["modelId"] = model }
                self.rpc("session/start", params, completion: finish)
            }
        }
    }
    func changeSetting(_ change: MuseSettingChange, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var params: [String: Any] = ["commandId": MuseStatusProbe.commandID(), "sessionId": sessionID]
        let method: String
        switch change {
        case .access(let id): method = "session/setPermissionProfile"; params["profileId"] = id
        case .effort(let effort): method = "session/setReasoningEffort"; params["reasoningEffort"] = effort
        case .model(let model):
            method = "session/setModel"
            var selection = ["modelId": model.id]
            if !model.provider.isEmpty { selection["providerId"] = model.provider }
            if let profile = model.profile { selection["profileId"] = profile }
            params["model"] = selection
        }
        rpc(method, params, completion: completion)
    }
    func submit(prompt: String, display: String, images: [String], effort: String?, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        var parts: [[String: Any]] = [["type": "text", "text": prompt]]
        do { for path in images { parts.append(["type": "image", "mediaType": "image/png", "base64Data": try Data(contentsOf: URL(fileURLWithPath: path)).base64EncodedString()]) } }
        catch { completion(.failure(error)); return }
        var params: [String: Any] = ["commandId": MuseStatusProbe.commandID(), "sessionId": sessionID, "input": parts, "displayText": display, "ifBusy": "queue"]
        if let effort { params["reasoningEffort"] = effort }
        rpc("turn/start", params) { result in
            if case .success(let value) = result { self.turnID = value["turnId"] as? String }
            completion(result)
        }
    }
    func interrupt() {
        var params: [String: Any] = ["commandId": MuseStatusProbe.commandID(), "sessionId": sessionID]
        if let turnID { params["turnId"] = turnID }
        rpc("turn/interrupt", params)
    }
    func close() { closing = true; try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() } }
    private func closed() {
        let pending = callbacks; callbacks = [:]
        let message = errorTail.isEmpty ? "Muse connection closed." : "Muse connection closed: " + errorTail
        for callback in pending.values { callback(.failure(NSError(domain: "Muse", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))) }
        if !closing { disconnected?(message) }; closing = true
    }
}

struct MuseRequest: Identifiable {
    let id: String
    let kind: String
    var params: [String: Any]
}

import SwiftUI
final class MuseRequestAnswers: ObservableObject {
    @Published var selections: [String: Set<String>] = [:]
    @Published var text: [String: String] = [:]
}
struct ApprovalHeading: View {
    let detail: String
    var title = "PERMISSION REQUIRED"
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").font(.title2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .heavy))
                Text(detail).font(.callout)
            }
            Spacer(minLength: 0)
        }.foregroundStyle(.black).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.yellow)
    }
}
struct MuseRequestView: View {
    @ObservedObject var session: Session
    let request: MuseRequest
    @ObservedObject var answers: MuseRequestAnswers
    init(session: Session, request: MuseRequest) {
        self.session = session; self.request = request; self.answers = session.requestAnswers
    }
    private var questions: [[String: Any]] { request.params["questions"] as? [[String: Any]] ?? [] }
    private var valid: Bool {
        questions.allSatisfy { q in
            let id = q["id"] as? String ?? ""; let chosen = answers.selections[id] ?? []
            if let value = answers.text[id], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value.count <= 500 }
            let selection = q["selection"] as? [String: Any] ?? [:]
            return chosen.count >= (selection["minSelections"] as? Int ?? 1) && chosen.count <= (selection["maxSelections"] as? Int ?? (selection["mode"] as? String == "multiple" ? Int.max : 1))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if request.kind == "approval" {
                ApprovalHeading(detail: "Review this action and choose whether to allow it.")
            } else { Text("Muse has a question").fontWeight(.semibold) }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if request.kind == "approval" {
                        Text(request.params["toolName"] as? String ?? "Tool action").fontWeight(.medium)
                        Text(request.params["rawArgs"] as? String ?? "").font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        let choices = request.params["availableChoices"] as? [[String: Any]] ?? []
                        ForEach(choices.indices, id: \.self) { i in
                            let choice = choices[i]
                            HStack(alignment: .top) {
                                Button(choice["label"] as? String ?? "Choose") { Store.shared.answerMuse(session, request: request, choice: choice["choiceId"] as? String) }
                                if let preview = choice["rulePreview"] as? String { Text(preview).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                else if let scope = choice["scope"] as? String, scope != "once" { Text(scope == "session" ? "For this session" : "Persistent rule").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        if choices.isEmpty { Text("No decision choices received. Waiting for Muse…").foregroundStyle(.secondary) }
                    } else {
                        ForEach(questions.indices, id: \.self) { i in
                            let q = questions[i]; let id = q["id"] as? String ?? "\(i)"
                            let options = q["options"] as? [[String: Any]] ?? []
                            let multiple = (q["selection"] as? [String: Any])?["mode"] as? String == "multiple"
                            Text(q["question"] as? String ?? "Question").textSelection(.enabled)
                            ForEach(options.indices, id: \.self) { j in
                                let option = options[j]; let label = option["label"] as? String ?? ""
                                Toggle(isOn: Binding(get: { answers.selections[id]?.contains(label) == true }, set: { on in
                                    answers.text[id] = ""
                                    if multiple { if on { answers.selections[id, default: []].insert(label) } else { answers.selections[id]?.remove(label) } }
                                    else { answers.selections[id] = on ? [label] : [] }
                                })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(label)
                                        if let description = option["description"] as? String { Text(description).font(.caption).foregroundStyle(.secondary) }
                                        if let preview = option["preview"] as? [String: Any], let content = preview["content"] as? String { Text(content).font(.caption).textSelection(.enabled) }
                                    }
                                }.toggleStyle(.checkbox)
                            }
                            TextField("Your answer (or choose above)", text: Binding(get: { answers.text[id] ?? "" }, set: { answers.text[id] = $0; answers.selections[id] = [] }), axis: .vertical).lineLimit(1...5)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: request.kind == "approval" ? 160 : 280)
            if !session.requestError.isEmpty { Text(session.requestError).foregroundStyle(.red).textSelection(.enabled) }
            if request.kind == "question" {
                HStack {
                    Button("Send answer") {
                        let payloadAnswers: [[String: Any]] = questions.map { q in
                            let id = q["id"] as? String ?? ""; let value = answers.text[id] ?? ""
                            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ["questionId": id, "freeText": value] }
                            let chosen = (answers.selections[id] ?? []).sorted()
                            if (q["selection"] as? [String: Any])?["mode"] as? String == "multiple" { return ["questionId": id, "selectedLabels": chosen] }
                            return ["questionId": id, "selectedLabel": chosen.first ?? ""]
                        }
                        Store.shared.answerMuse(session, request: request, answers: payloadAnswers)
                    }.disabled(!valid)
                    Button("Cancel question") { Store.shared.answerMuse(session, request: request, cancel: true) }
                }
            }
            if session.answeringRequest { Text("Sending decision…").font(.caption).foregroundStyle(.secondary) }
        }.padding(10)
            .background(request.kind == "approval" ? Color.yellow.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            .overlay(Rectangle().stroke(request.kind == "approval" ? Color.yellow : Color.clear, lineWidth: 3))
            .disabled(session.answeringRequest)
    }
}
