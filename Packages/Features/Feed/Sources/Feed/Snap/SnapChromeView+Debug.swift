import DesignSystem
import ThreadKit
import UIKit

// The chrome's DEBUG accessors, for the tests and the landing probes — out
// of `SnapChromeView.swift` (#2521), whose members they read.
#if DEBUG
extension SnapChromeView {
    /// The scrim and the caption, for the scrim's suite.
    var debugScrimView: UIView { scrimView }
    var debugScrimClip: UIView { scrimClip }
    var debugCaptionLabel: UIView { captionLabel }

    /// How far the column stands below its resting seat right now (#2326).
    var debugColumnGlide: CGFloat { glassColumn.transform.ty }
    /// The column's lift at rest, as this chrome stands.
    var debugColumnLineLift: CGFloat { currentColumnLineLift }

    /// The band's and the stream's frames in this chrome's space.
    var debugBandFrame: CGRect { commentTicker.frame }
    var debugBandTrailingEnd: (cornerRadius: CGFloat, fadeLocations: [NSNumber]?) {
        commentTicker.debugTrailingEnd
    }
    var debugStreamFrame: CGRect { subtitleView.frame }
    var debugRailFrame: CGRect { shortcutRail.frame }
    /// The wheel, which rides the column's layer (#1872).
    var debugShortcutRail: SnapShortcutRailView { shortcutRail }

    /// The caption's frame in `space`, for the landing probe that compares
    /// the flight replica with the page it fades into.
    func debugCaptionFrame(in space: UICoordinateSpace) -> CGRect {
        captionLabel.convert(captionLabel.bounds, to: space)
    }

    /// The page strip and the caption, so a spec can state where the strip sits
    /// in the column — and that its arrival moves nothing else.
    var debugPageBarFrame: CGRect { mediaPageBar.frame }
    /// The action column's two bubbles, for the spec that
    /// holds them still across the media and comments layouts.
    var debugBoostButton: UIButton { boostButton }
    var debugSoundBubble: SnapSoundBubbleButton { soundBubble }
    var debugSoundHold: HoldToArmPresenter? { actionColumn.soundHold }
    /// The glass column's items, shape by shape, as the column stands them
    /// now (#1872).
    var debugColumnItems: [[String]] { actionColumn.columnSlots().map { $0.map(\.id) } }
    var debugGlassColumn: SnapGlassColumn { glassColumn }
    /// `view`'s frame in this chrome's space — a column item stands in its
    /// bubble's glass, not in the chrome (#1872).
    func debugFrame(of view: UIView) -> CGRect { view.convert(view.bounds, to: self) }
    /// The sound's station, shown or not — where its bubble stands.
    var debugSoundStationFrame: CGRect { soundStation.convert(soundStation.bounds, to: self) }
    /// The comment band, in the chrome's space.
    var debugTickerFrame: CGRect { commentTicker.frame }
    /// The comment band and the subtitle pill themselves (#1798).
    var debugCommentTicker: SnapCommentTickerView { commentTicker }
    var debugSubtitleView: SnapSubtitleView { subtitleView }
    var debugCaptionFrame: CGRect { captionLabel.frame }
    var debugPageBar: SnapMediaPageBarView { mediaPageBar }

    /// The like pill's transform — identity, always (#1186).
    var debugBoostButtonTransform: CGAffineTransform { boostButton.transform }
    /// The count under the pill's heart — nil while the pill is not showing.
    var debugLikeBadgeText: String? { boostButton.isHidden ? nil : boostButton.configuration?.title }
    /// Where the heart is drawn, in the chrome's space.
    ///
    /// ⚠️ THE GLYPH, centred in its image view, which stands taller than the
    /// picture it shows (~2 pt above and below the heart). Read off the
    /// view, the gaps looked even only while the button was measured half
    /// laid out — at its title's width, the heart off centre; fully laid out
    /// in the column's glass (#1872), the view's padding showed.
    var debugLikeHeartFrame: CGRect {
        boostButton.layoutIfNeeded()
        guard let image = boostButton.imageView else { return .zero }
        let frame = image.convert(image.bounds, to: self)
        guard let drawn = image.image?.size, drawn.height > 0, drawn.height < frame.height else { return frame }
        return frame.insetBy(dx: 0, dy: (frame.height - drawn.height) / 2)
    }
    /// Where the count is drawn, in the chrome's space.
    var debugLikeBadgeFrame: CGRect {
        boostButton.layoutIfNeeded()
        guard let label = boostButton.titleLabel else { return .zero }
        return label.convert(label.bounds, to: self)
    }
}
#endif
