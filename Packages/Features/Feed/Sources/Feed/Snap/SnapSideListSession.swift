import CoreImage
import CoreModels
import CoreNavigation
import DesignSystem
import MediaPlayback
import PostGrid
import PostSurfaces
import ThreadKit
import UIKit

/// What the side list's session and the swipe chain ask of their screen
/// (#2514): the pager and its pages, the post on show and its cell, the
/// installed side list and the posts it samples, the sound's audible surface,
/// the open comments' composer, and the pager's scroll lock.
///
/// A view controller: its view is the space drags are measured in, its bars
/// are what the card fits between, and its stack takes the author's push.
@MainActor
protocol SnapSideListSessionHost: UIViewController {
    var collectionView: UICollectionView! { get }
    var orderedIDs: [PostID] { get }
    var modelsByID: [PostID: FeedItemDisplayModel] { get }
    var viewModel: FeedViewModel { get }
    var activePostID: PostID? { get }
    var activeSnapCell: SnapFeedCell? { get }
    /// The settled page's cell, whether or not its activation has run.
    var settledSnapCell: SnapFeedCell? { get }
    var settledPageIndex: Int { get }
    var isKeyboardOnScreen: Bool { get }
    /// The side list, when the screen installs one (`installsSideList`).
    var sideList: SnapSideListController? { get }
    /// The current posts the side list samples from.
    var sideListEntries: (@MainActor () async -> [FeedEntry])? { get }
    var soundPlayback: SnapSoundPlayback { get }
    var commentsContentVC: UIViewController? { get }
    func setContentScrollEnabled(_ enabled: Bool)
    func updateActiveItem()
}

/// The side list's session and the leftward swipe chain (#2514): which stage
/// a horizontal drag takes (the list, the author's push), the list's
/// candidates, the session the card pages through while the list is open
/// (#1509) and the list a reopening resumes (#1580), the ring, a tile picked
/// and the player handed over to the card (#1581), the stopped mark moving
/// between the card and the tile (#1550), the pulls that close the list, the
/// bars the card fits between and the pages' overlay offset.
///
/// The list itself — its view, its pose, its settle, its loading — is
/// `SnapSideListController`'s, which the screen installs and which asks the
/// screen for these.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN: every entry point runs in the caller's
/// turn, where the screen called it before — the arbiter's `shouldBegin`
/// (`swipeStage`), the pager's scroll (`updateSideListRing`), the list's pose
/// and settle callbacks, a page change. Only the candidates' fetch and the
/// view model's session begin wait, as they did.
@MainActor
final class SnapSideListSession {
    private unowned let host: any SnapSideListSessionHost
    private let videoPlayback: VideoPlaybackController?

    init(host: any SnapSideListSessionHost, videoPlayback: VideoPlaybackController?) {
        self.host = host
        self.videoPlayback = videoPlayback
    }

    /// The screen's side list, read where the moved code names it — its
    /// `if let sideList` bindings included.
    private var sideList: SnapSideListController? { host.sideList }

    /// How far the pages' overlays sit down while the side list is open
    /// (#1509): the band the bottom toolbar covers, in the page's space.
    private(set) var sideListOverlayOffset: CGFloat = 0
    /// The lists made so far, by the post they were opened from (#1509).
    var sideListCache: [PostID: [FeedEntry]] = [:]
    /// The post the side list was opened from, while it drives the card.
    var sideListAnchor: PostID?
    /// The post on show's clip, paused from its side-list tile (#1550);
    /// nil when none.
    var sideListPausedPost: PostID?
    /// The paused clip whose stopped mark the side list's move is carrying
    /// between the card and its tile (#1580); nil when no move carries one.
    var sideListMarkCarry: PostID?
    /// ⚠️ THE LIST IS THE SOURCE'S, NOT THE POST ON SHOW'S (#1580, the
    /// owner 2026-10-22): closed on a post picked in it, the list it was
    /// picked from — the source post's "similar" posts — stays the one a
    /// reopening shows, the card on that post, until the feed is taken up
    /// again (a page change after the close). Nil: the next opening makes
    /// the post on show's list.
    private(set) var sideListResume: (anchor: PostID, shown: PostID)?

