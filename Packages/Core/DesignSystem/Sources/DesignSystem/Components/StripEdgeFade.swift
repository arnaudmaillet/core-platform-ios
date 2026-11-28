import UIKit

/// The edge fade on a selector strip whose pages are cut off (#2475, the
/// owner 2026-11-28): the strip's content fades out on the side, or the
/// sides, past which titles are hidden, and nowhere when the whole row is in
/// view — so a cut title reads as "there is more this way", never as a
/// clipped word.
///
/// Opt-in (`PagedTabBar.fadesCutEdges`, kept on the strip's scroll view):
/// only the profile's selector, which can hold seven pages in a bar, wears
/// it today.
///
/// ⚠️ **A MASK ON THE SCROLL VIEW, NEVER AN ALPHA ON A LABEL.** Inside a bar
/// platter a leaf label's partial alpha renders opaque (`SegmentView`); a
/// container's mask fades what it holds as one. The mask sits in the scroll
/// view's own layer, whose bounds move with the content offset, so it is
/// re-laid on every layout pass — UIKit lays a scroll view out on every
/// scroll step (`StripScrollView.layoutSubviews`).
@MainActor
enum StripEdgeFade {
    /// How far the fade runs in from a cut edge.
    static let depth: CGFloat = 24
    /// Which sides of a viewport `width` wide, at `offset` over content
    /// `contentWidth` wide, hide something. Pure, for tests.
    nonisolated static func cutSides(
        offset: CGFloat, width: CGFloat, contentWidth: CGFloat
    ) -> (leading: Bool, trailing: Bool) {
        let overflow = contentWidth - width
        guard width > 0, overflow > 0.5 else { return (false, false) }
        return (offset > 0.5, offset < overflow - 0.5)
    }

    /// Fades `scroller`'s cut sides, or takes the mask away — when it opted
    /// in; nothing otherwise.
    static func apply(to scroller: UIScrollView) {
        guard (scroller as? StripScrollView)?.fadesCutEdges == true else {
            if scroller.layer.mask is StripEdgeFadeMask { scroller.layer.mask = nil }
            return
        }
        let width = scroller.bounds.width
        let cut = cutSides(offset: scroller.contentOffset.x, width: width, contentWidth: scroller.contentSize.width)
        guard cut.leading || cut.trailing else {
            if scroller.layer.mask is StripEdgeFadeMask { scroller.layer.mask = nil }
            return
        }
        let mask = (scroller.layer.mask as? StripEdgeFadeMask) ?? {
            let made = StripEdgeFadeMask()
            made.startPoint = CGPoint(x: 0, y: 0.5)
            made.endPoint = CGPoint(x: 1, y: 0.5)
            scroller.layer.mask = made
            return made
        }()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.frame = scroller.bounds
        let edge = Double(min(0.5, depth / width))
        mask.locations = [0, NSNumber(value: edge), NSNumber(value: 1 - edge), 1]
        let opaque = UIColor.black.cgColor
        let clear = UIColor.clear.cgColor
        mask.colors = [cut.leading ? clear : opaque, opaque, opaque, cut.trailing ? clear : opaque]
        CATransaction.commit()
    }
}

/// The fade's own layer class, so a mask someone else set is never taken.
final class StripEdgeFadeMask: CAGradientLayer {}

extension PagedTabBar {
    /// Whether the strip fades out on the side where pages are cut off
    /// (`StripEdgeFade`, #2475). Off by default.
    public var fadesCutEdges: Bool {
        get { scroller.fadesCutEdges }
        set {
            scroller.fadesCutEdges = newValue
            StripEdgeFade.apply(to: scroller)
        }
    }

    #if DEBUG
    /// Which sides the fade covers now — what a test reads.
    public var debugFadedEdges: (leading: Bool, trailing: Bool) {
        guard let mask = scroller.layer.mask as? StripEdgeFadeMask,
              let colors = mask.colors as? [CGColor], colors.count == 4 else { return (false, false) }
        return (colors[0].alpha < 0.5, colors[3].alpha < 0.5)
    }

    /// Lays the fade as a scroll step would. Tests.
    public func debugApplyEdgeFade() { StripEdgeFade.apply(to: scroller) }
    #endif
}
