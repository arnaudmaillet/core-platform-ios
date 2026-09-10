import CoreModels
import DesignSystem
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

/// The For You pager: three format pages (Activity / Media / Short) in one
/// horizontally paging scroll view. Each format owns a fixed layout, so
/// swiping between pages IS the layout transition.
///
/// The nesting works because the axes never compete: this scroll view pages
/// horizontally only (its content height equals its frame height), and each
/// page scrolls vertically only (its content width equals the frame's), so
/// UIKit's standard pan arbitration routes each drag to exactly one of them.
///
/// Unlike the profile gallery's pager, this one does NOT sync its height to
/// the active page: every page is viewport-height and scrolls on its own.
final class ForYouPagerView: UIView {
    /// Pager order == selector order == the tabs the screen actually has.
    ///
    /// **Two tabs, and the media grid leads.** `GalleryFilter.Format` still has
    /// three cases because the profile gallery uses all of them; For You simply
    /// does not give each one a tab. `.short` (text-only posts) has no tab of
    /// its own here — those posts still appear, under Following, which is the
    /// unfiltered page.
    ///
    /// The titles the viewer reads are `ForYouViewController`'s, and they do not
    /// echo the enum: `.media` is "Discover" and `.activity` is "Following".
    /// The enum names the CONTENT SHAPE (what is in the page), the titles name
    /// the PRODUCT IDEA (why you would go there), and those were never the same
    /// question.
    static let pageOrder: [GalleryFilter.Format] = [.media, .activity]

    /// The tapped post's index into the *given format page's* posts.
    var onItemTapped: ((GalleryFilter.Format, Int) -> Void)?

    /// The same open, at the post's comments — see
    /// `ForYouGridPage.onItemCommentsTapped`.
    var onItemCommentsTapped: ((GalleryFilter.Format, Int) -> Void)?

    /// What is on screen and worth warming — see `ForYouGridPage.onWarmRequested`.
    var onWarmRequested: (([GalleryPost]) -> Void)?
    /// A row's author was tapped, on whichever page is showing.
    var onAuthorTapped: ((GalleryPost) -> Void)?
    /// What a row's "..." offers — see `ForYouGridPage.authorMenuActions`.
    var authorMenuActions: ((ForYouGridPage.AuthorMenuContext) -> [PostCardMenuAction])?
    /// Fired when a page becomes active: a settled finger swipe or a finished
    /// programmatic page. Not fired when the page is unchanged.
    var onPageSettled: ((GalleryFilter.Format) -> Void)?
    /// Fractional page position (e.g. `1.42` — 42% of the way from Gallery to
    /// Short), emitted on every scroll tick, drag or animation.
    ///
    /// This is what lets the top tab capsule's lens track the finger instead of
    /// snapping at the end of a swipe, and it is why the pager is a plain
    /// paging scroll view rather than a `UIPageViewController` — the latter
    /// exposes no continuous position at all.
    var onProgress: ((CGFloat) -> Void)?

    /// The active page's scroll view, whenever it changes.
    ///
    /// ⚠️ **NOT `self.scrollView`, WHICH IS HORIZONTAL.** Handing the pager's
    /// own scroller to `setContentScrollView(_:for: .bottom)` is a SILENT
    /// no-op: it pages sideways and `alwaysBounceVertical` is false, so the
    /// tab bar simply never minimizes and nothing logs or errors.
    ///
    /// ⚠️ AND NOT FROM `onProgress`. That fires every frame of a horizontal
    /// swipe — during which the finger is horizontal, so nothing could
    /// minimize anyway — and would hand UIKit a different scroller, at a
    /// different offset, while a touch is down. The interval it would cover
    /// ends at `settle()`, which is the instant the page is committed.
    var onActiveScrollViewChanged: ((UIScrollView) -> Void)?
    var onNearEnd: (() -> Void)?
    var onRefresh: (() -> Void)?

