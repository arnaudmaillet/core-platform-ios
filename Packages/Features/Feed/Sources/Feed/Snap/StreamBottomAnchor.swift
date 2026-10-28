import UIKit

/// A stream shorter than its viewport STARTS FROM THE BOTTOM, as in a
/// messaging app (#1799, the owner's experiment of 2026-10-27): two messages
/// rest just above the composer, not under the top bar.
///
/// Anchoring only — no order changes anywhere. The room left above a short
/// stream (the SLACK) is added to its top inset; a stream as tall as its
/// viewport has none, and nothing changes. Growing past the viewport is
/// continuous: the slack shrinks to 0, with no jump.
///
/// ⚠️ NOT AN INVERTED COLLECTION VIEW (a flipped `transform`): the lifted
/// preview, text selection, the day pills, VoiceOver and the scroll indicator
/// would all need un-flipping. And because the slack is part of the INSET,
/// every formula that reads "the top" as `-adjustedContentInset.top` keeps
/// working.
///
/// One helper for every host, so no screen grows its own arithmetic: the
/// conversation (phase 1), the comments (phase 2).
enum StreamBottomAnchor {
    /// QA, DEBUG only, off by default: `-stream-bottom-anchor` turns the
    /// experiment on. Without it every stream is top-aligned, as before.
    static let isEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-stream-bottom-anchor")
        #else
        false
        #endif
    }()

    /// The room above a stream of `contentHeight` in a `viewport` — the
    /// stream's bounds less its top and bottom insets, the composer's
    /// clearance included, and WITHOUT any slack already applied.
    static func slack(viewport: CGFloat, contentHeight: CGFloat) -> CGFloat {
        max(0, viewport - contentHeight)
    }

    /// `scrollView`'s slack, given the slack it wears now (`current`, part of
    /// its top inset): the viewport is measured as if it wore none.
    static func slack(for scrollView: UIScrollView, wearing current: CGFloat) -> CGFloat {
        let insets = scrollView.adjustedContentInset
        let viewport = scrollView.bounds.height - (insets.top - current) - insets.bottom
        return slack(viewport: viewport, contentHeight: scrollView.contentSize.height)
    }
}
