import UIKit

/// The autoplay gate's geometry: which part of a scrolling grid the viewer can
/// see, and how much of a cell's media is inside it.
///
/// Pure, so the two questions that decide whether a grid plays anything can be
/// asked without a window.
///
/// ⚠️ A CONTENT INSET IS NOT ALWAYS CHROME. On For You both insets are floating
/// bars that sit OVER the content, so removing them leaves what is visible. A
/// page hosted under a header that scrolls away (the place page, the profile)
/// is inset at the top by the header's whole height as RESERVED RANGE (content
/// begins there, nothing hides behind it) and at the foot by whatever empty
/// room lets a short page still travel that header's distance. Removed as if
/// they were chrome, the place page's 479 + 369 left a 26pt band on an 874pt
/// screen: every Discover tile read as under half visible, and the tile a
/// dismissal had just landed on was stopped the instant the page appeared.
/// Such a host must say what really covers it (`hostOcclusion`); the profile
/// gallery reached the same rule first.
public enum GridPlaybackVisibility {
    /// Minimum share of a cell's MEDIA that must be inside the viewport before
    /// it may autoplay. A tile creeping in at an edge is not something the
    /// viewer is looking at.
    public static let minimumVisibleFraction: CGFloat = 0.5

    /// The part of the grid's bounds the viewer can see.
    ///
    /// - Parameters:
    ///   - bounds: the scroll view's bounds (its content coordinates).
    ///   - contentInset: its adjusted content inset — used as the cover only
    ///     when the host has not said otherwise.
    ///   - hostOcclusion: what actually covers the page, from a host whose
    ///     insets are layout rather than chrome. `nil` keeps the inset.
    public static func viewport(
        bounds: CGRect, contentInset: UIEdgeInsets, hostOcclusion: UIEdgeInsets?
    ) -> CGRect {
        bounds.inset(by: hostOcclusion ?? contentInset)
    }

    /// The share of `media` inside `viewport`, in 0...1. Zero for a degenerate
    /// rect or one wholly outside.
    public static func visibleFraction(of media: CGRect, in viewport: CGRect) -> CGFloat {
        guard media.width > 0, media.height > 0 else { return 0 }
        let visible = media.intersection(viewport)
        guard !visible.isNull, !visible.isEmpty else { return 0 }
        return (visible.width * visible.height) / (media.width * media.height)
    }

    /// Whether enough of `media` is on screen to autoplay it.
    public static func autoplays(_ media: CGRect, in viewport: CGRect) -> Bool {
        visibleFraction(of: media, in: viewport) >= minimumVisibleFraction
    }
}