    /// A page change (`updateActiveItem`).
    func activePostDidChange() {
        // A clip paused from its tile is left behind by a page change: the
        // mark goes with it (#1550).
        if let paused = sideListPausedPost, paused != host.activePostID {
            sideListPausedPost = nil
            sideList?.listView.setPausedMark(false, on: nil)
        }
    }

    /// The feed taken up again after a close (`scrollViewWillBeginDragging`).
    func forgetResume() {
        sideListResume = nil
    }

    /// Whether a leftward drag born at `origin` (in this view) may open the
    /// side list: nothing open over the page, nothing under the finger that
    /// owns its own drags (the rail, an open panel), and a carousel with no
    /// photo left to turn to — or a drag born in the trailing edge strip,
    /// which opens it from any photo.
    func sideListMayOpen(from origin: CGPoint) -> Bool {
        // ⚠️ THE COMMENTS LAYOUT TOO (#1728, the owner): the open thread no
        // longer blocks the chain — its list scrolls vertically, the chain is
        // horizontal, and its composer still keeps its drags (below).
        guard !host.collectionView.isDecelerating, !host.isKeyboardOnScreen, !host.orderedIDs.isEmpty else { return false }
        // ⚠️ THE EDGE FIRST (#1592, the owner): the trailing strip — and the
        // trailing column standing at it — win over everything under them.
        if isInTrailingEdge(origin) || isOnTrailingColumn(origin) { return true }
        let point = host.collectionView.convert(origin, from: host.view)
        if let hit = host.collectionView.hitTest(point, with: nil) {
            for current in sequence(first: hit, next: { $0.superview }) {
                if current is SnapShortcutRailView || current is SnapWheelGlassView || current is SnapRailBoostButton || current is CommentsInputBar {
                    return false
                }
            }
        }
        return MediaCarouselTouchRouting.dragPassesThroughCarousel(
            at: point, in: host.collectionView, towardsPageDelta: 1
        )
    }

    /// Whether `origin` (in this view) lies in the trailing edge strip.
    func isInTrailingEdge(_ origin: CGPoint) -> Bool {
        host.view.bounds.maxX - origin.x <= PagedScreenDismissalPolicy.trailingEdgeZone
    }

    /// ⚠️ THE TRAILING COLUMN IS THE EDGE (the owner, 2026-10-22): the emote
    /// rail, the like bubble and the sound bubble stand at the screen's edge,
    /// so a leftward drag born on one of them is a drag "from the right edge"
    /// — the author's profile. Nothing of theirs is lost: the rail scrolls on
    /// VERTICAL drags only (`SnapShortcutRailView.gestureRecognizerShouldBegin`)
    /// and the bubbles answer taps.
    func isOnTrailingColumn(_ origin: CGPoint) -> Bool {
        let point = host.collectionView.convert(origin, from: host.view)
        guard let hit = host.collectionView.hitTest(point, with: nil) else { return false }
        return sequence(first: hit, next: { $0.superview }).contains {
            $0 is SnapShortcutRailView || $0 is SnapWheelGlassView || $0 is SnapRailBoostButton
                || $0 is SnapSoundBubbleButton || $0 is SnapColumnSaveButton
        }
    }

