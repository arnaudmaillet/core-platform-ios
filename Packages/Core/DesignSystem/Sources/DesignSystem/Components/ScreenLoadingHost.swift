import UIKit

/// THE screen's loading driver (#1768): which of its three layers shows —
/// the skeleton, the content or the status (empty, failed, taking longer) —
/// on the kit's timing (`SkeletonGate`), so a screen spells only what each
/// layer looks like.
///
/// - `load()`: content and status down; the skeleton after the delay, held
///   its minimum once up; after `takingLonger`, `onTakingLonger` — the screen
///   says so on its status with a Try Again, rather than an endless shimmer.
/// - `showContent()`: the content, cross-faded in over the skeleton when the
///   skeleton was on screen (`crossfadeSkeleton(to:)`, the one skeleton exit),
///   at once otherwise — the rows are applied before, so the fade is
///   hydration in place.
/// - `showStatus()`: the status (configured by the screen just before).
///
/// The layers are the screen's own views, laid out by it; the host only
/// shows and hides them.
@MainActor
public final class ScreenLoadingHost {
    public enum Layer: Equatable, Sendable {
        case skeleton, content, status
    }

    private let container: UIView
    private let skeleton: UIView
    private let content: UIView
    private let status: UIView
    private let gate: SkeletonGate

    /// The layer on screen; nil while a load waits out the skeleton's delay.
    public private(set) var shown: Layer?

    /// Still loading after the gate's `takingLonger`: configure the status
    /// ("Taking longer than usual", Try Again) and call `showStatus()`.
    public var onTakingLonger: (() -> Void)? {
        get { gate.onTakingLonger }
        set { gate.onTakingLonger = newValue }
    }

    public init(
        container: UIView, skeleton: UIView, content: UIView, status: UIView,
        timing: SkeletonGate.Timing = .standard, clock: LoadingClock = .system
    ) {
        self.container = container
        self.skeleton = skeleton
        self.content = content
        self.status = status
        gate = SkeletonGate(timing: timing, clock: clock)
        gate.onSkeletonChange = { [weak self] showing in
            guard let self, showing else { return }
            show(.skeleton, dissolving: false)
        }
    }

    /// A load starts with nothing to show: the skeleton on the gate's timing.
    /// A screen already showing its content keeps it (a refresh).
    public func load() {
        guard shown != .content else { return }
        if shown != .skeleton { show(nil, dissolving: false) }
        gate.begin()
    }

    /// The content is applied: it shows, after the skeleton's minimum.
    public func showContent() {
        reveal(.content)
    }

    /// The status is configured: it shows, after the skeleton's minimum.
    public func showStatus() {
        reveal(.status)
    }

    private func reveal(_ layer: Layer) {
        gate.finish { [weak self] in
            guard let self else { return }
            show(layer, dissolving: shown == .skeleton && container.window != nil)
        }
    }

    private func show(_ layer: Layer?, dissolving: Bool) {
        shown = layer
        let target: UIView? = switch layer {
        case .skeleton: skeleton
        case .content: content
        case .status: status
        case nil: nil
        }
        for view in [content, status] where view !== target { view.isHidden = true }
        guard let target, target !== skeleton else {
            if layer == .skeleton { skeleton.showSkeleton() } else { skeleton.isHidden = true }
            return
        }
        guard dissolving else {
            skeleton.isHidden = true
            target.isHidden = false
            target.alpha = 1
            return
        }
        skeleton.crossfadeSkeleton(to: target)
    }
}
