import CryptoKit
import Foundation

// Agent assessments: every agent turn returns structured JSON (summary,
// status, a few glanceable facts and deeper nested detail). The host owns
// measured values; a model may only point at them by id. A malformed or
// missing assessment never fails the turn: the last record stays, marked stale.

/// Arbitrary JSON from an untrusted reply, bounded before it is stored.
indirect enum AgentJSON: Codable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([AgentJSON]), object([String: AgentJSON])
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([AgentJSON].self) { self = .array(value) }
        else { self = .object(try c.decode([String: AgentJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let value): try c.encode(value)
        case .number(let value): try c.encode(value.isFinite ? value : 0)
        case .string(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        }
    }
    /// Converts a JSONSerialization value (host evidence) without guessing booleans from numbers.
    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber: self = .number(number.doubleValue)
        case let text as String: self = .string(text)
        case let items as [Any]: self = .array(items.map { AgentJSON(any: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { AgentJSON(any: $0) })
        default: self = .string(String(describing: value!))
        }
    }
    subscript(key: String) -> AgentJSON? { if case .object(let object) = self { return object[key] }; return nil }
    var string: String? { if case .string(let value) = self { return value }; return nil }
    var isEmpty: Bool {
        switch self { case .null: return true; case .array(let a): return a.isEmpty; case .object(let o): return o.isEmpty; default: return false }
    }
    /// One-line text for a scalar; nil for containers.
    var scalarText: String? {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .number(let value): return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .string(let value): return value
        default: return nil
        }
    }
    /// Keeps stored detail small: depth, item counts, string length and total
    /// node budget are capped; anything beyond is marked truncated.
    func bounded(depth: Int = 0, budget: inout Int, maxDepth: Int = 6, maxString: Int = 2000) -> AgentJSON {
        budget -= 1
        guard budget >= 0 else { return .string("…") }
        switch self {
        case .string(let value): return .string(String(value.prefix(maxString)))
        case .number(let value): return .number(value.isFinite ? value : 0)
        case .array(let items):
            guard depth < maxDepth else { return .string("… (\(items.count) items)") }
            var result: [AgentJSON] = []
            for item in items.prefix(64) { guard budget > 0 else { result.append(.string("…")); break }; result.append(item.bounded(depth: depth + 1, budget: &budget, maxDepth: maxDepth, maxString: maxString)) }
            return .array(result)
        case .object(let object):
            guard depth < maxDepth else { return .string("… (\(object.count) fields)") }
            var result: [String: AgentJSON] = [:]
            for key in object.keys.sorted().prefix(64) {
                guard budget > 0 else { result["…"] = .string("truncated"); break }
                result[String(key.prefix(80))] = object[key]!.bounded(depth: depth + 1, budget: &budget, maxDepth: maxDepth, maxString: maxString)
            }
            return .object(result)
        default: return self
        }
    }
    func bounded(nodes: Int) -> AgentJSON { var budget = nodes; return bounded(budget: &budget) }
    /// Canonical text (sorted keys) for hashing and logs.
    var canonical: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
    /// Rows for the nested detail view: one per key/index, indented by depth.
    struct Line: Equatable, Identifiable { var id: Int; var depth: Int; var key: String; var value: String? }
    func outline(maxDepth: Int = 8) -> [Line] {
        var lines: [Line] = []
        func walk(_ node: AgentJSON, key: String, depth: Int) {
            if let text = node.scalarText { lines.append(Line(id: lines.count, depth: depth, key: key, value: text)); return }
            guard depth < maxDepth else { lines.append(Line(id: lines.count, depth: depth, key: key, value: "…")); return }
            switch node {
            case .array(let items):
                if !key.isEmpty { lines.append(Line(id: lines.count, depth: depth, key: key, value: items.isEmpty ? "[]" : nil)) }
                for (index, item) in items.enumerated() { walk(item, key: "\(index + 1).", depth: key.isEmpty ? depth : depth + 1) }
            case .object(let object):
                if !key.isEmpty { lines.append(Line(id: lines.count, depth: depth, key: key, value: object.isEmpty ? "{}" : nil)) }
                for name in object.keys.sorted() { walk(object[name]!, key: name, depth: key.isEmpty ? depth : depth + 1) }
            default: break
            }
        }
        walk(self, key: "", depth: 0)
        return lines
    }
}