    /// ⚠️ THE LEFTWARD SWIPE CHAIN (#1525, the owner 2026-10-21):
    /// - a **media** post, the list closed: the side list opens (the
    ///   carousel's own photos first — `sideListMayOpen`);
    /// - a **text** post: no list (media posts only, the owner) — the
    ///   author's profile is pushed, following the finger;
    /// - the list **open**: a leftward drag pushes the author of the post on
    ///   the CARD (the list's current item, not the anchor); a rightward one
    ///   closes the list;
    /// - from the **right edge** or the action column (#1592, the owner
    ///   2026-10-22): the author's profile at once, skipping the list — except
    ///   on a **carousel**, where it opens the list (#1720).
    func swipeStage(for direction: SwipeDirection, at origin: CGPoint) -> SwipeStage? {
        guard let sideList, !sideList.isSettling else { return nil }
        if sideList.isOpen {
            switch direction {
            case .rightward: return .panel(sideList)
            case .leftward:
                // Not from the list itself (its tiles scroll and tap).
                guard !sideList.listView.frame.contains(origin) else { return nil }
                return authorPushStage()
            }
        }
        guard direction == .leftward, sideListMayOpen(from: origin) else { return nil }
        let model = host.activePostID.flatMap { host.modelsByID[$0] }
        if isInTrailingEdge(origin) || isOnTrailingColumn(origin) {
            // ⚠️ A CAROUSEL'S EDGE OPENS THE LIST (#1720, the owner): its
            // middle pages through its photos, so the edge is the way to the
            // similar posts. Any other post's edge pushes the author.
            if let model, model.isCollection { return .panel(sideList) }
            return authorPushStage()
        }
        guard let model else { return nil }
        return model.mediaURL != nil ? .panel(sideList) : authorPushStage()
    }

    /// The push of the shown post's author — made now, so a screen with no
    /// router (or no author) answers no stage at all.
    private func authorPushStage() -> SwipeStage? {
        guard let author = host.activePostID.flatMap({ host.modelsByID[$0] })?.authorID,
              let profile = host.viewModel.authorProfileDestination(author) else { return nil }
        return .push { profile }
    }

    /// ⚠️ BACK FROM THE PROFILE, THE POST IS FULL SCREEN (#1525, the owner):
    /// a committed push closes the list behind the profile, without
    /// animation — the post on show stays the current page, placed after
    /// the anchor (#1509).
    func swipePushDidEnd(committed: Bool) {
        // The pager pages again — unless the list, still open after a
        // cancelled push, keeps it frozen as its own settle does.
        if !(sideList?.isEngaged ?? false) { host.setContentScrollEnabled(true) }
        guard committed, let sideList, sideList.isOpen || sideList.isEngaged else { return }
        sideList.settle(open: false, animated: false)
    }

    /// The pager holds still under the finger's push.
    func swipePushWillBegin() {
        host.setContentScrollEnabled(false)
    }

    /// ⚠️ THE POST ON SHOW, THEN SIMILAR POSTS (#1509): the list is
    /// `[the post on show] + current posts of the feed's kind (#1421), none
    /// already in the feed, in a random order` — the "similar" half behind
    /// one seam (`sideListEntries`), so posts sharing a hashtag replace it as
    /// a data change. One list per anchor, kept while the screen lives: the
    /// same post opens on the same list.
    func sideListCandidates() async -> [FeedEntry] {
        guard let anchor = host.activePostID else { return [] }
        if let cached = sideListCache[anchor] { return cached }
        async let similar = host.sideListEntries?() ?? []
        async let shown = host.viewModel.entry(for: anchor)
        let (entries, anchorEntry) = await (similar, shown)
        let inFeed = Set(host.orderedIDs)
        let kind: SnapFeedKindScope? = host.modelsByID[anchor].map { $0.mediaURL == nil ? .text : .media }
        var seen: Set<PostID> = [anchor]
        let others = entries.filter { entry in
            guard !inFeed.contains(entry.post.id), seen.insert(entry.post.id).inserted else { return false }
            return kind == nil || SnapFeedKindScope(entry) == kind
        }.shuffled()
        let list = (anchorEntry.map { [$0] } ?? []) + others
        sideListCache[anchor] = list
        return list
    }

    /// Whether the side list drives the card now (#1509).
    var isSideListSessionActive: Bool { host.viewModel.isInSideListSession }