    /// DesignSystem's yielding pager scroll view, not a bare `UIScrollView`.
    ///
    /// It gives horizontal drags up to two things: the leading-edge pop strip,
    /// and any horizontally scrollable content under the touch. The second is
    /// what lets a post card's media carousel be swiped at all — without it this
    /// pager took every drag and the tab changed instead.
    ///
    /// Shared with `HorizontalPagerView` rather than reimplemented, because the
    /// first version of that fix went into the other pager and did nothing here.
    private let scrollView = HorizontalPagerScrollView()
    private let pages: [ForYouGridPage]
    private var activeIndex = 0
    /// The last index handed to `onPageSettled`. Tracked separately from
    /// `activeIndex` because a tab tap sets the TARGET immediately and only
    /// arrives a beat later — comparing the landing against `activeIndex`
    /// alone would make every tap-driven page change look like a no-op.
    private var reportedIndex = 0

    /// The posts a page is showing — what a tile tap seeds from.
    func posts(for format: GalleryFilter.Format) -> [GalleryPost] {
        page(for: format)?.posts ?? []
    }

    /// The page itself, for a hero source that needs its geometry.
    func page(for format: GalleryFilter.Format) -> ForYouGridPage? {
        guard let index = Self.pageOrder.firstIndex(of: format) else { return nil }
        return pages[index]
    }

