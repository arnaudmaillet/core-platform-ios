import CoreModels
import Foundation

/// The full-screen feed's flight flags (#2387): the eight transition-scoped
/// facts a flight raises on the screen — a zoom present, a text reveal, a
/// departure, an engaged grab — and what derives from them.
///
/// ⚠️ THE SCREEN IS REUSED (`FeedFlowCoordinator` keeps one controller), so
/// every flag is re-stated on every present or lowered at every landing, by
/// the screen, exactly where it always was: a value left up by the last visit
/// is the reused-feed defect (`arrivalFacts`).
///
/// A value, with no side effect of its own: the screen's `flight` property
/// keeps the landing's — the deferred comments panel mounting when
/// `isAwaitingZoomPresentation` goes down — in its `didSet`, on the same write.
struct SnapFlightPhase {
    /// The clip time a presenting flight's picture showed, for the entry page
    /// (#625) — see `zoomTransitionWillStartMedia(at:)`. A nil post is the
    /// entry page of a feed that had no posts yet when the flight took off.
    var flightMediaStart: (postID: PostID?, seconds: TimeInterval)?
    /// True between `zoomTransitionWillBegin` and `zoomTransitionDidEnd`. Cells
    /// realized inside that window inherit the playback deferral, so a page
    /// activating mid-flight cannot steal the render slot from the flying card.
    ///
    /// Going down — the flight is over, one way or another — a text page that
    /// stood on its placeholder gets its real panel (charter PR 5b): the
    /// screen's `flight.didSet`.
    var isAwaitingZoomPresentation = false
    /// A text reveal is about to push this screen. The reveal is a navigation
    /// push with its own animator, not a zoom presentation, so it never
    /// reaches `zoomTransitionWillBegin` / `zoomTransitionDidEnd`: the
    /// installer raises this before the push and `viewDidAppear` — the push's
    /// landing — lowers it.
    var isAwaitingRevealPresentation = false
    /// Set by `zoomTransitionWillDepart`, read once by `zoomTransitionDidEnd`:
    /// the ending flight takes this screen off screen.
    var isDepartingWithFlight = false
    /// Whether the card staging that presentation is flying THIS page's player
    /// — the source's own answer, handed over by the transition controller.
    ///
    /// Defaults to the conservative reading and is RE-STATED on every present,
    /// for the reason `zoomOwnsInteractiveDismissal` below is: the controller
    /// is reused, so a leftover `false` from a map flight would silently unarm
    /// the deferral for the next flight from a grid — where it is load-bearing.
    var flightCarriesActivePlayer = true
    /// Set by whoever pushes this screen: true when a flight attached a grab to
    /// it, false when it arrived by an ordinary push and the native edge swipe
    /// should work. Written on BOTH paths rather than defaulted, because the
    /// controller is REUSED and a stale answer from the previous presentation
    /// is exactly the bug this would otherwise become.
    var zoomOwnsInteractiveDismissal = true
    /// A dismissing grab is moving the live page (`setZoomDismissState`): the
    /// floors stay clear and the page stays visible until it is put back.
    var isEngagedDismissalActive = false
    /// The inert page-chrome replica riding in the hero transition's flying
    /// card. Held weakly for the duration of a flight so a post that hydrates
    /// mid-flight (cold tap) can still fill in the replica's labels; the card
    /// owns the view itself.
    weak var flightChrome: SnapChromeView?

    /// True while any flight — zoom or reveal — has the screen on its way.
    var isAwaitingAnyFlight: Bool {
        isAwaitingZoomPresentation || isAwaitingRevealPresentation
    }

    /// The two facts whose AND is the deferral. Read at all three stamping
    /// sites, so a page realized mid-flight cannot disagree with the one the
    /// flight staged over.
    ///
    /// ⚠️ A MAP FLIGHT DOES NOT DEFER, and the question "could the page start
    /// sooner so the video is up earlier in the window" is CLOSED. Measured on
    /// a present from a marker, `-zoom-live-log -media-log`, times relative to
    /// the flight beginning:
    ///
    ///     +0 ms    willBegin flyingPlayer=N defers=N
    ///     +68 ms   [page-play] start
    ///     +230 ms  retry ADOPTED mid-flight — the first decoded frame
    ///     +703 ms  landed
    ///
    /// A marker carries no player, so this reads false and the page starts as
    /// early as there is a page to start. The 162 ms between the start and the
    /// first frame is a remote asset decoding, not a policy, and the fade
    /// begins in the same tick the frame exists.
    ///
    /// The only two ways to make that frame earlier are both refused: warming a
    /// player for every visible marker would put an `AVPlayer` behind a 44pt
    /// pin, spend pool loans the pool is already tight on and decode during
    /// pan — the map's own invariant forbids the first and
    /// `prewarmVisiblePosts` deliberately warms POSTS, not players; and a cheap
    /// preview rendition is the standing contract ask
    /// (`dev/issues/BACKEND_MEDIA_PREVIEW_RENDITIONS.md`). Until that ships the
    /// card is not empty for those 162 ms: it flies the marker's sprite sheet,
    /// animating, at the page's own framing.
    var defersPlaybackForStagingFlight: Bool {
        isAwaitingZoomPresentation && flightCarriesActivePlayer
    }
}