    /// The list is open and loaded: the card pages through it (#1509) — the
    /// feed set aside untouched, the pager on the post on show, the list's
    /// first item.
    func beginSideListSessionIfNeeded() {
        guard let sideList, sideList.isOpen, !host.viewModel.isInSideListSession, let shown = host.activePostID else { return }
        let entries = sideList.listView.entries
        // Reopened on a post picked in the last list: that list again, the
        // card on the post at its place in it (#1580).
        let resumed = sideListResume.flatMap { resume in
            resume.shown == shown && entries.first?.post.id == resume.anchor
                && entries.contains(where: { $0.post.id == shown }) ? resume.anchor : nil
        }
        guard let anchor = resumed ?? (entries.first?.post.id == shown ? shown : nil) else { return }
        Task { [weak self] in
            guard let self, await host.viewModel.beginSideListSession(anchor: anchor, entries: entries) else { return }
            sideListAnchor = anchor
            settlePager(onIndex: host.orderedIDs.firstIndex(of: shown) ?? 0)
        }
    }

    /// One context for every still: making one per call is costly.
    private static let stillContext = CIContext(options: [.useSoftwareRenderer: false])

    /// The frame `surface` is drawing now, as an image (#1581).
    private static func stillImage(of surface: VideoRenderView) -> UIImage? {
        guard let buffer = surface.currentFrameBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cg = stillContext.createCGImage(image, from: image.extent) else {
            return nil
        }
        return UIImage(cgImage: cg)
    }

    /// The surface `id`'s page draws its clip on, while that page is the
    /// post on show (#1581: the side list's tile mirrors it).
    func liveVideoSurface(for id: PostID) -> VideoRenderView? {
        guard host.activePostID == id else { return nil }
        return host.settledSnapCell?.liveVideoSurface
    }

    /// The list closed, unseen, as the screen leaves (`viewDidDisappear`).
    func closeSideListForDismissal() {
        if let sideList, sideList.isEngaged || sideList.isOpen {
            sideList.settle(open: false, animated: false)
        }
        sideListResume = nil
    }

    /// The source post whose list a reopening keeps, while it holds
    /// (`sideListResume`).
    var sideListResumeAnchor: PostID? {
        guard let resume = sideListResume, resume.shown == host.activePostID else { return nil }
        return resume.anchor
    }

    /// The pager on page `index`, at once, and the page made active.
    func settlePager(onIndex index: Int) {
        let page = host.collectionView.bounds.height
        guard page > 0, host.orderedIDs.indices.contains(index) else { return }
        UIView.performWithoutAnimation {
            host.collectionView.setContentOffset(CGPoint(x: 0, y: CGFloat(index) * page), animated: false)
            host.collectionView.layoutIfNeeded()
        }
        host.updateActiveItem()
    }

    /// The list closed (#1509): the feed comes back as it was. The post on
    /// show STAYS full screen — placed right after the anchor, so a swipe up
    /// continues the feed from there — however the list closed: rightward,
    /// or pulled past either end (#1580).
    private func endSideListSession() {
        guard host.viewModel.isInSideListSession, let anchor = sideListAnchor else { return }
        sideListAnchor = nil
        sideListResume = host.activePostID.map { (anchor, $0) }
        guard let index = host.viewModel.endSideListSession(anchor: anchor, keeping: host.activePostID) else { return }
        settlePager(onIndex: index)
    }

    /// ⚠️ THE RING FOLLOWS THE CARD'S SCROLL (#1546, the owner 2026-10-21):
    /// between two posts, the two tiles' rings share the way — half each
    /// half way — so the ring fades across under the finger and back on a
    /// cancelled swipe. A jump with no finger (a tile's tap) fades it.
    func updateSideListRing(_ scrollView: UIScrollView) {
        guard let sideList, sideList.isOpen, host.viewModel.isInSideListSession else { return }
        let page = scrollView.bounds.height
        guard page > 0, !host.orderedIDs.isEmpty else { return }
        let position = min(max(scrollView.contentOffset.y / page, 0), CGFloat(host.orderedIDs.count - 1))
        let lower = Int(position.rounded(.down))
        let fraction = position - CGFloat(lower)
        var weights: [PostID: CGFloat] = [:]
        if host.orderedIDs.indices.contains(lower) { weights[host.orderedIDs[lower]] = 1 - fraction }
        if fraction > 0, host.orderedIDs.indices.contains(lower + 1) {
            weights[host.orderedIDs[lower + 1], default: 0] += fraction
        }
        let byFinger = scrollView.isTracking || scrollView.isDecelerating
        sideList.listView.setRing(weights, animated: !byFinger)
    }