    init(imagePipeline: ImagePipeline, videoPlayback: VideoPlaybackController? = nil) {
        pages = Self.pageOrder.map { format in
            ForYouGridPage(
                imagePipeline: imagePipeline,
                style: format == .media ? .grid : .list,
                videoPlayback: videoPlayback
            )
        }
        super.init(frame: .zero)

        scrollView.isPagingEnabled = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = self
        scrollView.pin(to: self)

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        var leading = content.leadingAnchor
        for (index, page) in pages.enumerated() {
            scrollView.addSubview(page)
            page.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                page.topAnchor.constraint(equalTo: content.topAnchor),
                page.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                page.leadingAnchor.constraint(equalTo: leading),
                page.widthAnchor.constraint(equalTo: frame.widthAnchor)
            ])
            leading = page.trailingAnchor
            let format = Self.pageOrder[index]
            page.onItemTapped = { [weak self] item in self?.onItemTapped?(format, item) }
            page.onItemCommentsTapped = { [weak self] item in
                self?.onItemCommentsTapped?(format, item)
            }
            page.onWarmRequested = { [weak self] posts in self?.onWarmRequested?(posts) }
            page.onRefresh = { [weak self] in self?.onRefresh?() }
            page.onAuthorTapped = { [weak self] post in self?.onAuthorTapped?(post) }
            page.authorMenuActions = { [weak self] context in
                self?.authorMenuActions?(context) ?? []
            }
            // Only the page the user is actually reading may drive pagination:
            // the other two are laid out and would otherwise fire on their own
            // resting offsets while off-screen.
            page.onNearEnd = { [weak self] in
                guard let self, Self.pageOrder[activeIndex] == format else { return }
                onNearEnd?()
            }
        }
        NSLayoutConstraint.activate([
            leading.constraint(equalTo: content.trailingAnchor),
            content.heightAnchor.constraint(equalTo: frame.heightAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ snapshot: ForYouViewModel.Snapshot) {
        for (index, format) in Self.pageOrder.enumerated() {
            pages[index].render(snapshot.state(for: format))
        }
    }

    /// The next snapshot is a re-derived corpus, not an extended one — told to
    /// BOTH pages, because a lens applies across the surface.
    func invalidateIncrementalUpdates() {
        pages.forEach { $0.invalidateIncrementalUpdates() }
    }

    /// Which of a page's posts arrived since the session baseline — the rows it
    /// puts a "New" header above.
    func setNewPosts(_ ids: Set<PostID>, for format: GalleryFilter.Format) {
        page(for: format)?.setNewPosts(ids)
    }

    /// Settles a tapped item clear of the chrome while the post covers this
    /// screen. Asked of every page; only the one holding a pending reveal acts.
    func applyPendingReveal() {
        pages.forEach { $0.applyPendingReveal() }
    }

    /// Hands every page what floats over its foot — see
    /// `ForYouGridPage.footChromeCover`.
    func setFootChromeCover(_ cover: CGFloat) {
        pages.forEach { $0.footChromeCover = cover }
    }

    func endRefreshing() {
        pages.forEach { $0.endRefreshing() }
    }

    /// Puts back everything a transition hid, on every page.
    ///
    /// Asked of all three rather than of the active one: a lens can be switched
    /// while a post is open, so the page that was flown from is not necessarily
    /// the page being read on the way back.
    func clearFlightConcealments() {
        pages.forEach {
            $0.clearRevealConcealment()
            $0.clearHeroConcealment()
        }
    }

    /// Only the page being read shows the footer spinner. The other two are
    /// laid out off-screen and would otherwise reserve a band nobody can see.
    func setPaging(_ paging: Bool) {
        for (index, page) in pages.enumerated() {
            page.setPaging(paging && index == activeIndex)
        }
    }

    /// Tab tap → smooth page. The scroll animation reports progress every
    /// frame, so a tap drives the capsule's lens through exactly the same path
    /// a finger does — a tap from Activity to Short visibly carries the lens
    /// *through* Gallery.
    func setActivePage(_ format: GalleryFilter.Format, animated: Bool) {
        guard let index = Self.pageOrder.firstIndex(of: format), index != activeIndex else { return }
        activeIndex = index
        guard bounds.width > 0 else {
            // No layout yet, so there is no offset to move and nothing to
            // report — but the two indices must not be left disagreeing.
            //
            // `viewDidLoad` restores the persisted format through here, before
            // first layout. Landing on Activity used to move `activeIndex` to 1
            // and leave `reportedIndex` at 0, and from then on a swipe BACK to
            // Gallery settled on 0, matched `reportedIndex`, and was dismissed
            // as "no change": `activeIndex` stayed 1, so `syncAutoplay` kept
            // the page the viewer was looking at switched off and it never
            // autoplayed, and `onPageSettled` never corrected the view model's
            // format. It healed only on a tab tap or a round trip. Restoring
            // Gallery — the default — could not reproduce it, because there
            // the guard above returns first and neither index moves.
            reportedIndex = index
            publishActiveScrollView()
            return
        }
        publishActiveScrollView()
        scrollView.setContentOffset(CGPoint(x: offsetX(for: index), y: 0), animated: animated)
        syncAutoplay()
        if !animated {
            onProgress?(CGFloat(index))
            settle()
        }
    }

    // MARK: - Driven by the capsule's own drag

    /// Drives the pager from something other than its own pan — the tab
    /// capsule's selection pill, which can be picked up and dragged like the
    /// pages themselves. Unanimated by design: this is called per frame of a
    /// finger.
    ///
    /// Lives here rather than in the caller so the index↔offset conversion (and
    /// with it the RTL mirroring) stays in one place; a caller writing
    /// `contentOffset` itself would be right in English and wrong in Arabic.
    func scrub(to progress: CGFloat) {
        guard bounds.width > 0, pages.count > 1 else { return }
        let clamped = min(max(progress, 0), CGFloat(pages.count - 1))
        let slot = isRTL ? CGFloat(pages.count - 1) - clamped : clamped
        scrollView.setContentOffset(CGPoint(x: slot * bounds.width, y: 0), animated: false)
    }

    /// Ends a scrub on a whole page, carrying the fling through: a flick that
    /// barely moved still lands on the next page, the same way the pager's own
    /// pan behaves.
    ///
    /// ⚠️ A scrub never decelerates — the offset was assigned, frame by frame —
    /// so nothing else will land these pages. `settle()` still runs, from the
    /// end of the animation this starts.
    func settleAfterScrub(velocityInPages: CGFloat) {
        guard bounds.width > 0, pages.count > 1 else { return }
        // Half a page of "throw" per unit velocity — enough that a flick
        // commits, small enough that a slow drag released mid-way falls back to
        // whichever page it is actually nearest.
        let projected = progress + velocityInPages * 0.5
        let landing = min(max(Int(projected.rounded()), 0), pages.count - 1)
        activeIndex = landing
        syncAutoplay()
        publishActiveScrollView()
        // Always travel, even when the landing is the page it started on: that
        // case is a scrub that did not commit, and it still has to come back
        // from wherever the finger left it. It is also the case
        // `setActivePage` cannot serve — it returns early on an unchanged
        // index, which is exactly the state this arrives in.
        //
        // ⚠️ **UNLESS THERE IS NOTHING TO TRAVEL, and then the landing is
        // announced HERE.** A drag released past the last tab clamps to an
        // offset the pages are already sitting on, and an animated scroll of
        // zero distance is not something to hang a callback on — `onPageSettled` is
        // what five of the six hosts commit their model from, so a release that
        // silently skipped it would leave the screen on one tab and its view
        // model on another.
        let target = offsetX(for: landing)
        guard abs(scrollView.contentOffset.x - target) > 0.5 else { return settle() }
        scrollView.setContentOffset(CGPoint(x: target, y: 0), animated: true)
    }

    // MARK: - Autoplay

    /// Whether this surface may autoplay at all — tab frontmost, nothing
    /// presented over it, app foregrounded. ANDed with per-page activity below.
    private var isSurfaceActive = false
    /// Exempt from the stop sweep: the post whose player a flight is carrying.
    private var flightPostID: PostID?

    func setAutoplayActive(_ active: Bool, keeping kept: PostID? = nil) {
        isSurfaceActive = active
        flightPostID = kept
        syncAutoplay()
    }

    func beginPlaybackHandoff(of postID: PostID) {
        pages.forEach { $0.beginPlaybackHandoff(of: postID) }
    }

    /// Closes the handoff on every page and reconciles. One call, one restored
    /// grid — no per-tile bookkeeping survives a flight.
    func endPlaybackHandoff() {
        pages.forEach { $0.endPlaybackHandoff() }
    }

    /// Retires a handoff nobody adopted. The pool parks at most one player, so
    /// asking any page is asking the pool — no need to know which one parked it.
    func discardPlaybackHandoff() {
        pages.forEach { $0.discardPlaybackHandoff() }
    }

    /// Only the page the viewer is actually on plays. The pager keeps all three
    /// laid out, so without this the off-screen formats would hold pool slots
    /// for video nobody can see.
    private func syncAutoplay() {
        for (index, page) in pages.enumerated() {
            page.setAutoplayActive(isSurfaceActive && index == activeIndex, keeping: flightPostID)
        }
    }

    /// The scroll view last handed out, so an unchanged page publishes nothing.
    private var publishedScrollView: UIScrollView?

    /// Says which scroll view is live, at the four moments a page is COMMITTED.
    private func publishActiveScrollView() {
        guard pages.indices.contains(activeIndex) else { return }
        let scroller = pages[activeIndex].minimizeScrollView
        guard scroller !== publishedScrollView else { return }
        publishedScrollView = scroller
        onActiveScrollViewChanged?(scroller)
    }

    private var lastLayoutWidth: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the offset page-aligned through width changes (first layout,
        // rotation) — offsets are in points, not page indices.
        guard bounds.width != lastLayoutWidth, bounds.width > 0 else { return }
        lastLayoutWidth = bounds.width
        scrollView.contentOffset = CGPoint(x: offsetX(for: activeIndex), y: 0)
        publishActiveScrollView()
        onProgress?(CGFloat(activeIndex))
    }

    // MARK: - Index ↔ offset

    /// Right-to-left languages lay the pages out mirrored (the constraints use
    /// leading/trailing), but `contentOffset.x` still counts from the left
    /// edge. Every conversion goes through these, so the rest of the pager —
    /// and the tab capsule above it — can think in logical page indices only.
    private var isRTL: Bool { effectiveUserInterfaceLayoutDirection == .rightToLeft }

    private func offsetX(for index: Int) -> CGFloat {
        let slot = isRTL ? pages.count - 1 - index : index
        return CGFloat(slot) * bounds.width
    }

    /// The fractional *logical* page position for the current offset.
    private var progress: CGFloat {
        guard bounds.width > 0 else { return CGFloat(activeIndex) }
        let slot = scrollView.contentOffset.x / bounds.width
        let clamped = min(max(slot, 0), CGFloat(pages.count - 1))
        return isRTL ? CGFloat(pages.count - 1) - clamped : clamped
    }
}

// MARK: - UIScrollViewDelegate

extension ForYouPagerView: UIScrollViewDelegate {
    // The pages own their own delegate (`ForYouGridPage`), so nothing vertical
    // reaches any of these — only the horizontal pager reports here.

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard bounds.width > 0 else { return }
        onProgress?(progress)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        settle()
    }

    /// A drag released without enough velocity to decelerate still lands on a
    /// page; without this the capsule would keep the old selection.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settle() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        settle()
    }

    private func settle() {
        guard bounds.width > 0 else { return }
        let landed = Int(progress.rounded())
        guard pages.indices.contains(landed), landed != reportedIndex else { return }
        activeIndex = landed
        reportedIndex = landed
        publishActiveScrollView()
        syncAutoplay()
        onPageSettled?(Self.pageOrder[landed])
    }
}
