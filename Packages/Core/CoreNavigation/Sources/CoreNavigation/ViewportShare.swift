import QuartzCore
import UIKit

/// THE SHARE OF A SCREEN STILL ON SCREEN, 0…1 (#1914, the owner 2026-10-30):
/// what a clip's gate reads, under one rule — **a clip plays while its
/// surface holds most of the viewport**: it plays at 0.5 and above, pauses
/// below, and its sound follows the share down from full to silent at half.
///
/// Not the post's, not the player's: whether a clip should play is a fact
/// about the SCREEN. The player cannot see what slides over it; the host
/// knows what plays and feeds the share into its own gate.
///
/// Sources, as hosts adopt them:
/// - **a screen pushed over the host, or popped off it**, animated or
///   interactive: read frame by frame from the covering screen's
///   presentation layer while the transition runs (a display link only
///   then), so a cancelled drag reports the way back (`track`);
/// - the host's own pager or drawer, reported as a fraction (`report`).
///
/// ⚠️ ONLY WHAT COVERS THE HOST. Its own pop or dismissal (a grab carrying
/// its player to a tile) is never measured: the screen under it is not a
/// cover, and the flight keeps the player playing. The host decides which
/// transitions to hand over.
@MainActor
public final class ViewportShare {
    /// The share now: 1 with nothing over the host.
    public private(set) var share: CGFloat = 1

    /// Told on every change of `share`.
    public var onChange: ((CGFloat) -> Void)?

    /// The threshold of the rule: plays at or above it.
    public static let playThreshold: CGFloat = 0.5

    /// Whether a clip plays at `share`.
    public static func plays(at share: CGFloat) -> Bool { share >= playThreshold }

    /// The sound's level at `share`: full on the whole screen, silent at the
    /// threshold, where the clip pauses.
    public static func volume(at share: CGFloat) -> Float {
        Float(min(1, max(0, (share - playThreshold) / (1 - playThreshold))))
    }

    private weak var host: UIView?
    private var link: CADisplayLink?
    private weak var cover: UIView?

    public init(host: UIView) {
        self.host = host
    }

    /// A fraction from a source of the host's own (a pager, a drawer).
    public func report(_ value: CGFloat) {
        let clamped = min(1, max(0, value))
        guard abs(clamped - share) > 0.001 else { return }
        share = clamped
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-viewport-share") {
            print(String(format: "[viewport-share] %.3f", clamped))
        }
        #endif
        onChange?(clamped)
    }

    /// Follows `coordinator`'s transition, in which `cover` is the screen
    /// sliding over the host (a push) or off it (a pop back to it). At its
    /// end the share settles on what the transition decided.
    ///
    /// - Parameter coversAtEnd: whether `cover` covers the host once the
    ///   transition completes (a push: true; a pop back: false). A cancel
    ///   reverses it.
    public func track(
        _ coordinator: UIViewControllerTransitionCoordinator, cover: UIView, coversAtEnd: Bool
    ) {
        self.cover = cover
        startLink()
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            guard let self else { return }
            stopLink()
            self.cover = nil
            let covered = context.isCancelled ? !coversAtEnd : coversAtEnd
            report(covered ? 0 : 1)
        }
    }

    /// The share of `host` left uncovered by `cover`, both in window
    /// coordinates, against the window's `bounds`. Pure, for tests.
    public static func share(host: CGRect, cover: CGRect, in bounds: CGRect) -> CGFloat {
        let visible = host.intersection(bounds)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return 0 }
        let hidden = visible.intersection(cover)
        let hiddenArea = hidden.isNull ? 0 : hidden.width * hidden.height
        return 1 - hiddenArea / (visible.width * visible.height)
    }

    private func startLink() {
        stopLink()
        let link = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // ⚠️ NOT SAMPLED NOW: before the transition's first frame the cover
        // still stands at its final frame — a push read 0, then 1, and paused
        // the clip for a frame (measured). The link's first tick reads it.
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func sample() {
        guard let host, let cover, let window = host.window else { return }
        let hostRect = host.convert(host.bounds, to: window)
        let coverLayer = cover.layer.presentation() ?? cover.layer
        let coverRect = coverLayer.convert(coverLayer.bounds, to: window.layer.presentation() ?? window.layer)
        report(Self.share(host: hostRect, cover: coverRect, in: window.bounds))
    }

    /// The display link's target, weakly holding the share so the link never
    /// keeps it alive — and ending the link once the share is gone.
    @MainActor
    private final class LinkTarget: NSObject {
        weak var owner: ViewportShare?
        init(_ owner: ViewportShare) { self.owner = owner }
        /// The link runs on the main run loop.
        @objc func tick(_ link: CADisplayLink) {
            guard let owner else { return link.invalidate() }
            owner.sample()
        }
    }
}
