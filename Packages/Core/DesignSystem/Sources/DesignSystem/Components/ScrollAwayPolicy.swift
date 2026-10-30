import CoreGraphics

/// AWAY FROM ITS START, A STREAM'S SLOT OFFERS THE WAY BACK (#1929, the owner
/// 2026-10-30): a conversation's newest message, a post's text. Pure: the
/// host feeds it the distance from the stream's start on every scroll, and
/// reads `showsReturn`.
///
/// - **It shows** once the start is more than `showFactor` viewports away,
///   and only on the viewer's own scroll (tracking or decelerating).
///   Programmatic moves — the tail pin, a quote jump, a new message followed
///   — never show it. A stream that fits its viewport never can.
/// - **It hides** once the start is back within `hideFactor` of a viewport,
///   whatever moved it. The two thresholds keep it from flickering at the
///   edge.
public struct ScrollAwayPolicy: Equatable, Sendable {
    /// How many viewports away the start must be before the way back shows.
    public static let showFactor: CGFloat = 1
    /// Within how much of a viewport the start must come back for it to go.
    public static let hideFactor: CGFloat = 0.5

    public private(set) var showsReturn = false

    public init() {}

    /// Answers for a stream `distance` points from its start in a viewport
    /// `viewport` points tall; `isUserScroll` says whether the viewer moved
    /// it. Returns `showsReturn`.
    @discardableResult
    public mutating func update(distance: CGFloat, viewport: CGFloat, isUserScroll: Bool) -> Bool {
        guard viewport > 0 else { return showsReturn }
        if showsReturn {
            if distance < viewport * Self.hideFactor { showsReturn = false }
        } else if isUserScroll, distance > viewport * Self.showFactor {
            showsReturn = true
        }
        return showsReturn
    }

    /// A new stream: back at its start.
    public mutating func reset() { showsReturn = false }
}
