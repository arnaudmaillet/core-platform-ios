import UIKit

/// What the tap arbiter asks of its page (#2521): whether the comments own
/// the page, the frozen insets and the chrome's readout that bound the
/// picture, whether there is a clip to act on, and the playback it toggles
/// or holds.
@MainActor
protocol SnapMediaTapArbiterHost: UIView {
    var isCommentsEngaged: Bool { get }
    var frozenInsets: UIEdgeInsets { get }
    var chrome: SnapChromeView { get }
    var playsVideo: Bool { get }
    var isPostUnavailable: Bool { get }
    var playback: SnapCellPlayback { get }
    @discardableResult func togglePlayback(markOnPage: Bool) -> Bool?
}

/// What a tap or a hold on the full-screen page means, out of `SnapFeedCell`
/// (#2521): the screen's say first (#1550), the clip's territory between the
/// header and the page's readout, a carousel's track (#1849), then the clip
/// itself. The recognizers stay the cell's (their delegate is the cell);
/// their handlers hand the touch here.
@MainActor
final class SnapMediaTapArbiter {
    private unowned let host: any SnapMediaTapArbiterHost

    init(host: any SnapMediaTapArbiterHost) {
        self.host = host
    }

    // The page's state, read where the cell's code read it.
    private var isCommentsEngaged: Bool { host.isCommentsEngaged }
    private var frozenInsets: UIEdgeInsets { host.frozenInsets }
    private var chrome: SnapChromeView { host.chrome }
    private var bounds: CGRect { host.bounds }
    private var playsVideo: Bool { host.playsVideo }
    private var isPostUnavailable: Bool { host.isPostUnavailable }
    private var playback: SnapCellPlayback { host.playback }
    private func togglePlayback() { host.togglePlayback(markOnPage: true) }

    /// A tap on the page, asked of the screen first: true when it took it
    /// (#1550: the side list open closes, and the clip is left alone).
    var interceptsMediaTap: (() -> Bool)?

    /// A tap that reached the page's own background. Internal (not private) so
    /// the arbitration is unit-testable — the simulator injects no touches, and
    /// this decision is the whole of what a tap means here.
    func tapMedia(at point: CGPoint) {
        // The screen's say first (#1550): with the side list open, a tap on
        // the card closes the list rather than pausing.
        if interceptsMediaTap?() == true { return }
        // A text page's engagement is its permanent resting state: no tap
        // collapses it, and it has no media to pause.
        if isCommentsEngaged { return }
        guard playbackTapRegionContains(point) else { return }
        // A carousel's track (#1849): the screen pauses the post's sound and
        // the clip on screen together.
        if let onPostTrackTap {
            onPostTrackTap()
            return
        }
        togglePlayback()
    }

    /// A carousel's track (#1849): the post's sound is the screen's song
    /// player's, one track across every page, and a tap or a hold on the
    /// page acts on it as well as on the clip on screen. Set by the screen
    /// for a carousel, nil for any other post.
    var onPostTrackTap: (() -> Void)?
    /// A hold on a carousel's page began (true) or ended (false).
    var onPostTrackHold: ((Bool) -> Void)?

    /// THE CLIP'S TERRITORY: the media band, between the header and the page's
    /// bottom readout.
    ///
    /// The gesture used to take the whole cell, which put play/pause on the
    /// caption, on the dead space under it, and in the band the nav bar's
    /// platters float in — a tap aimed at the gap between two bar buttons
    /// stopped the video. What the viewer means by "the picture" is bounded at
    /// the top by the header and at the bottom by the first thing that is
    /// clearly the page talking about the post: the comment band, or a
    /// gallery's page dots where they sit above it.
    ///
    /// The trailing rail is NOT excluded here: it is interactive chrome, and
    /// `isInteractiveTouch` already keeps every control's touches for the
    /// control. This boundary is about territory, not about targets.
    func playbackTapRegionContains(_ point: CGPoint) -> Bool {
        playbackTapRegion.contains(point)
    }

    /// The region above, as a rectangle. The floor can only be as low as the
    /// chrome's readout and never above the header — a cell that has not been
    /// laid out yet answers with an empty rect rather than a negative one.
    var playbackTapRegion: CGRect {
        let top = frozenInsets.top
        let floor = max(top, chrome.bottomReadoutTop)
        return CGRect(x: 0, y: top, width: bounds.width, height: floor - top)
    }

    /// ⚠️ THE SAME TERRITORY AS THE TAP, and it has to be: two gestures that
    /// disagree about where the picture is are two different pictures as far as
    /// the hand is concerned. So the hold is off duty exactly where the tap is
    /// — outside the media band, and while the thread is open (where the strip
    /// means "bring the media back").
    func beginMediaHold(at point: CGPoint) {
        guard !isCommentsEngaged, playbackTapRegionContains(point) else { return }
        // A carousel's track is held with its page, picture or clip (#1849).
        onPostTrackHold?(true)
        guard playsVideo, !isPostUnavailable else { return }
        playback.beginHold()
    }

    func endMediaHold() {
        onPostTrackHold?(false)
        playback.endHold()
    }
}
