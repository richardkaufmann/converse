import SwiftUI

struct PadConnect: View {
    @ObservedObject var model: PadModel
    @ObservedObject private var service = DeviceSyncService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = "48721"
    @State private var deviceName = UserDefaults.standard.string(forKey: "deviceName") ?? "Converse iPad"
    @State private var forget: TrustedDevice?
    var body: some View {
        NavigationStack {
            Form {
                Section("Setup") {
                    Text("Converse on iPad views and controls conversations on a home computer. Install and open Converse on that computer first. Its CLI logins and files stay there.")
                    TextField("This device’s name", text: $deviceName).onSubmit {
                        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { UserDefaults.standard.set(name, forKey: "deviceName"); service.deviceNameOverride = name }
                    }
                }
                Section("Pairing sequence") {
                    Text("1. Tap Connect on ONE device.\n2. Compare ALL eight code groups on both screens.\n3. Tap Pair on the initiating device and Approve on the receiving device.")
                    Text("Pair once with any member to join its fabric. All members connect automatically. Every member can admit others and control sessions on home computers under their logins.").font(.callout)
                    Text(service.serviceStatus).font(.caption).textSelection(.enabled)
                }
                if service.localNetworkDenied {
                    Section("Local Network access is off") {
                        Text("Allow Converse in Settings → Privacy & Security → Local Network. This also affects connecting by address on your LAN.")
                        Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                        Button("Try again") { service.suspendViewer(); service.resumeViewer() }
                    }
                }
                if let prompt = service.pairingPrompt {
                    Section(prompt.isInitiator ? "Pair with " + prompt.peerName : "Approve connection from " + prompt.peerName) {
                        Text(prompt.instruction)
                        Text(prompt.code).font(.system(.title3, design: .monospaced).bold()).textSelection(.enabled)
                        Text("Every group must match exactly.").bold()
                        Text("Fingerprint: " + prompt.fingerprint).font(.caption).textSelection(.enabled)
                        if prompt.keyChanged || prompt.nameCollision { Text("This identity differs from a stored device. Check that you expect a new identity before trusting it.").foregroundStyle(.red) }
                        HStack { Button("Reject", role: .destructive) { service.rejectPairing() }; Spacer(); Button(prompt.actionLabel) { service.confirmPairing() }.buttonStyle(.borderedProminent) }
                    }
                }
                Section("Nearby Converses") {
                    if service.discovered.isEmpty { Text("Keep Converse open on both devices on the same network. You can also connect by address below.").foregroundStyle(.secondary) }
                    ForEach(service.discovered) { device in HStack { Text(device.name); Spacer(); Button("Connect") { service.connect(discovered: device) } } }
                }
                Section("Connect by address") {
                    TextField("Host or IP address", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    Button("Connect") { service.connectManual(host: host.trimmingCharacters(in: .whitespacesAndNewlines), port: Int(port) ?? -1) }.disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("For VPNs without Bonjour discovery, use the home computer’s address and listening port. Pairing uses the same verification.").font(.caption)
                }
                Section("Fabric members") {
                    if service.trusted.isEmpty { Text("None paired yet.") }
                    ForEach(service.trusted) { device in
                        HStack {
                            VStack(alignment: .leading) { Text(device.name); Text(service.homes[device.deviceID]?.online == true ? "Online" : "Offline").font(.caption).foregroundStyle(.secondary) }
                            Spacer(); Button("Remove", role: .destructive) { forget = device }
                        }
                    }
                }
                if !service.lastOutcome.isEmpty { Section { Text(service.lastOutcome).font(.caption).textSelection(.enabled) } }
            }.navigationTitle("Converse · Setup").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                .confirmationDialog("Remove this device from the fabric?", isPresented: Binding(get: { forget != nil }, set: { if !$0 { forget = nil } }), titleVisibility: .visible) { Button("Remove from Fabric", role: .destructive) { if let device = forget { service.forgetDevice(device) }; forget = nil } } message: { Text("This removal propagates to connected fabric members. The device must be admitted again to rejoin.") }
        }
    }
}

struct PadRequest: View {
    let id: String
    let request: DeviceRequestDTO
    @ObservedObject private var service = DeviceSyncService.shared
    @State private var answers: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    var questions: [[String: Any]] { request.questionsJSON.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] } ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.kind == "approval" ? "PERMISSION REQUIRED" : "QUESTION FROM HOME", systemImage: "exclamationmark.triangle.fill").font(.headline)
            if request.kind == "approval" {
                if let name = request.toolName { Text(name).bold() }
                if let args = request.rawArgs { Text(args).font(.system(.caption, design: .monospaced)).lineLimit(5).textSelection(.enabled) }
                ForEach(request.choices) { choice in Button(choice.label) { service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "answer", requestID: request.id, choiceID: choice.id)) }.buttonStyle(.bordered) }
            } else {
                ForEach(questions.indices, id: \.self) { index in
                    let q = questions[index]
                    let qid = q["id"] as? String ?? String(index)
                    let options = q["options"] as? [[String: Any]] ?? []
                    Text(q["question"] as? String ?? "Question")
                    ForEach(options.indices, id: \.self) { oi in
                        let label = options[oi]["label"] as? String ?? "Option"
                        let selected = selections[qid]?.contains(label) == true
                        Button((selected ? "✓ " : "○ ") + label) {
                            let multiple = (q["selection"] as? [String: Any])?["mode"] as? String == "multiple"
                            if multiple { if selected { selections[qid]?.remove(label) } else { selections[qid, default: []].insert(label) } }
                            else { selections[qid] = [label] }
                        }
                    }
                    TextField("Answer", text: Binding(get: { answers[qid] ?? "" }, set: { answers[qid] = $0 })).textFieldStyle(.roundedBorder)
                }
                Button("Send answers") {
                    var result: [[String: Any]] = []
                    for (index, q) in questions.enumerated() {
                        let key = q["id"] as? String ?? String(index)
                        var answer: [String: Any] = ["questionId": key]
                        let labels = (selections[key] ?? []).sorted()
                        if !labels.isEmpty { answer["selectedLabels"] = labels; if labels.count == 1 { answer["selectedLabel"] = labels[0] } }
                        if let text = answers[key], !text.isEmpty { answer["freeText"] = text }
                        result.append(answer)
                    }
                    let data = try? JSONSerialization.data(withJSONObject: result)
                    service.sendRemoteCommand(globalID: id, command: DeviceCommandPayload(action: "answer", requestID: request.id, answersJSON: data))
                }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.yellow.opacity(0.65))
    }
}

struct PadHelp: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private let book = try? HelpBook.load()
    var body: some View {
        NavigationStack {
            List {
                if let book {
                    Section { Text("Converse " + book.appVersion + " · Offline help from the README").font(.caption).foregroundStyle(.secondary) }
                    ForEach(book.search(query)) { topic in
                        NavigationLink(topic.title) {
                            ScrollView {
                                Text((try? AttributedString(markdown: topic.markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(topic.plainText)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                            }.navigationTitle(topic.title).navigationBarTitleDisplayMode(.inline)
                        }
                    }
                    if book.search(query).isEmpty { Text("No matching topics.") }
                } else { Link("Read Converse Help on GitHub", destination: URL(string: "https://github.com/richardkaufmann/converse#readme")!) }
            }.searchable(text: $query, prompt: "Search Help").navigationTitle("Converse Help")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