struct AgentFact: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case measured, evidence, judgment
        var label: String { rawValue.capitalized }
        var help: String {
            switch self {
            case .measured: return "Measured by Converse from a real source"
            case .evidence: return "Traceable evidence the agent cited"
            case .judgment: return "The agent's explicitly labelled judgment"
            }
        }
    }
    var id: String
    var label: String
    var value: String
    var kind: Kind
    var source: String
    var observedAt: Date?
    var detail: AgentJSON? = nil
    static let unavailable = "Unavailable"
}

struct AgentAssessment: Codable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case onTrack = "on-track", atRisk = "at-risk", blocked, done
        var label: String { switch self { case .onTrack: return "On track"; case .atRisk: return "At risk"; case .blocked: return "Blocked"; case .done: return "Done" } }
        static func parse(_ text: String?) -> Status? {
            guard let text else { return nil }
            let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
            return Status(rawValue: value) ?? ["ontrack": .onTrack, "atrisk": .atRisk, "complete": .done, "completed": .done][value]
        }
    }
    var summary: String
    var status: Status
    var facts: [AgentFact]
    var detail: AgentJSON? = nil
    /// Three to five words for portrait art. A presentation hint, not content.
    var mood: [String]? = nil
    var revision: Int = 1
    var contentHash: String = ""
    /// When this revision was created; heartbeats never move it.
    var updatedAt: Date = Date()
    /// When an agent turn last confirmed this content.
    var checkedAt: Date = Date()
    /// Unchanged turns since this revision.
    var heartbeats: Int? = nil
    var seeded: Bool? = nil
    var shortHash: String { String(contentHash.prefix(8)) }
    static let displayedFacts = 7
}

struct AgentAssessmentRevision: Codable, Equatable {
    var revision: Int
    var contentHash: String
    var status: AgentAssessment.Status
    var summary: String
    var updatedAt: Date
    var checkedAt: Date
    var heartbeats: Int
}

/// Why the latest turn did not produce a usable assessment.
struct AgentAssessmentProblem: Codable, Equatable {
    var reason: String
    var at: Date
}

enum AgentAssessments {
    static let historyLimit = 10
    static let maxFacts = 12
    static let teaching = """
    Return assessment EVERY turn, even when reply is empty: {summary: at most two sentences on progress against the objective, status: "on-track"|"at-risk"|"blocked"|"done", mood: optional 3-5 single words describing the agent's current spirit for portrait art, facts: 5-7 glanceable rows [{id, label, value, kind, source, observedAt, detail}], detail: optional nested JSON with deeper levels (sub-facts, lists, links) than the rows show}. kind is "measured", "evidence" or "judgment". measuredFacts in the evidence are host measurements: to show one, include {id: its exact id, kind: "measured"}; Converse fills in label, value, source and observedAt. Never type a measured value yourself; a measured fact Converse does not have shows Unavailable. evidence facts must be traceable to supplied sessions, lots, Discord or this run's research: source names the session id, lot or exact URL, and observedAt is the source's time. judgment facts are your explicitly labelled opinion; source "judgment". Each fact may carry detail: any nested JSON shown when the human hovers or selects that row. Keep facts relevant to THIS agent's objective. An unchanged assessment is expected when nothing changed; do not reword it just to look fresh. Never put credentials or private transcript excerpts in an assessment.
    """

    // MARK: Host measurements

