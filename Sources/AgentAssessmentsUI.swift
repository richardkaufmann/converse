import AppKit
import SwiftUI
import UniformTypeIdentifiers

// View → Assessments and View → Portraits. Local windows need no extra access
// gate. Portraits subscribe to demand only while their window is open.
@MainActor final class AgentBoardWindows {
    static let shared = AgentBoardWindows()
    func showAssessments() { GalleryWindows.shared.showAll(portraits: false) }
    func showPortraits() { GalleryWindows.shared.showAll(portraits: true) }
}

struct AgentAssessmentsView: View {
    @ObservedObject var store = Store.shared
    var body: some View {
        let agents = store.sessions.filter { $0.agent != nil }
        ScrollView {
            if agents.isEmpty {
                Text("No agents yet. Create one from File → New Agent; its first turn adds an assessment here.").foregroundStyle(.secondary).padding(24)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(agents) { AgentAssessmentCard(session: $0) }
            }.padding(16)
        }.frame(minWidth: 380, minHeight: 320)
    }
}

struct AgentAssessmentCard: View {
    @ObservedObject var session: Session
    @State private var expansion = AssessmentDetailExpansion()
    @State private var showAllFacts = false
    @State private var showHistory = false
    @FocusState private var focused: String?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date, config = session.agent ?? AgentConfig(), assessment = config.assessment
            let ageColor: Color = config.assessmentNeedsConfirmation ? .orange : assessment.map { now.timeIntervalSince($0.checkedAt) < 300 ? .green : .secondary } ?? .secondary
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title).font(.headline).lineLimit(2)
                    Spacer()
                    if let assessment { AssessmentStatusPill(status: assessment.status) }
                    Text(config.assessmentAge(now: now)).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(ageColor.opacity(0.18), in: Capsule()).foregroundStyle(ageColor)
                        .accessibilityLabel("Assessment age: " + config.assessmentAge(now: now))
                }
                if let assessment {
                    Text(assessment.summary).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text(revisionLine(assessment, now: now)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("No assessment yet. The agent's next turn adds one.").font(.callout).foregroundStyle(.secondary)
                }
                if let problem = config.assessmentProblem {
                    Label(problem.reason + " · " + AgentAge.short(problem.at, now: now) + " ago", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let failure = config.portrait?.failure {
                    Label("Portrait couldn't refresh: " + failure + " · " + AgentAge.short(config.portrait?.failedAt, now: now) + " ago", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !config.visibleAssessmentFacts.isEmpty {
                    Divider()
                    let facts = showAllFacts ? config.visibleAssessmentFacts : Array(config.visibleAssessmentFacts.prefix(AgentAssessment.displayedFacts))
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(facts) { fact in factRow(fact, now: now) }
                    }
                    if config.visibleAssessmentFacts.count > AgentAssessment.displayedFacts {
                        Button(showAllFacts ? "Show fewer" : "Show \(config.visibleAssessmentFacts.count - AgentAssessment.displayedFacts) more") { showAllFacts.toggle() }.buttonStyle(.link).font(.caption)
                    }
                }
                if let detail = assessment?.detail, !detail.isEmpty {
                    expandable(id: "card", label: "Details", accessibility: "Assessment details", row: { EmptyView() }) { AgentJSONDetailView(json: detail) }
                }
                if let history = config.assessmentHistory, !history.isEmpty {
                    DisclosureGroup("Earlier assessments", isExpanded: $showHistory) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(history, id: \.revision) { item in
                                Text(item.status.label + " · " + AgentAge.short(item.updatedAt, now: now) + " ago" + (item.heartbeats > 0 ? " · unchanged for \(item.heartbeats) more checks" : "") + "\n" + item.summary)
                                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.font(.caption)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.18)))
        }
    }
    private func revisionLine(_ assessment: AgentAssessment, now: Date) -> String {
        var line = "Updated " + AgentAge.short(assessment.updatedAt, now: now) + " ago"
        // Unchanged turns collapse into one line instead of repeating the card.
        if let beats = assessment.heartbeats, beats > 0 { line += " · no change in \(beats) check" + (beats == 1 ? "" : "s") + ", last " + AgentAge.short(assessment.checkedAt, now: now) + " ago" }
        if assessment.seeded == true { line += " · seeded from the last scoreboard" }
        return line
    }
    private func freshnessColor(_ freshness: AgentAssessmentFreshness) -> Color {
        switch freshness { case .fresh: return .green; case .aging: return .yellow; case .old, .none: return .secondary; case .stale: return .orange }
    }
    @ViewBuilder private func factRow(_ fact: AgentFact, now: Date) -> some View {
        let age = AgentAge.short(fact.observedAt, now: now)
        expandable(id: "fact." + fact.id, label: nil, accessibility: fact.label + ": " + fact.value + ", " + fact.kind.label + ", observed " + (age == "—" ? "at an unknown time" : age + " ago"), row: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fact.label).font(.caption).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(fact.value).font(.callout.monospacedDigit()).lineLimit(2).foregroundStyle(fact.value == AgentFact.unavailable ? .secondary : .primary)
                Text(String(fact.kind.label.prefix(1))).font(.caption2.bold()).frame(width: 16).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3)).help(fact.kind.help)
                Text(age).font(.caption2).foregroundStyle(.secondary).frame(width: 32, alignment: .trailing).help(fact.observedAt.map { "Observed " + $0.formatted() } ?? "Observation time unknown")
            }
        }) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fact.kind.help + " · " + fact.source).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                if let detail = fact.detail, !detail.isEmpty { AgentJSONDetailView(json: detail) }
            }
        }
    }
    /// Hover expands; click, Space or Return pins; VoiceOver activates the same state.
    private func expandable<Row: View, Detail: View>(id: String, label: String?, accessibility: String, @ViewBuilder row: () -> Row, @ViewBuilder detail: () -> Detail) -> some View {
        let open = expansion.isExpanded(id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary).frame(width: 10)
                if let label { Text(label).font(.caption.bold()) }
                row()
            }
            if open { detail().padding(.leading, 14).padding(.bottom, 4) }
        }
        .padding(.vertical, 2).padding(.horizontal, 4)
        .background(focused == id ? Color.accentColor.opacity(0.12) : open ? Color.secondary.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onHover { expansion.hover(id, $0) }
        .onTapGesture { expansion.activate(id) }
        .focusable().focused($focused, equals: id)
        .onKeyPress(keys: [.space, .return]) { _ in expansion.activate(id); return .handled }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
        .accessibilityValue(open ? "Details shown" : "Details hidden")
        .accessibilityHint("Press to show or hide details")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { expansion.activate(id) }
    }
}

