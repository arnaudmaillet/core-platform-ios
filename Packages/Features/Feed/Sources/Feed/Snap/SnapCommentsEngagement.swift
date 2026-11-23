import DesignSystem
import ThreadKit
import UIKit

/// What the comments' engagement asks of its page (#2521): the content view
/// and the page's stage it installs into, the chrome it fades, whether the
/// post has media, the frozen insets, the window, and the card swipe's
/// recognizer and the screen's page drive.
@MainActor
protocol SnapCommentsEngagementHost: UIView {
    var contentView: UIView { get }
    var pageStage: UIView { get }
    var chrome: SnapChromeView { get }
    var mediaURL: URL? { get }
    var frozenInsets: UIEdgeInsets { get }
    var cardSwipeRecognizer: UIPanGestureRecognizer { get }
    var onRequestCommentsPageDrive: ((CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void)? { get }
}

/// The comments' engagement on the full-screen page, out of `SnapFeedCell`
/// (#2521): the comments region and its install, the header's frost, the
/// engagement's interpolatable state and its switch, the resting
/// placeholder, and the card swipe's territory, begin gate and drive.
///
/// ⚠️ The card swipe's recognizer, its target and its delegate stay the
/// cell's, and so does `gestureRecognizerShouldBegin`, in the cell's class
/// body: its override hands the begin gate here in one line
/// (`cardSwipeShouldBegin`), and its `@objc` handler hands over the pan.
///
/// ⚠️ `installComments` lays out in its caller's turn, so inside the
/// engagement's spring when it is called from there.
///
/// Shared with the page: none of its multi-writer properties (`mediaCard.alpha`,
/// `contentView.backgroundColor`, `chrome.alpha`, `columnStage.alpha`). The
/// chrome's engaged fade is the chrome's own (`setCommentsEngagedProgress`).
@MainActor
final class SnapCommentsEngagement {
    private unowned let host: any SnapCommentsEngagementHost

    init(host: any SnapCommentsEngagementHost) {
        self.host = host
    }

    // The page's state, read where the cell's code read it.
    private var contentView: UIView { host.contentView }
    private var pageStage: UIView { host.pageStage }
    private var chrome: SnapChromeView { host.chrome }
    private var mediaURL: URL? { host.mediaURL }
    private var frozenInsets: UIEdgeInsets { host.frozenInsets }
    private var window: UIWindow? { host.window }
    private var cardSwipeRecognizer: UIPanGestureRecognizer { host.cardSwipeRecognizer }
    private var onRequestCommentsPageDrive: ((CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void)? {
        host.onRequestCommentsPageDrive
    }

    /// Whether the cell is in the comments-engaged layout (media docked in
    /// the strip's slot, chrome faded out, caption re-homed beside the
    /// media). Pure layout state: playback is deliberately untouched.
    private(set) var isCommentsEngaged = false
    /// The engaged state's comments region: a cell-owned container spanning
    /// the strip's bottom to the cell's bottom edge. The comments UI itself
    /// is NOT cell state — the feed VC installs a child controller's view
    /// via `installComments` on engage and reclaims it on disengage, so
    /// thread data, scroll position, and a half-typed reply never live in a
    /// recycled cell. Z-order: above the media (which vacates the region),
    /// below the chrome (the action rail floats over it).
    let commentsContainer = SnapCommentsContainerView()
    private var commentsContainerConstraints: [NSLayoutConstraint] = []
    /// The engaged header's frost: a dissolving blur band across the top
    /// inset, so the nav chrome stays legible where comment rows glide
    /// under it. A SIBLING of the comments container, not a child, so it
    /// never rides the stream's transform.
    let headerFrost = ProgressiveFrostView(
        maskColors: SnapCommentsLayout.headerFrostMaskColors,
        maskLocations: SnapCommentsLayout.headerFrostMaskLocations
    )
    private var headerFrostConstraints: [NSLayoutConstraint] = []

    /// Installs the comments UI (a child controller's view, owned by the
    /// feed VC) into the region below the strip, settled and ready BEFORE
    /// the engagement animates: the container starts invisible with a
    /// small downward offset so the one spring block lifts it in with the
    /// rest of the mutation.
    func installComments(_ view: UIView) {
        commentsContainer.isHidden = false
        // Pure crossfade, no translation: the bottom band's geometry must
        // hold dead-still while the old footer and the composer swap.
        commentsContainer.alpha = 0
        NSLayoutConstraint.deactivate(commentsContainerConstraints)
        // FULL height: the stream spans the whole cell and slides under the
        // strip (the hosted scroll view rests its content below the strip
        // via inset — `setEngagedInsets` on the child).
        commentsContainerConstraints = [
            commentsContainer.topAnchor.constraint(equalTo: pageStage.topAnchor),
            commentsContainer.leadingAnchor.constraint(equalTo: pageStage.leadingAnchor),
            commentsContainer.trailingAnchor.constraint(equalTo: pageStage.trailingAnchor),
            commentsContainer.bottomAnchor.constraint(equalTo: pageStage.bottomAnchor),
        ]
        NSLayoutConstraint.activate(commentsContainerConstraints)
        // The header band spans EXACTLY its container — screen top to where
        // the stream's content begins — and ramps across all of it: opaque
        // at the screen's edge, fully clear at the container's inner edge.
        // Nothing spills past the chrome the band exists to serve.
        headerFrost.isHidden = false
        // The veil, on the pages where the blur alone cannot be seen.
        headerFrost.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity(hasMedia: mediaURL != nil))
        NSLayoutConstraint.deactivate(headerFrostConstraints)
        headerFrostConstraints = [
            headerFrost.topAnchor.constraint(equalTo: pageStage.topAnchor),
            headerFrost.leadingAnchor.constraint(equalTo: pageStage.leadingAnchor),
            headerFrost.trailingAnchor.constraint(equalTo: pageStage.trailingAnchor),
            headerFrost.heightAnchor.constraint(
                equalToConstant: SnapCommentsLayout.commentsTopInset(topInset: frozenInsets.top)
            ),
        ]
        NSLayoutConstraint.activate(headerFrostConstraints)
        // NOTE: no caption card is installed here. The caption is the
        // hosted stream's FIRST ROW now, so it scrolls with the comments
        // instead of floating above them — which is what removed the
        // measured caption height, the reserved strip rectangle, and the
        // job of keeping a fixed card in sync with a moving list.
        // NOTE: the media card is NOT z-lifted here. It stays at the back
        // of the stack for the whole engagement — the stream reads over it
        // through the backdrop, which is the entire point of this layout.
        // (It used to be raised above the frost so the docked tile could
        // float over the comments; that lift is what made its invisible
        // full-bleed frame eat stream touches, and it is gone with the
        // tile.)
        view.translatesAutoresizingMaskIntoConstraints = false
        commentsContainer.addSubview(view)
        view.pin(to: commentsContainer)
        contentView.layoutIfNeeded()
    }