    /// A post picked in the list: the card moves to it — the list's own
    /// item, nothing injected into the feed (#1509).
    ///
    /// ⚠️ AT ONCE (#1548, the owner 2026-10-21): no scroll through the posts
    /// in between, the card shows the chosen one in the next frame. The
    /// pager stays in the list's order, so a swipe from there reaches its
    /// real neighbours.
    func showSideListEntry(_ entry: FeedEntry) {
        // ⚠️ THE POST ON SHOW'S OWN TILE PAUSES IT (#1550): while the list
        // is open, the card closes the list on a tap, so the clip is paused
        // and resumed from its tile, which wears the stopped mark.
        if entry.post.id == host.activePostID {
            toggleSideListPlayback()
            return
        }
        guard host.viewModel.isInSideListSession,
              let index = host.orderedIDs.firstIndex(of: entry.post.id) else { return }
        // ⚠️ THE CARD TAKES THE TILE'S OWN PLAYER (#1581, the owner's
        // recording): started fresh, even at the tile's second, the card and
        // the tile both showed the post's cover until a first frame — the
        // flash on every pick. The tile's player is handed over instead, on
        // the frame it is showing: the card draws it at once (bound
        // alongside, then adopted, filed under the post's own scope, its cap
        // raised to a page's), and the tile goes on drawing it as the
        // card's mirror. A tile with no player of its own falls back to a
        // start at its second.
        let id = entry.post.id
        let handoff = sideList?.listView.tilePlayhead(for: id)
        let tileSurface = sideList?.listView.autoplay?.handOver(id)
        if tileSurface == nil, let handoff {
            videoPlayback?.prepareStart(of: handoff.url, scope: id.rawValue, at: handoff.seconds)
        }
        settlePager(onIndex: index)
        guard let videoPlayback, let card = liveVideoSurface(for: id) else { return }
        // The frame the tile is showing, as the card's poster until its own
        // layer draws (a frame or so): never the post's cover.
        if let tileSurface, let still = Self.stillImage(of: tileSurface) { card.setPoster(still) }
        if let tileSurface, card !== tileSurface,
           videoPlayback.attachSurface(card, alongsideSurface: tileSurface),
           videoPlayback.adoptSurface(card, replacing: tileSurface) {
            videoPlayback.rescope(card, to: id.rawValue)
            videoPlayback.setPeakBitRate(MediaPlaybackPolicy.peakBitRate, in: card)
            card.revealOnFirstFrame()
            host.soundPlayback.refreshAudibleSurface()
            sideList?.listView.reconcileNow()
        } else if let handoff, videoPlayback.hasPlayer(in: card) {
            videoPlayback.seek(toSeconds: handoff.seconds, in: card, toleranceSeconds: 0)
        }
    }

    /// Toggles the post on show's clip from the list: the stopped mark on
    /// its tile, none on the card.
    private func toggleSideListPlayback() {
        guard let id = host.activePostID, let cell = host.activeSnapCell, cell.canTogglePlayback,
              let paused = cell.togglePlayback(markOnPage: false) else { return }
        sideListPausedPost = paused ? id : nil
        sideList?.listView.setPausedMark(paused, on: id)
    }

    /// ⚠️ THE MARK CROSSES WITH THE MOVE (#1580, the owner 2026-10-22): a
    /// paused clip's stopped mark leaves the card for its tile as the list
    /// opens — 1 − progress on the card, progress on the tile — under the
    /// finger and on the spring, both ways, rather than jumping at the end.
    /// `handOverPausedMark` settles who keeps it.
    func sideListPoseDidChange(progress: CGFloat) {
        guard let id = host.activePostID, let cell = host.settledSnapCell, let list = sideList?.listView else { return }
        if sideListMarkCarry != id {
            // Nothing paused, nothing to carry.
            guard cell.showsPausedMark || sideListPausedPost == id else { return }
            sideListMarkCarry = id
            cell.setPausedMarkVisible(true, animated: false)
            list.setPausedMark(true, on: id, animated: false)
        }
        cell.setPausedMarkShare(1 - progress)
        list.setPausedMarkShare(progress)
    }

