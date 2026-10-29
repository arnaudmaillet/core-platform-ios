import UIKit

/// THE STEPS UNDER THE FINGER (#1881): a scroller's or a scrub's detents,
/// felt one haptic per detent crossed. The host feeds it where it is, and
/// whether the viewer drives it; this owns the detection, so every host
/// plays the same thing the same way.
///
/// - **One role per index change**, the host's role (`step` for a coarse
///   detent, `tick` for a fine one), paced by `Haptics`: a fast flick plays
///   fewer than it crosses, never a buzz.
/// - **Silent when the viewer does not drive it**: a programmatic scroll, a
///   reload, a settle back onto the detent it sat on. Its index is followed
///   all the same, so the next driven move starts from where it truly is.
/// - **Silent past either end**: no tick on a rubber band.
@MainActor
public final class DetentFeedback {
    /// What each detent crossed plays.
    public let role: Haptic
    /// The detent last seen, driven or not.
    public private(set) var index: Int?

    public init(role: Haptic = .step) {
        self.role = role
    }

    /// Warms the role when the gesture starts (touch-down, a drag's begin).
    public func prepare() {
        Haptics.prepare(role)
    }

    /// Re-reads the detent: `index`, in `range` (nil for no ends), driven by
    /// the viewer's finger or a glide they started — or not. Returns whether
    /// this call played.
    @discardableResult
    public func update(index newIndex: Int, in range: ClosedRange<Int>? = nil, isDriven: Bool) -> Bool {
        // Past an end: the rubber band says nothing, and the last detent
        // stays the edge one.
        if let range, !range.contains(newIndex) { return false }
        defer { index = newIndex }
        guard let index, newIndex != index, isDriven else { return false }
        Haptics.play(role)
        return true
    }

    /// Re-reads a position along an axis of evenly spaced detents: detent n
    /// sits at `origin + n × spacing`, and a position belongs to the nearest.
    @discardableResult
    public func update(
        position: CGFloat, spacing: CGFloat, origin: CGFloat = 0,
        count: Int? = nil, isDriven: Bool
    ) -> Bool {
        guard spacing > 0 else { return false }
        let detent = Int(((position - origin) / spacing).rounded())
        return update(index: detent, in: count.map { 0...max(0, $0 - 1) }, isDriven: isDriven)
    }

    /// Takes `index` as where it now is, playing nothing: a reload, a
    /// programmatic jump.
    public func reset(to index: Int?) {
        self.index = index
    }
}
