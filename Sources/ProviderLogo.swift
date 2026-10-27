import AppKit
import SwiftUI

struct ProviderLogo: View {
    let engine: String
    private var provider: String {
        ["muse": "meta", "claude": "anthropic", "codex": "openai"][engine] ?? engine
    }
    private var label: String {
        ["muse": "Meta", "claude": "Anthropic", "codex": "OpenAI"][engine] ?? engine.capitalized
    }
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: provider, withExtension: "svg", subdirectory: "ProviderLogos"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            } else {
                Text(String(label.prefix(1))).font(.system(size: 14, weight: .bold))
            }
        }.frame(width: 20, height: 20).foregroundStyle(.primary)
            .accessibilityLabel(label).help(label)
    }
}