    /// The stopped mark moves between the card and the tile as the list
    /// opens and closes (#1550); paging to another post takes it down.
    private func handOverPausedMark(listOpen: Bool) {
        guard let id = host.activePostID, let cell = host.settledSnapCell else { return }
        // A move carried it: the side it ended on keeps it, whole, the
        // other lets it go unseen — it is at 0 already.
        if sideListMarkCarry == id {
            sideListMarkCarry = nil
            if listOpen {
                cell.setPausedMarkVisible(false, animated: false)
                sideListPausedPost = id
                sideList?.listView.setPausedMarkShare(1)
            } else {
                cell.setPausedMarkShare(1)
                sideListPausedPost = nil
                sideList?.listView.setPausedMark(false, on: nil, animated: false)
            }
            return
        }
        sideListMarkCarry = nil
        if listOpen {
            if cell.showsPausedMark {
                cell.setPausedMarkVisible(false)
                sideListPausedPost = id
            }
            sideList?.listView.setPausedMark(sideListPausedPost == id, on: id)
        } else {
            if sideListPausedPost == id { cell.setPausedMarkVisible(true) }
            sideListPausedPost = nil
            sideList?.listView.setPausedMark(false, on: nil)
        }
    }

    /// The pulls that close the side list now (#1580): with the list open
    /// and still, down on its first post, up on its last — where the card
    /// sits at that end of the pager, with nothing beyond it.
    var sideListEdgePulls: SnapSideListEdgePull.Directions {
        guard let sideList, sideList.isOpen, !sideList.isSettling, host.viewModel.isInSideListSession,
              let pager = host.collectionView, !host.orderedIDs.isEmpty else { return [] }
        let page = pager.bounds.height
        guard page > 0 else { return [] }
        let index = host.settledPageIndex
        // At rest on its page, not mid-scroll.
        guard abs(pager.contentOffset.y - CGFloat(index) * page) < 0.5 else { return [] }
        var pulls: SnapSideListEdgePull.Directions = []
        if index == 0 { pulls.insert(.down) }
        if index == host.orderedIDs.count - 1 { pulls.insert(.up) }
        return pulls
    }

    /// What the bars cover, for the side list's card to fit between them
    /// (#1509): the top bar's bottom and the bottom toolbar's top, read off
    /// the bars themselves when they are on screen, the safe area otherwise.
    var sideListBars: UIEdgeInsets {
        var top = host.view.safeAreaInsets.top
        var bottom = host.view.safeAreaInsets.bottom
        if let nav = host.navigationController {
            let bar = nav.navigationBar
            if !nav.isNavigationBarHidden, bar.window != nil, !bar.isHidden {
                top = max(top, bar.convert(bar.bounds, to: host.view).maxY)
            }
            let toolbar = nav.toolbar!
            if !nav.isToolbarHidden, toolbar.window != nil, !toolbar.isHidden {
                bottom = max(bottom, host.view.bounds.maxY - toolbar.convert(toolbar.bounds, to: host.view).minY)
            }
        }
        return UIEdgeInsets(top: max(0, top), left: 0, bottom: max(0, bottom), right: 0)
    }

    /// Moves every page's overlay down by `offset` (the side list's pose).
    func setSideListOverlayOffset(_ offset: CGFloat) {
        sideListOverlayOffset = offset
        for case let cell as SnapFeedCell in host.collectionView.visibleCells {
            cell.setSideListOverlayOffset(offset)
        }
        // …and the open comments' composer with them (#1730).
        (host.commentsContentVC as? PostDetailViewController)?.setOverlayOffset(offset)
    }

    /// The list settled open or closed. Open, the pager pages back from its
    /// first post too — the dismissal stands aside (`downwardDragOwner`).
    func sideListDidSettle(open: Bool) {
        handOverPausedMark(listOpen: open)
        if open {
            beginSideListSessionIfNeeded()
        } else {
            endSideListSession()
        }
        sideList?.activePostDidChange(host.activePostID)
    }
}
