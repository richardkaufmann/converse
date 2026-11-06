import AppKit

enum PaneTextChange { case bigger, smaller, reset }
/// A focused view that sizes its own text (e.g. a Parking Lot editor) adopts this.
protocol PaneTextScalable: AnyObject { func applyPaneText(_ change: PaneTextChange) }
enum PaneTextScaling {
    /// Called for "no focused pane": every Parking Lot pane resizes too. Set by the lot side.
    static var allLots: ((PaneTextChange) -> Void)?
}
