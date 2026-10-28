import SwiftUI

struct PadConnect: View {
    @ObservedObject var model: PadModel
    var body: some View { ConverseGroupsView() }
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