    /// Facts Converse measures itself. Values stay host-owned: the model can
    /// only reference these by id. Missing values read Unavailable.
    static func measured(lots: [AgentLotScoreboard], repository: String?, snapshot: AgentRepoSnapshot?,
                         discord: (count: Int, atLimit: Bool, channel: String)?, versions: [String: Any]?, now: Date) -> [AgentFact] {
        var facts: [AgentFact] = []
        for lot in lots {
            let unfinished = lot.sections.reduce(0) { $0 + $1.unfinished }
            let red = lot.sections.reduce(0) { $0 + ($1.colors[ParkingLotTag.red.rawValue] ?? 0) }
            let source = "Parking Lot “" + lot.name + "”"
            let sections = AgentJSON.object(Dictionary(lot.sections.map { ($0.title, AgentJSON.string($0.value)) }, uniquingKeysWith: { first, _ in first }))
            facts.append(AgentFact(id: "lot." + lot.id.uuidString + ".unfinished", label: lot.name + " · unfinished", value: String(unfinished), kind: .measured, source: source, observedAt: lot.observedAt, detail: .object(["sections": sections, "revision": .number(Double(lot.revision))])))
            facts.append(AgentFact(id: "lot." + lot.id.uuidString + ".red", label: lot.name + " · red", value: String(red), kind: .measured, source: source, observedAt: lot.observedAt,
                detail: .object(["sections": .object(Dictionary(lot.sections.compactMap { section in (section.colors[ParkingLotTag.red.rawValue] ?? 0) > 0 ? (section.title, AgentJSON.number(Double(section.colors[ParkingLotTag.red.rawValue] ?? 0))) : nil }, uniquingKeysWith: { first, _ in first }))])))
        }
        if let repository = repository?.trimmingCharacters(in: .whitespacesAndNewlines), !repository.isEmpty {
            let repo = snapshot?.repository == repository ? snapshot : nil
            let source = "github.com/" + repository
            func add(_ id: String, _ label: String, _ value: Int?, note: String? = nil) {
                facts.append(AgentFact(id: "github." + id, label: label, value: value.map(String.init) ?? AgentFact.unavailable, kind: .measured, source: source, observedAt: repo?.observedAt,
                                       detail: note.map { .object(["note": .string($0)]) }))
            }
            add("stars", "GitHub stars", repo?.stars)
            add("downloads", "Release downloads", repo?.releaseDownloads, note: "Cumulative across all accessible releases.")
            add("cloners14d", "Unique cloners · 14d", repo?.uniqueCloners14d, note: "Rolling 14 days; lifetime uniques are not provided.")
            add("clonersToday", "Unique cloners · today UTC", repo?.uniqueClonersTodayUTC, note: "Today's UTC bucket may be delayed.")
            add("visitors14d", "Visitors · 14d", repo?.visitors14d)
            add("openIssues", "Open issues", repo?.openIssues)
            add("openBugs", "Open bugs", repo?.openBugs)
            add("openPRs", "Open pull requests", repo?.openPRs)
            if let notes = repo?.notes, !notes.isEmpty, let last = facts.indices.last { facts[last].detail = .object(["notes": .array(notes.map { .string($0) })]) }
        }
        if let discord {
            facts.append(AgentFact(id: "discord.new", label: "Discord · new messages", value: String(discord.count) + (discord.atLimit ? "+" : ""), kind: .measured, source: "Discord channel " + discord.channel, observedAt: now,
                                   detail: .object(["batchAtLimit": .bool(discord.atLimit)])))
        }
        if let versions, let this = versions["thisDevice"] as? [String: Any], let local = this["installedVersion"] as? String {
            let paired = versions["pairedDevices"] as? [[String: Any]] ?? []
            let matching = paired.filter { ($0["installedVersion"] as? String) == local }.count
            facts.append(AgentFact(id: "fleet.versions", label: "Fleet on " + local, value: paired.isEmpty ? "This Mac only" : "\(matching + 1) of \(paired.count + 1) devices",
                                   kind: .measured, source: "Converse device sync", observedAt: now, detail: AgentJSON(any: versions)))
        }
        return facts
    }

    // MARK: Contract

    enum Outcome: Equatable {
        case revision(AgentAssessment)
        case heartbeat(AgentAssessment)
        case rejected(String)
    }