    /// The engaged stream's top inset — where its content rests, just
    /// below the screen chrome. A pure function of the safe area now: the
    /// caption scrolls inside the stream, so nothing above it has to be
    /// measured. The VC threads this into `setEngagedInsets`.
    func engagedCommentsTopInset(safeAreaTop: CGFloat) -> CGFloat {
        SnapCommentsLayout.commentsTopInset(topInset: safeAreaTop)
    }

    /// The engagement's INTERPOLATABLE state, as one function of progress:
    /// 0 = fully engaged, 1 = fully dismissed. Every leg that can be driven
    /// continuously lives here and nowhere else, which is what lets the
    /// finger-driven pull-down and the animated engage/disengage share one
    /// definition of what the two ends look like.
    ///
    /// (The blur bands and the bubble's glass are NOT here: a material
    /// materializes through the `effect` property, which has no fractional
    /// state. They switch at the ends and are hidden behind the fading
    /// stream while the drag is in flight.)
    func setCommentsEngagementProgress(_ progress: CGFloat) {
        let t = min(max(0, progress), 1)
        commentsContainer.alpha = 1 - t
        // NO transform here. The shrink belongs to the STREAM alone (the
        // hosted list scales itself), because the footer's blur band lives
        // inside this container and a band that scales stops sitting at the
        // screen's edge — it drifts inward and reads as part of the moving
        // layer instead of as fixed chrome.
        // The header band is a SIBLING, so it never scaled; it fades on its
        // own alpha to leave with everything else. (Alpha on an effect view
        // cannot MATERIALIZE a blur, which is why the band still switches
        // its `effect` at the ends — but fading an already-built one out is
        // exactly what alpha is for.)
        headerFrost.alpha = 1 - t
        // The page's own chrome returns as the stream leaves — the ticker
        // and caption fade back IN as the comments fade out, one crossfade
        // rather than two sequential ones.
        chrome.setCommentsEngagedProgress(t)
    }

    /// Reclaims the region after disengagement settles (the VC removes the
    /// child's view; this clears the cell-side scaffolding).
    /// Whether this cell is currently showing a comments panel.
    ///
    /// The one question a caller can ask about the DISPLAY without knowing how
    /// the panel got here — which is what a specification has to be written
    /// against, since every defect in this area has been a difference between
    /// the bookkeeping and the pixels.
    var isShowingComments: Bool {
        // ⚠️ AND VISIBLE. A panel is installed at alpha 0 and revealed by the
        // engagement, so a media page's parked tap-to-comments WARM is hosted
        // here too — present, and showing nothing. Counting it would make the
        // specification claim a media page displays a thread it does not.
        !commentsContainer.isHidden
            && commentsContainer.alpha > 0
            && !commentsContainer.subviews.isEmpty
    }

    func clearComments() {
        // The comments gone, the column unfolds onto the record (#1929).
        chrome.setSoundShowsReturn(false, animated: false)
        commentsContainer.subviews.forEach { $0.removeFromSuperview() }
        commentsContainer.isHidden = true
        NSLayoutConstraint.deactivate(commentsContainerConstraints)
        commentsContainerConstraints = []
        headerFrost.isHidden = true
        headerFrost.alpha = 1
        headerFrost.effect = nil
        NSLayoutConstraint.deactivate(headerFrostConstraints)
        headerFrostConstraints = []
    }