struct AssessmentStatusPill: View {
    var status: AgentAssessment.Status
    var body: some View {
        let color: Color = status == .onTrack ? .green : status == .atRisk ? .orange : status == .blocked ? .red : .blue
        Text(status.label).font(.caption.bold()).padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
            .accessibilityLabel("Status: " + status.label)
    }
}

/// Nested JSON as an indented outline.
struct AgentJSONDetailView: View {
    var json: AgentJSON
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(json.outline()) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if !line.key.isEmpty { Text(line.key).foregroundStyle(.secondary) }
                    if let value = line.value { Text(value).fixedSize(horizontal: false, vertical: true) }
                }.font(.caption).padding(.leading, CGFloat(line.depth) * 12)
            }
        }.textSelection(.enabled)
    }
}

struct AgentPortraitsView: View {
    @ObservedObject var store = Store.shared
    @ObservedObject var portraits = PortraitService.shared
    @State private var notice = ""
    var body: some View {
        let agents = store.sessions.filter { $0.agent != nil }
        VStack(spacing: 0) {
            ScrollView {
                if agents.isEmpty { Text("No agents yet.").foregroundStyle(.secondary).padding(24) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 420), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(agents) { AgentPortraitCard(session: $0, portraits: portraits, notice: $notice) }
                }.padding(16)
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).padding(8) }
            Text("While this window is open, portraits refresh when an agent's assessment changes, at most every few minutes per agent. Closing it stops automatic requests.")
                .font(.caption).foregroundStyle(.secondary).padding([.horizontal, .bottom], 10)
        }.frame(minWidth: 260, minHeight: 300)
    }
}

// Stored portrait filenames carry their content hash, so a path names one image.
enum PortraitImageCache {
    private static let images: NSCache<NSString, NSImage> = { let cache = NSCache<NSString, NSImage>(); cache.countLimit = 64; return cache }()
    private(set) static var loads = 0
    static func image(_ latest: AgentPortraitRecord.Image?) -> NSImage? {
        guard let latest else { return nil }
        if let cached = images.object(forKey: latest.path as NSString) { return cached }
        loads += 1
        guard let image = NSImage(contentsOfFile: latest.path) else { return nil }
        images.setObject(image, forKey: latest.path as NSString)
        return image
    }
}

struct AgentPortraitCard: View {
    @ObservedObject var session: Session
    @ObservedObject var portraits: PortraitService
    @Binding var notice: String
    var imageHeight: CGFloat? = nil
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let config = session.agent ?? AgentConfig(), latest = config.portrait?.latest
            let image = PortraitImageCache.image(latest)
            let stale = latest.map { $0.cacheKey != PortraitService.cacheKey(agent: session.id, config: config) } ?? false
            let generating = portraits.isGenerating(session.id)
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                            .accessibilityLabel("Portrait of " + session.title)
                            .contextMenu {
                                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
                                Button("Save…") { save(latest) }
                                if NSSharingService(named: .addToIPhoto) != nil {
                                    Button("Save to Photos") { PhotoImageShare.save(image, notice: { notice = $0 }) }
                                }
                            }
                    } else {
                        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)).aspectRatio(1, contentMode: .fit)
                            .overlay(Text(generating ? "Painting…" : "No portrait yet").font(.caption).foregroundStyle(.secondary))
                    }
                    if generating { ProgressView().controlSize(.small).padding(6).background(.regularMaterial, in: Circle()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(6) }
                }
                .frame(height: imageHeight)
                HStack {
                    Text(session.title).font(.headline).lineLimit(1)
                    Spacer()
                    Button { Task { await portraits.request(session, store: .shared, origin: .menu, force: true) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Refresh portrait")
                        .disabled(generating).help("Request a new portrait now, even if one was made recently.")
                }
                if let latest {
                    Text("Updated " + AgentAge.short(latest.generatedAt, now: context.date) + " ago" + (stale ? " · newer information available" : ""))
                        .font(.caption).foregroundStyle(stale ? .orange : .secondary)
                }
                if let failure = config.portrait?.failure {
                    Text("Couldn't refresh: " + failure + " · " + AgentAge.short(config.portrait?.failedAt, now: context.date) + " ago").font(.caption).foregroundStyle(.orange).lineLimit(3)
                }
            }
        }
    }
    private func save(_ image: AgentPortraitRecord.Image?) {
        guard let image, let bytes = try? Data(contentsOf: URL(fileURLWithPath: image.path)) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = session.title + " portrait.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try bytes.write(to: url, options: .atomic); notice = "Saved " + url.lastPathComponent + "." }
        catch { notice = "Couldn't save: " + error.localizedDescription }
    }
}