    static func iso(_ text: String?) -> Date? {
        guard let text else { return nil }
        let full = ISO8601DateFormatter(); full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ISO8601DateFormatter().date(from: text) ?? full.date(from: text)
    }
    static func clip(_ text: String?, _ limit: Int) -> String {
        String((text ?? "").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces).prefix(limit))
    }

    /// Validates one turn's raw assessment against host measurements and the
    /// previous record. Pure: the caller stores the outcome.
    static func evaluate(_ raw: AgentJSON?, measured: [AgentFact], previous: AgentAssessment?, now: Date) -> Outcome {
        guard let raw, raw != .null else { return .rejected("No assessment returned this turn.") }
        guard case .object = raw else { return .rejected("Assessment was not a JSON object.") }
        let summary = clip(raw["summary"]?.string, 400)
        guard !summary.isEmpty else { return .rejected("Assessment summary was missing.") }
        guard let status = AgentAssessment.Status.parse(raw["status"]?.string) else { return .rejected("Assessment status was missing or not on-track, at-risk, blocked or done.") }
        var facts: [AgentFact] = []
        if let value = raw["facts"], value != .null {
            guard case .array(let items) = value else { return .rejected("Assessment facts were not an array.") }
            for item in items.prefix(maxFacts) {
                guard case .object = item else { continue }
                if let fact = fact(item, measured: measured, previous: previous, now: now), !facts.contains(where: { $0.id == fact.id }) { facts.append(fact) }
            }
        }
        let mood = raw["mood"].flatMap { value -> [String]? in
            guard case .array(let items) = value else { return nil }
            let words = items.compactMap { $0.string.map { clip($0, 24) } }.filter { !$0.isEmpty }.prefix(5)
            return words.isEmpty ? nil : Array(words)
        }
        let detail = raw["detail"].flatMap { $0 == .null ? nil : $0.bounded(nodes: 600) }
        var next = AgentAssessment(summary: summary, status: status, facts: facts, detail: detail, mood: mood, updatedAt: now, checkedAt: now)
        next.contentHash = contentHash(next)
        if let previous, previous.contentHash == next.contentHash, previous.seeded != true {
            var beat = previous
            beat.checkedAt = now; beat.heartbeats = (previous.heartbeats ?? 0) + 1; beat.mood = mood ?? previous.mood
            // Same content: measured rows were re-measured, so their times advance;
            // agent-cited facts keep the observation time of their source.
            beat.facts = previous.facts.map { old in next.facts.first { $0.id == old.id && $0.kind == .measured } ?? old }
            return .heartbeat(beat)
        }
        next.revision = (previous?.revision ?? 0) + 1
        return .revision(next)
    }

    private static func fact(_ item: AgentJSON, measured: [AgentFact], previous: AgentAssessment?, now: Date) -> AgentFact? {
        let rawID = clip(item["id"]?.string, 120), rawLabel = clip(item["label"]?.string, 80)
        let byID = rawID.isEmpty ? nil : measured.first { $0.id == rawID }
        let kind = AgentFact.Kind(rawValue: clip(item["kind"]?.string, 20).lowercased()) ?? (byID != nil ? .measured : item["source"]?.string?.isEmpty == false ? .evidence : .judgment)
        let detail = item["detail"].flatMap { $0 == .null ? nil : $0.bounded(nodes: 200) }
        // A host measurement id always shows the host value, whatever kind the model claimed.
        if byID != nil || kind == .measured {
            let byLabel = rawLabel.isEmpty ? nil : measured.first { $0.label.caseInsensitiveCompare(rawLabel) == .orderedSame }
            if var host = byID ?? byLabel { if host.detail == nil { host.detail = detail }; return host }
            // The model claimed a measurement Converse does not have: never show its value.
            let label = rawLabel.isEmpty ? rawID : rawLabel
            guard !label.isEmpty else { return nil }
            return AgentFact(id: rawID.isEmpty ? slug(label) : rawID, label: label, value: AgentFact.unavailable, kind: .measured,
                             source: "Not measured by Converse", observedAt: nil,
                             detail: .object(["note": .string("Converse has no measurement for this fact. Measured values never come from the model.")]))
        }
        let label = rawLabel.isEmpty ? rawID : rawLabel
        guard !label.isEmpty else { return nil }
        let id = rawID.isEmpty ? slug(label) : rawID
        let value = clip(item["value"]?.string ?? item["value"]?.scalarText, 200)
        let source = clip(item["source"]?.string, 300)
        // A cited fact keeps its source time; an unchanged one keeps the time it was first seen.
        let stated = iso(item["observedAt"]?.string).flatMap { $0 <= now.addingTimeInterval(300) ? $0 : nil }
        let earlier = previous?.facts.first { $0.id == id && $0.value == value }?.observedAt
        return AgentFact(id: id, label: label, value: value.isEmpty ? AgentFact.unavailable : value, kind: kind,
                         source: source.isEmpty ? (kind == .judgment ? "judgment" : "Unspecified") : source,
                         observedAt: stated ?? earlier ?? now, detail: detail)
    }
    static func slug(_ text: String) -> String {
        String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.prefix(60))
    }
    /// Meaningful content only: status, normalized summary, facts (not their
    /// observation times) and detail. Unchanged content keeps its revision and
    /// portrait cache key even when the agent rewrote nothing.
    static func contentHash(_ assessment: AgentAssessment) -> String {
        // Measured rows count by value: their host detail carries observation
        // times that change on every measurement without changing the fact.
        let facts = assessment.facts.sorted { $0.id < $1.id }.map { fact in
            AgentJSON.array([.string(fact.id), .string(fact.label), .string(fact.value), .string(fact.kind.rawValue), .string(fact.source), fact.kind == .measured ? .null : fact.detail ?? .null])
        }
        let body = AgentJSON.array([.string(assessment.status.rawValue), .string(clip(assessment.summary, 400).lowercased()), .array(facts), assessment.detail ?? .null])
        return SHA256.hash(data: Data(body.canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AgentConfig {
    /// Stores one turn's outcome. Returns true when a new revision was created.
    @discardableResult mutating func recordAssessment(_ outcome: AgentAssessments.Outcome, now: Date) -> Bool {
        switch outcome {
        case .revision(let next):
            if let old = assessment {
                var history = assessmentHistory ?? []
                history.insert(AgentAssessmentRevision(revision: old.revision, contentHash: old.contentHash, status: old.status, summary: old.summary, updatedAt: old.updatedAt, checkedAt: old.checkedAt, heartbeats: old.heartbeats ?? 0), at: 0)
                assessmentHistory = Array(history.prefix(AgentAssessments.historyLimit))
            }
            assessment = next; assessmentProblem = nil
            return true
        case .heartbeat(let beat):
            assessment = beat; assessmentProblem = nil
            return false
        case .rejected(let reason):
            assessmentProblem = AgentAssessmentProblem(reason: reason, at: now)
            return false
        }
    }
    /// Migration: an agent with an earlier scoreboard starts with a seeded,
    /// clearly labelled assessment instead of an empty card. The next turn replaces it.
    mutating func seedAssessmentFromScoreboard(now: Date = Date()) {
        guard assessment == nil, let board = scoreboard else { return }
        let sentiment = board.sentiment ?? "neutral"
        let facts = board.metrics.prefix(AgentAssessment.displayedFacts).map { metric in
            AgentFact(id: AgentAssessments.slug(metric.label), label: String(metric.label.prefix(80)), value: String(metric.value.prefix(200)), kind: .evidence,
                      source: metric.sourceURL ?? "Earlier scoreboard", observedAt: board.observedAt,
                      detail: metric.asOf.map { .object(["asOf": .string($0)]) })
        }
        let summary = board.summary.isEmpty ? String(widgetSummary.prefix(400)) : board.summary
        var seeded = AgentAssessment(summary: summary, status: ["urgent", "down"].contains(sentiment) ? .atRisk : .onTrack, facts: Array(facts),
                                     detail: .object(["seededFrom": .string("Earlier scoreboard"), "sentiment": .string(sentiment)]),
                                     revision: 1, updatedAt: board.observedAt ?? now, checkedAt: board.observedAt ?? now, seeded: true)
        seeded.contentHash = AgentAssessments.contentHash(seeded)
        assessment = seeded
    }
}

/// Badge for how current a card is.
enum AgentAssessmentFreshness: Equatable {
    case fresh, aging, old, stale(String), none
    static func of(_ assessment: AgentAssessment?, problem: AgentAssessmentProblem?, now: Date) -> Self {
        if let problem, assessment != nil { return .stale(problem.reason) }
        guard let assessment else { return problem.map { .stale($0.reason) } ?? .none }
        if assessment.seeded == true { return .stale("Seeded from the last scoreboard; the next turn replaces it.") }
        let age = now.timeIntervalSince(assessment.checkedAt)
        return age < 3600 ? .fresh : age < 86400 ? .aging : .old
    }
    var label: String {
        switch self { case .fresh: return "Fresh"; case .aging: return "Aging"; case .old: return "Old"; case .stale: return "Stale"; case .none: return "No assessment" }
    }
}

enum AgentAge {
    /// "now", "4m", "3h", "2d".
    static func short(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }
}

/// Hover expands a row's detail; click or Space/Return pins it. One model so
/// pointer, keyboard and VoiceOver reach the same state.
struct AssessmentDetailExpansion: Equatable {
    private(set) var hovered: String?
    private(set) var pinned: Set<String> = []
    func isExpanded(_ id: String) -> Bool { hovered == id || pinned.contains(id) }
    mutating func hover(_ id: String, _ inside: Bool) {
        if inside { hovered = id } else if hovered == id { hovered = nil }
    }
    /// Click, Space or Return. A row opened by hover is pinned by its first
    /// activation, so clicking what you are reading never hides it.
    mutating func activate(_ id: String) {
        if pinned.contains(id) { pinned.remove(id); if hovered == id { hovered = nil } }
        else { pinned.insert(id) }
    }
}