    /// Applies or reverses the comments-engaged layout. Call inside a
    /// single `UIView.animate` spring block — every mutation here is
    /// animatable (the backdrop's dim and blur, the media's recede, chrome
    /// surface alphas, the card's glass and content), which is what keeps
    /// the whole state change ONE motion on ONE surface. The player is
    /// untouched by construction: nothing here re-hosts it, and after the
    /// dock's removal nothing here even moves its surfaces.
    /// A stand-in for the resting panel, shown at once (charter PR 5b): the
    /// same container, the same frost, the same engaged chrome, so the page
    /// looks as it will once the real panel is mounted over it.
    func installRestingPlaceholder(_ placeholder: UIView) {
        installComments(placeholder)
        // The engaged LOOK — container and frost up, backdrop dimmed, the
        // chrome's rail down — WITHOUT marking the cell engaged: the real
        // panel's mount goes through `installComments` (alpha 0) and then
        // `setCommentsEngaged(true)` to show it, and a cell already marked
        // engaged would skip that second step and leave both invisible. The
        // rail matters: with the look applied by hand the page flew in with
        // its reaction bubbles showing, which the real panel then hid.
        setCommentsEngagementProgress(0)
        if window != nil, headerFrost.effect == nil {
            headerFrost.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
        }
    }

    /// The real panel has been mounted above it: the stand-in fades and goes.
    func removeRestingPlaceholder(_ placeholder: UIView, animated: Bool = true) {
        guard placeholder.superview != nil else { return }
        if animated {
            placeholder.fadeOutSkeleton(removing: true)
        } else {
            placeholder.removeFromSuperview()
        }
    }

    func setCommentsEngaged(_ engaged: Bool) {
        guard engaged != isCommentsEngaged else { return }
        isCommentsEngaged = engaged
        // The card's page-drive pan exists ONLY while engaged — the state
        // seam is the recognizer's power switch, so no teardown path can
        // strand an armed pan in the default feed. Armed on EVERY engaged
        // post (media AND text): a vertical swipe on the card drives the
        // pager interactively, exactly like the composer bar's — it pages,
        // it never dismisses, so it's the right gesture on a text post's
        // permanent resting interface too.
        cardSwipeRecognizer.isEnabled = engaged

        if engaged {
            // One interpolatable set (see `setCommentsEngagementProgress`),
            // so the boolean legs and any driven one can never diverge.
            setCommentsEngagementProgress(0)
            // The band materializes on the same beat and the same supported
            // path (the `effect` property — alpha on an effect view is not,
            // which is also why the blur cannot ride the interactive drag).
            if window != nil, headerFrost.effect == nil {
                headerFrost.effect = UIBlurEffect(style: SnapCommentsLayout.frostStyle)
            }
        } else {
            setCommentsEngagementProgress(1)
            headerFrost.effect = nil
        }
    }

    /// The card swipe's begin gate, asked by the cell's
    /// `gestureRecognizerShouldBegin` (see there).
    func cardSwipeShouldBegin() -> Bool {
        guard isCommentsEngaged else { return false }
        let velocity = cardSwipeRecognizer.velocity(in: host)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        return cardSwipeRegionContains(cardSwipeRecognizer.location(in: contentView))
    }

    /// The page-drive swipe's territory: the HEADER BAND — everything above
    /// where the stream's content begins.
    ///
    /// It used to be the floating caption card. With the caption scrolling
    /// as a list row there is no non-scrolling card left to grab, and the
    /// band above the stream is the only cell territory a drag can start in
    /// without fighting the list: below this line a vertical drag scrolls
    /// the comments, which is exactly what it should do. Internal (not
    /// private) so the boundary stays unit-testable.
    func cardSwipeRegionContains(_ point: CGPoint) -> Bool {
        guard point.y >= 0 else { return false }
        return point.y <= SnapCommentsLayout.commentsTopInset(topInset: frozenInsets.top)
    }

    /// A vertical swipe on the glass card drives the feed pager
    /// INTERACTIVELY (same as the composer bar's page-swipe). The whole
    /// engaged layer — docked media card, glass, comments — lives inside
    /// THIS cell, so once the host hand-moves the pager's `contentOffset`
    /// the entire assembly rides the finger for free; the cell only
    /// forwards the pan's phase + raw translation/velocity. No self-nudge
    /// (that would double the motion), no commit-only settle.
    func handleCardSwipe(_ pan: UIPanGestureRecognizer) {
        guard isCommentsEngaged else { return }
        let dy = pan.translation(in: host).y
        let vy = pan.velocity(in: host).y
        switch pan.state {
        case .began:
            onRequestCommentsPageDrive?(.began, 0, 0)
        case .changed:
            onRequestCommentsPageDrive?(.changed, dy, vy)
        case .ended, .cancelled, .failed:
            onRequestCommentsPageDrive?(.ended, dy, vy)
        default:
            break
        }
    }
}

extension SnapFeedCell: SnapCommentsEngagementHost {}
