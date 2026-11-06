import AppKit
import SwiftUI

struct ProviderLogo: View {
    let engine: String
    private var provider: String {
        ["muse": "meta", "claude": "anthropic", "codex": "openai"][engine] ?? engine
    }
    private var label: String {
        ["muse": "Meta", "claude": "Anthropic", "codex": "OpenAI", "parking": "Parking Lot", "unassigned": "Choose a provider", ConverseExchange.unboundEngine: "Imported · choose a provider"][engine] ?? engine.capitalized
    }
    private var brandColor: Color {
        switch engine {
        case "muse": return Color(red: 4 / 255, green: 103 / 255, blue: 223 / 255)
        case "claude": return Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
        default: return .primary // OpenAI specifies an uncolored Blossom.
        }
    }
    var body: some View {
        Group {
            if engine == "parking" || engine == "unassigned" {
                ParkingLotShoe()
            } else if engine == ConverseExchange.unboundEngine {
                Image(systemName: "tray.and.arrow.down").resizable().scaledToFit()
            } else if let url = Bundle.main.url(forResource: provider, withExtension: "svg", subdirectory: "ProviderLogos"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            } else {
                Text(String(label.prefix(1))).font(.system(size: 14, weight: .bold))
            }
        }.frame(width: 20, height: 20).foregroundStyle(brandColor)
            .accessibilityLabel(label).help(label)
    }
}

/// Starter sessions have implementation defaults before the human chooses a provider.
/// Keep those defaults out of the sidebar and pane header; observe the guide so
/// choosing a provider updates every parked starter row immediately.
struct SessionProviderLogo: View {
    @ObservedObject var session: Session
    @ObservedObject var guide: FirstRunGuide
    private var engine: String {
        if let record = guide.record,
           [record.supportID, record.codingID, record.agentID].contains(session.id) {
            if record.provider == nil { return "unassigned" }
            if ["choose", "later", "login"].contains(record.stage), let provider = record.provider { return provider }
        }
        if let agent = session.agent { return AgentModels.parse(agent.model)?.engine ?? "muse" }
        return session.entry.engine
    }
    var body: some View { ProviderLogo(engine: engine) }
}
