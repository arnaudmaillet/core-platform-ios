import ThreadKit
import UIKit

/// What the feed's paging asks of its panel (#2523): the composer, whose
/// pan pages the feed, and the cut of the streams to their room.
///
/// A view controller: the page's VoiceOver actions sit on its view.
@MainActor
protocol PostDetailFeedPagingHost: UIViewController {
    var composeBar: CommentsInputBar { get }
    func cutStreamsToRoom()
}

extension PostDetailViewController {
    // MARK: - The pull to the next / previous post (#2298 § 2)

    /// What the feed gives the page's pull (#2298 § 2): where a pull that way
    /// goes — the post's author, nil for nowhere (the feed's last post, the
    /// first post's top, which keeps its close) — and the page change itself.
    struct PostPull {
        /// The post a pull that way would go to; nil for no pill.
        var target: (PostPullDirection) -> PostPullTarget?
        /// The feed's own page change to that post, from where the page
        /// stands now, at `velocity` (pt/s, the finger's), then `completion`
        /// once it has settled (or did not go).
        var commit: (_ direction: PostPullDirection, _ velocity: CGFloat, _ completion: @escaping () -> Void) -> Void
    }
}

/// The feed's paging from a page's panel, out of `PostDetailViewController`
/// (#2523): the composer's interactive page swipe, the pull past the
/// streams' ends to the next or previous post (#2298 § 2), and the page's
/// VoiceOver actions.
@MainActor
final class PostDetailFeedPaging {
    private unowned let host: any PostDetailFeedPagingHost

    init(host: any PostDetailFeedPagingHost) {
        self.host = host
    }

    /// Wires the composer's INTERACTIVE page-swipe — the bar forwards each
    /// pan phase (began/changed/ended) with the raw vertical translation and
    /// velocity, and the host drives the feed pager's `contentOffset` in
    /// real time (finger-linked paging), settling on release.
    ///
    /// `pagesBack` answers, as a downward drag begins on a stream its room
    /// holds whole (#2298 § 1), whether it goes to the previous post — the
    /// feed's router, so the first post keeps its close there.
    func setEngagedPageSwipeHandler(
        _ handler: @escaping (CommentsInputBar.PageSwipePhase, CGFloat, CGFloat) -> Void,
        pagesBack: @escaping () -> Bool
    ) {
        host.composeBar.onPageSwipe = handler
        pagesBackFromStreamTop = pagesBack
        // A page in a vertical feed: its streams read in its room (#2298).
        // One that fits pages with the feed's swipe; one that scrolls goes on
        // with the pull past its ends (`setPostPull`).
        host.cutStreamsToRoom()
    }
    /// Whether a downward drag on a stream that fits goes to the previous
    /// post. Nil outside a vertical feed.
    private(set) var pagesBackFromStreamTop: (() -> Bool)?

    /// The feed's side of the pull; nil outside a vertical feed (the comments
    /// sheet has no pull, #2298 § 5).
    private(set) var postPull: PostDetailViewController.PostPull?

    /// Wires the pull past the streams' ends to the feed, and the page's
    /// VoiceOver actions with it: "Next post", "Previous post" — no pull
    /// needed.
    func setPostPull(_ pull: PostDetailViewController.PostPull) {
        postPull = pull
        host.loadViewIfNeeded()
        host.view.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Next post") { [weak self] _ in self?.goToPost(.next) ?? false },
            UIAccessibilityCustomAction(name: "Previous post") { [weak self] _ in self?.goToPost(.previous) ?? false },
        ]
    }

    /// Where a pull that way would go now: nil with the keyboard up, or with
    /// nowhere to go.
    func postPullTarget(_ direction: PostPullDirection) -> PostPullTarget? {
        guard let postPull, !host.composeBar.isKeyboardOpen else { return nil }
        return postPull.target(direction)
    }

    /// The page's VoiceOver action: the post that way, as a committed pull
    /// would go to it. False (VoiceOver says so) when there is none.
    @discardableResult
    func goToPost(_ direction: PostPullDirection) -> Bool {
        guard let postPull, postPull.target(direction) != nil else { return false }
        postPull.commit(direction, 0) {}
        return true
    }
}

extension PostDetailViewController: PostDetailFeedPagingHost {}
