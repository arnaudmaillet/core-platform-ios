import UIKit

/// The tick a pull gives as it crosses its threshold under the finger — the
/// Following shelf's "pull to push" (`PostShelfSection.followEndPull`), and
/// every pull-to-refresh since #1354 (the owner, 2026-10-17).
///
/// Once per crossing: going back under the threshold re-arms it, and holding
/// past it says nothing more. A pull that only DRIFTS over the line — a
/// bounce-back, a refresh already running — says nothing either: the caller
/// tells it whether a finger is on the list.
@MainActor
public final class PullThresholdFeedback {
    private let haptic = HapticSelection()
    /// Past the threshold right now, and already said so.
    public private(set) var isArmed = false

    public init() {}

    /// Warms the generator when a pull begins, so the tick is not late.
    public func prepare() {
        haptic.prepare()
    }

    /// Re-reads the pull. Returns whether this call ticked.
    @discardableResult
    public func update(pulled distance: CGFloat, threshold: CGFloat, isTracking: Bool) -> Bool {
        guard distance >= threshold else {
            isArmed = false
            return false
        }
        guard !isArmed, isTracking else { return false }
        isArmed = true
        haptic.selectionChanged()
        return true
    }
}
