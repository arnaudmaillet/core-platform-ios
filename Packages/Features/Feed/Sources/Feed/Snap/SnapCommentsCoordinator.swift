import CoreModels
import CoreNavigation
import DesignSystem
import LaunchArguments
import MediaCore
import PostGrid
import PostSurfaces
import ThreadKit
import UIKit

/// What the full-screen feed's comments ask of their screen (#2387): the
/// pages and their models, the flight, the pager and its lock, the chrome
/// the engagement swaps, and the panels' factories.
///
/// A view controller: the panels are its children, and the sheet is
/// presented from it.
@MainActor
protocol SnapCommentsCoordinatorHost: UIViewController {
    var collectionView: UICollectionView! { get }
    var orderedIDs: [PostID] { get }
    var modelsByID: [PostID: FeedItemDisplayModel] { get }
    var activePostID: PostID? { get }
    var settledPageIndex: Int { get }
    var lifecycle: SnapLifecycleDispatcher { get }
    var flight: SnapFlightPhase { get }
    /// The screen is on screen (appeared, not yet gone).
    var isOnScreen: Bool { get }
    /// The post a card asked to open on its comments (`openComments`).
    var pendingCommentsID: PostID? { get }
    var pagerDrive: SnapPagerDrive { get }
    /// The one owner of the pager's `isScrollEnabled`.
    var pagerScrollLock: SnapPagerScrollLock { get }
    /// `SnapVerticalDragRouter`'s owner of a downward drag beginning now.
    var downwardDragOwner: SnapVerticalDragRouter.DownwardOwner { get }
    /// The theme the device is in, not the one the screen is pinned to.
    var deviceInterfaceStyle: UIUserInterfaceStyle { get }
    var makeCommentsPanelContent: ((PostID) -> UIViewController)? { get }
    var makeRestingCommentsPanelContent: ((PostID) -> UIViewController)? { get }
    var makeWalletSheet: (@MainActor () -> UIViewController)? { get }
    var walletBadgeItem: UIBarButtonItem? { get }
    var defaultToolbarItems: [UIBarButtonItem] { get }
    /// Whether the bar wears the engagement's chrome.
    var engagedChromeOnBar: Bool { get set }
    var commentTabs: CommentTabsSelector { get }
    var imagePipeline: ImagePipeline { get }
    var followStore: SnapAuthorFollowStore { get }
    var viewModel: FeedViewModel { get }
    func pageIndexPath(for id: PostID) -> IndexPath?
    func isTextPage(_ id: PostID?) -> Bool
    func markPostUnavailable(_ id: PostID, recording: Bool)
    func applyRailSlot(to panel: UIViewController?, hostedByPage: Bool)
    func bindCaptionAuthor(of content: UIViewController?, for id: PostID)
    func observeCommentCount(of detail: PostDetailViewController?)
    func observeCommentsDay(of detail: PostDetailViewController?)
    func syncCommentsDay()
    func syncCommentSortAvailability()
    func setEngagedChrome(_ engaged: Bool, hasMedia: Bool, animated: Bool)
    func refreshWalletBadge()
    func reapplyEngagedInsets()
    func applyGrounds()
}

/// The full-screen feed's comments (#2387): a text page's resting panel
/// (built ahead, previewed while another page holds the engagement, mounted,
/// locked at the settle, released when its page has gone), the warms of both
/// kinds of panel, the loading page that stands in before the corpus, and
/// the launch of a media post's sheet.
///
/// ⚠️ SYNCHRONOUS WITH ITS SCREEN. Every entry point runs in the caller's
/// turn, and the screen calls them where it always did: the settle's
/// reconcile, the cell's display, the flight's landing, the render. What
/// waits — the staged warm, the idle warm, a landing's mount — waits on its
/// own, as it did.
@MainActor
final class SnapCommentsCoordinator {
    private unowned let host: any SnapCommentsCoordinatorHost

    /// The arrival screen's own LOADING state, drawn while the corpus is in
    /// flight — a SUBVIEW, never a ground.
    ///
    /// A feed pushed before its posts arrive has no cells, so the window used
    /// to open onto whatever colour the floors were. `emptyGround` made that
    /// colour the tapped card's; this puts the screen it is opening onto on top
    /// of it, in the state it is actually in. Filmed as ~930ms of empty grey on
    /// the FIRST selection of a pin and none on the second, because the first is
    /// what fills the cache the synchronous seed reads.
    ///
    /// ⚠️ IT IS THE REAL PANEL, not a drawing of one. Built from the same
    /// factory the resting page uses and handed to the cell when the post lands,
    /// so what the viewer watches load is the thing that finishes loading —
    /// and so nothing here can invent an author or a caption, because a PostID
    /// is the only thing it is given.
    private var loadingPageID: PostID?
    private(set) var loadingPage: UIViewController?
    private(set) var loadingPageFrost: ProgressiveFrostView?
    /// Parked in the prewarm slot, awaiting a cell's adoption.
    private var handedOverLoadingPage: UIViewController?
    /// Set on a COMPLETED disappearance: the builder's seed Task is never
    /// cancelled, so a render can still land on a screen that has gone.
    private var loadingPageDisarmed = false

    /// The page whose panel is waiting for the flight to land.
    private var deferredResting: (id: PostID, cell: SnapFeedCell, placeholder: RestingCommentsPlaceholderView)?

    private(set) var commentsEngagedID: PostID?
    /// A media post's comments, a native sheet, while one is up (#2087): the
    /// engagement above is a text page's and stays nil meanwhile.
    private(set) var commentsSheet: SnapCommentsSheetSession?
    /// The active page's sheet panel, built ahead of the tap on the settle
    /// seam — the page's own warm, outside the page (#2087).
    private var commentsSheetWarm: (id: PostID, panel: UIViewController)?
    /// The page whose sheet warm is on its way, over the turns after its
    /// settle (`stageCommentsSheetWarm`).
    private var stagedCommentsWarm: PostID?
    /// The engaged comments UI — a child of THIS controller (thread data,
    /// scroll position, and reply drafts must never live in a recycled
    /// cell); the cell only hosts its view while engaged.
    private(set) var commentsContentVC: UIViewController?
    /// Whether the active engagement is a text page's RESTING interface —
    /// PRE-RENDERED on visibility (as the cell scrolls in, fully formed,
    /// no reveal spring), then LOCKED at settle. The two phases are split
    /// so the interface slides in complete while the incoming scroll is
    /// never aborted (the pager lock can only land once the page has
    /// settled — disabling it mid-drag would freeze the user's scroll).
    private(set) var commentsEngagementIsResting = false
    /// `scheduleIdleCommentsWarm`. Held so leaving can call it off.
    private var idleCommentsWarm: DispatchWorkItem?
    /// The RESTING panels built ahead for text pages — see
    /// `prewarmRestingComments`. Deliberately not the engagement slot. The
    /// window around the settled page (#2059): the next page's, the previous
    /// one's, and the page being landed on until it mounts its own — three,
    /// or keeping the page just left pushed out the page arriving.
    let restingWarm = SnapWarmSlots<PostID, UIViewController>(capacity: 3)
    /// The panel of a page that is scrolling IN while another still owns the
    /// engagement — see `previewRestingComments`.
    private(set) var previewRestingID: PostID?
    private(set) var previewRestingVC: UIViewController?
    private weak var previewRestingCell: SnapFeedCell?
    /// engaged toolbar context) has been applied — set when the page
    /// activates, so a pre-render that never settles never locks.
    private var restingLockApplied = false

    init(host: any SnapCommentsCoordinatorHost) {
        self.host = host
    }

    // MARK: - Comments engagement

    /// A post's comments, asked for (a comment surface, a card's count, a
    /// push): a media post's open in the sheet (#2087); a text post's ARE
    /// its page, mounted at its settle (the resting path), so there is
    /// nothing to open.
    func presentComments(for id: PostID, animated: Bool = true) {
        guard host.modelsByID[id]?.mediaURL != nil else { return }
        presentCommentsSheet(for: id, animated: animated)
    }

    /// The comments in a native sheet over the bottom of the screen, the
    /// page's media shrunk into the room above it —
    /// `SnapCommentsSheetSession`. Today's panel, built as the page's is; the
    /// pager and the sector hold still while it is up.
    private func presentCommentsSheet(for id: PostID, animated: Bool) {
        // ⚠️ A REOPENING DURING THE CLOSE TURNS AROUND (#2287 § 4): the sheet
        // gone, the media still on its way back, the session that closed it
        // hands the media over where it stands rather than snapping it home.
        let landingSheet = commentsSheet.flatMap { $0.postID == id && $0.isLandingAfterSheet ? $0 : nil }
        guard commentsSheet == nil || landingSheet != nil, commentsEngagedID == nil, host.presentedViewController == nil,
              host.view.window != nil, host.modelsByID[id]?.mediaURL != nil,
              let indexPath = host.pageIndexPath(for: id),
              let cell = host.collectionView.cellForItem(at: indexPath) as? SnapFeedCell,
              let content = takeCommentsSheetWarm(for: id) ?? host.makeCommentsPanelContent?(id)
        else { return }
        let handover = landingSheet?.handOverLanding()
        let detail = content as? PostDetailViewController
        // The panel learns here that its post turned out unavailable (#1409),
        // as `applyRailSlot` tells the page's.
        detail?.onPostUnavailable = { [weak self] id in self?.host.markPostUnavailable(id, recording: true) }
        if let detail {
            SnapCommentsSheetViewController.prepare(detail, commentCount: host.modelsByID[id]?.cardMetrics?.comments)
        }
        // ⚠️ AFTER THE HANDOVER: a turned-around session ends inside
        // `handOverLanding`, and its end releases the sheet's hold — taken
        // before, this session's hold would go with it.
        host.pagerScrollLock.hold(.sheet)
        // The balance moves to the sheet's bar (the page's leaves with its
        // bar): a badge of its own, kept current with the page's.
        let sheetBadge = host.walletBadgeItem != nil ? WalletBadgeButton() : nil
        let makeWalletSheet = host.makeWalletSheet
        let session = SnapCommentsSheetSession(
            postID: id, panel: content, cell: cell, feed: host,
            walletBadge: sheetBadge,
            onWalletTap: makeWalletSheet.map { make in { [weak self] in
                guard let sheet = self?.commentsSheet?.sheet, sheet.presentedViewController == nil else { return }
                sheet.present(make(), animated: true)
            } }
        ) { [weak self] in
            guard let self else { return }
            commentsSheet = nil
            host.pagerScrollLock.release(.sheet)
            // Reopening is as cheap as opening — warmed once the screen is
            // still, never in the close's own turn: ~100 ms of panel build
            // there held the first frames of whatever the finger did next
            // (#2116).
            scheduleIdleCommentsWarm()
        }
        commentsSheet = session
        host.refreshWalletBadge()
        session.present(animated: animated, handover: handover)
    }

    /// Builds the sheet's panel for `id` before the tap: loading its view asks
    /// for its first comments (`PostDetailViewController.viewDidLoad`), so the
    /// sheet rises on rows, not bones — the page's own warm, without the page.
    func prewarmCommentsSheet(for id: PostID) {
        guard needsCommentsSheetWarm(id), let content = host.makeCommentsPanelContent?(id) else { return }
        loadCommentsSheetWarm(content, for: id)
    }

    private func needsCommentsSheetWarm(_ id: PostID) -> Bool {
        commentsSheet == nil && commentsSheetWarm?.id != id && host.modelsByID[id]?.mediaURL != nil
    }

    private func loadCommentsSheetWarm(_ content: UIViewController, for id: PostID) {
        // ⚠️ THE WARM IS WHERE THE PAGE LEARNS ITS POST HAS GONE (#1409):
        // loading the panel revalidates the post, and a page whose post
        // turned unavailable blocks its like, boost and sound from here —
        // not only once the sheet opens.
        (content as? PostDetailViewController)?.onPostUnavailable = { [weak self] id in
            self?.host.markPostUnavailable(id, recording: true)
        }
        content.loadViewIfNeeded()
        commentsSheetWarm = (id, content)
    }

    /// `prewarmCommentsSheet`, in two turns after the current one's commit:
    /// the panel's construction in the first, its view (the first comments,
    /// their layout) in the second (#2136).
    ///
    /// ⚠️ NOT IN THE SETTLE'S OWN TURN. The settle runs in the scroll's last
    /// deceleration frame, and the whole warm there (~30 ms of CPU: a 39–46
    /// ms turn on the simulator, `-O`) held whatever the finger did next — a
    /// tap, the next swipe. Spread out, the settle's turn is 3–9 ms, the
    /// construction 6–9 ms, the view 22–31 ms. Each step re-asks: the same page, still active, no
    /// sheet open, the screen still; a step that finds the screen moving
    /// hands over to the idle warm, which waits for quiet. A tap on the
    /// comments before the second step builds the sheet then, as it would
    /// without a warm.
    private func stageCommentsSheetWarm(for id: PostID) {
        guard needsCommentsSheetWarm(id), stagedCommentsWarm != id else { return }
        stagedCommentsWarm = id
        RunLoopTurn.afterCommit { [weak self] in
            guard let self, mayTakeStagedWarmStep(id) else { return }
            guard let content = host.makeCommentsPanelContent?(id) else {
                stagedCommentsWarm = nil
                return
            }
            RunLoopTurn.afterCommit { [weak self] in
                guard let self, mayTakeStagedWarmStep(id) else { return }
                stagedCommentsWarm = nil
                loadCommentsSheetWarm(content, for: id)
            }
        }
    }

    /// Whether the staged warm of `id` may take its next step; called off
    /// when the page moved on, the sheet opened or the screen is moving.
    private func mayTakeStagedWarmStep(_ id: PostID) -> Bool {
        guard stagedCommentsWarm == id else { return false }
        guard host.activePostID == id, needsCommentsSheetWarm(id) else {
            stagedCommentsWarm = nil
            return false
        }
        guard isQuietForCommentsWarm else {
            stagedCommentsWarm = nil
            scheduleIdleCommentsWarm()
            return false
        }
        return true
    }

    /// The warm panel, if it is `id`'s; spent by the taking.
    private func takeCommentsSheetWarm(for id: PostID) -> UIViewController? {
        defer { commentsSheetWarm = nil }
        return commentsSheetWarm?.id == id ? commentsSheetWarm?.panel : nil
    }

    /// The TEXT page's resting engagement, PHASE 1 (visual pre-render):
    /// mounts the whole interface — glass card, collapsed slot, frost,
    /// hosted stream, composer onstage — INSTANTLY and on VISIBILITY (the
    /// cell's `willDisplay`, as it scrolls in), so a text page enters the
    /// viewport 100% pre-assembled with zero reveal animation. Two things
    /// the modal `presentComments` does are DEFERRED to settle (phase 2,
    /// `lockRestingEngagement`): the pager freeze (disabling it here would
    /// abort the very scroll bringing the cell in) and the engaged toolbar
    /// swap (nav chrome follows the SETTLED page, not a half-scrolled one).
    /// Idempotent by the slot guard; media pages never take this path.
    /// A text page's interface, built BEFORE its cell exists.
    ///
    /// ⚠️ THE COST IS THE BUILD, NOT THE DATA. The stream is already warm by
    /// the time a page scrolls in (see `warmContent`), and the page still
    /// arrived as a black rectangle that filled itself in a beat later —
    /// because what a text page IS is this panel, and it was constructed at
    /// `willDisplay`, which is the same moment the black is on screen. Roughly
    /// 100ms of layout, spent exactly when nothing can absorb it.
    ///
    /// ⚠️ HELD IN ITS OWN FIELD, and that is not tidiness. The engagement slot
    /// (`commentsContentVC`) is what `presentRestingComments` guards on: a warm
    /// parked there makes the mount decline, and the page then arrives blank
    /// for good rather than late. That exact mistake is on the record; this
    /// holds the built panel to one side and hands it over at the mount.
    ///
    /// Never during a flight, for the reason `prewarmComments` gives: this is
    /// layout, and a hero's frame budget is not where it should be paid.
    /// ⚠️ AND IT DOES NOT WAIT FOR THE ENGAGEMENT SLOT TO BE FREE, which the
    /// first version of this did and which made it never run.
    ///
    /// Guarding on `commentsEngagedID`/`commentsContentVC` was copied from the
    /// MOUNT, where those fields mean "something is already installed in a
    /// cell". Building means nothing of the sort: this constructs into its own
    /// field and touches neither. Their two most common values are exactly the
    /// cases that matter — the current page is a text page and is holding the
    /// slot with its own resting panel, or the current media page has had its
    /// tap-to-comments panel warmed into it — so the guard declined precisely
    /// when the next page needed building, and the black rectangle came back
    /// unchanged.
    func prewarmRestingComments(for id: PostID) {
        guard !host.flight.isAwaitingAnyFlight,
              !restingWarm.contains(id),
              host.isTextPage(id),
              let makeCommentsPanelContent = host.makeCommentsPanelContent else { return }
        let content = (host.makeRestingCommentsPanelContent ?? makeCommentsPanelContent)(id)
        host.applyRailSlot(to: content, hostedByPage: true)
        // Bound before its first layout: a page built ahead wears its
        // author's mark from its first frame (#2300).
        host.bindCaptionAuthor(of: content, for: id)
        content.view.backgroundColor = .clear
        // ⚠️ IN THE DEVICE'S THEME, not `.unspecified`.
        //
        // This view controller has no parent yet, so `.unspecified` resolves
        // against nothing and it is laid out and rendered in whatever UIKit
        // defaults to — then it is mounted into a cell and changes theme in
        // front of the viewer. The whole point of building ahead is that
        // nothing about the page changes when it arrives.
        content.overrideUserInterfaceStyle = host.deviceInterfaceStyle
        // Laid out at the size it will be mounted at, so the mount is a
        // re-parent rather than a first layout. A view built and never measured
        // saves nothing.
        content.view.frame = host.view.bounds
        content.view.layoutIfNeeded()
        restingWarm.insert(content, for: id)
        #if DEBUG
        debugPrewarmedRestingID = id
        #endif
    }
    /// One at a time: the pager moves on and the page two ahead is not worth a
    /// second view controller's memory.
    /// The exit: a HANDOVER when there is a text page to hand it to, a fade
    /// otherwise.
    ///
    /// ⚠️ KEYED ON ANY RENDER, not on the first one carrying items. `.empty`
    /// and `.failed` both render with zero items, so "wait for content" would
    /// leave this sitting over the status label for ever.
    func retireLoadingPage() {
        guard let panel = loadingPage else { return }
        let head = host.orderedIDs.first
        let handsOver = head != nil && head == loadingPageID
            && host.isTextPage(head)
            && commentsEngagedID == nil && commentsContentVC == nil
            && restingWarm.isEmpty
        loadingPage = nil
        loadingPageID = nil
        guard handsOver, let head else { return fadeOutLoadingPage(panel, animated: true) }
        // ⚠️ THE VIEW STAYS WHERE IT IS. Only the child relationship drops;
        // the cell re-parents the SAME view in the SAME layout pass, so there
        // is never a frame of neither — which is the whole point of building
        // the real panel rather than a picture of one.
        panel.willMove(toParent: nil)
        panel.removeFromParent()
        panel.view.isUserInteractionEnabled = true
        loadingPageFrost?.removeFromSuperview()
        loadingPageFrost = nil
        restingWarm.insert(panel, for: head)
        handedOverLoadingPage = panel
        #if DEBUG
        debugPrewarmedRestingID = head
        if LaunchArgument.mediaLog.isPassed() {
            print(String(format: "[media] %.3f loading-page retire handover=yes",
                         CACurrentMediaTime()))
        }
        #endif
    }

    /// The belt. The apply's completion does not guarantee realized cells, so
    /// force the pass and check whether anything actually adopted the panel —
    /// an unadopted one sits on `view` as a lid over the feed.
    func finishLoadingPageHandover() {
        guard let panel = handedOverLoadingPage else { return }
        host.collectionView.layoutIfNeeded()
        handedOverLoadingPage = nil
        guard panel.view.superview === host.view else { return }
        restingWarm.remove(panel)
        #if DEBUG
        if LaunchArgument.mediaLog.isPassed() {
            print(String(format: "[media] %.3f loading-page adopted=no — faded",
                         CACurrentMediaTime()))
        }
        #endif
        fadeOutLoadingPage(panel, animated: true)
    }

    /// 0.15s — this file's length for late content.
    private func fadeOutLoadingPage(_ panel: UIViewController, animated: Bool) {
        let frost = loadingPageFrost
        loadingPageFrost = nil
        let strip = {
            panel.willMove(toParent: nil)
            panel.view.removeFromSuperview()
            panel.removeFromParent()
            frost?.removeFromSuperview()
        }
        guard animated, host.view.window != nil else { return strip() }
        UIView.animate(withDuration: 0.15, animations: {
            panel.view.alpha = 0
            frost?.alpha = 0
        }, completion: { _ in strip() })
    }
    /// The stand-in, for the flight's duration (charter PR 5b).
    func installRestingPlaceholder(for id: PostID, model: FeedItemDisplayModel, host cell: SnapFeedCell) {
        if let current = deferredResting {
            cell.removeRestingPlaceholder(current.placeholder)
        }
        let placeholder = RestingCommentsPlaceholderView(
            model: model, imagePipeline: host.imagePipeline, safeAreaTop: host.view.safeAreaInsets.top,
            // What the warm already holds flies in as real rows (#2002).
            heldComments: host.viewModel.heldTopComments(for: id),
            // The caption's face wears what the panel's will (#2300).
            authorMark: host.followStore.badge(for: model.authorID)
        )
        cell.installRestingPlaceholder(placeholder)
        deferredResting = (id, cell, placeholder)
        #if DEBUG
        print("[defer-resting] placeholder installed for \(id.rawValue) bounds=\(placeholder.bounds) container=\(placeholder.superview?.frame ?? .zero) hidden=\(placeholder.superview?.isHidden ?? true) alpha=\(placeholder.superview?.alpha ?? -1)")
        #endif
    }

    /// The flight has landed. A card opened ON its comments needs its panel
    /// in this very turn, before the pending comments are applied, so it
    /// finds it exactly as it would have without the deferral. Every other
    /// landing lets the landing frame commit first and mounts on the next
    /// turn: measured, the mount is ~160 ms (debug sim), and spent inside the
    /// landing frame it would hold the animation's last frame back.
    func landDeferredRestingComments() {
        guard let deferred = deferredResting else { return }
        #if DEBUG
        print("[defer-resting] landing \(deferred.id.rawValue) pending=\(host.pendingCommentsID?.rawValue ?? "none")")
        #endif
        if host.pendingCommentsID != nil {
            mountDeferredRestingComments()
        } else {
            DispatchQueue.main.async { [weak self] in self?.mountDeferredRestingComments() }
        }
    }

    /// The real panel goes in over the stand-in, on the same pixels, and the
    /// stand-in fades.
    private func mountDeferredRestingComments() {
        guard let deferred = deferredResting else { return }
        deferredResting = nil
        guard deferred.cell.window != nil, host.orderedIDs.contains(deferred.id) else {
            #if DEBUG
            print("[defer-resting] mount skipped: window=\(deferred.cell.window != nil) known=\(host.orderedIDs.contains(deferred.id))")
            #endif
            deferred.cell.removeRestingPlaceholder(deferred.placeholder)
            return
        }
        // `installRestingPanel` takes the placeholder down as it mounts; the
        // removal below covers the paths that mount nothing (the preview
        // branch, a slot already held).
        deferredResting = deferred
        presentRestingComments(for: deferred.id, host: deferred.cell)
        #if DEBUG
        print("[defer-resting] mounted engaged=\(commentsEngagedID?.rawValue ?? "none") content=\(commentsContentVC != nil) preview=\(previewRestingID?.rawValue ?? "none")")
        #endif
        deferredResting = nil
        deferred.cell.removeRestingPlaceholder(deferred.placeholder, animated: false)
    }

    func presentRestingComments(for id: PostID, host cell: SnapFeedCell) {
        // ⚠️ A PARKED WARM IS NOT AN ENGAGEMENT, and treating it as one is the
        // black page.
        //
        // The guard below reads `commentsContentVC` as "a panel is installed in
        // a cell". A media page's tap-to-comments WARM sits in that same field
        // with no engagement behind it — so scrolling from a warmed media page
        // onto a text page found the slot taken, declined the mount, and the
        // text page scrolled in as a black rectangle. It then appeared all at
        // once at the settle, where the resign leg discards the warm and the
        // activate leg mounts for real. Measured exactly that way on a
        // recording: black for the whole scroll, complete the instant it
        // stopped.
        //
        // The warm belongs to the page being LEFT and is worth nothing now.
        guard commentsEngagedID == nil, commentsContentVC == nil else {
            // ⚠️ THE SLOT IS HELD BY ANOTHER PAGE'S ENGAGEMENT — text onto
            // text, where the page being left is still on screen and still
            // needs its panel. The incoming page gets a PREVIEW instead: the
            // same panel in the same place, without the engagement's
            // bookkeeping. The settle promotes it once the slot frees.
            previewRestingComments(for: id, host: cell)
            return
        }
        guard let content = restingPanel(for: id) else { return }
        commentsEngagedID = id
        commentsContentVC = content
        commentsEngagementIsResting = true
        restingLockApplied = false
        installRestingPanel(content, for: id, host: cell)
    }

    /// The incoming page's panel, mounted while another page still owns the
    /// engagement.
    ///
    /// ⚠️ EVERYTHING THE VIEWER SEES, NONE OF WHAT THE VIEWER DRIVES.
    ///
    /// The engagement is one slot on purpose: it carries the pager lock, the
    /// composer's ownership and the toolbar's context, and two of those at once
    /// is a contradiction. What is NOT single is the picture — a text page IS
    /// its panel, so a page scrolling in has to show one or it is a black
    /// rectangle until the scroll stops. That is the reported defect for text
    /// onto text, where the page being left still needs its own.
    ///
    /// So the panel is mounted into the incoming cell with no claim on the
    /// slot, and the settle promotes it the moment the page being left
    /// resigns. The promotion is a field assignment: nothing is built twice.
    private func previewRestingComments(for id: PostID, host cell: SnapFeedCell) {
        guard previewRestingID != id, commentsEngagedID != id,
              let content = restingPanel(for: id) else { return }
        discardRestingPreview()
        previewRestingID = id
        previewRestingVC = content
        previewRestingCell = cell
        installRestingPanel(content, for: id, host: cell)
    }

    /// Hands the engagement to a panel that is already on screen. False when
    /// there is nothing to promote, so the caller mounts for real.
    @discardableResult
    func promoteRestingPreview(for id: PostID) -> Bool {
        guard previewRestingID == id, let content = previewRestingVC,
              commentsEngagedID == nil, commentsContentVC == nil else { return false }
        previewRestingID = nil
        previewRestingVC = nil
        previewRestingCell = nil
        commentsEngagedID = id
        commentsContentVC = content
        commentsEngagementIsResting = true
        restingLockApplied = false
        // Its day was not heard while it was a preview.
        host.syncCommentsDay()
        // Nor was its keyboard: a preview's ceiling is off, and a promotion
        // that comes after the settle (the page being left lets go of the
        // slot when its last pixel goes) has no reconcile behind it (#969).
        syncComposerKeyboardCeilings(activeID: host.activePostID)
        return true
    }

    /// The composer's keyboard ceiling (`setComposerTracksKeyboard`) on every
    /// panel the feed holds: ON for the engagement of the page being read, off
    /// for everything else — a preview, a warm parked with no engagement, an
    /// engagement on a page that is not the settled one.
    ///
    /// ⚠️ CALLED WHEREVER THE ENGAGEMENT CHANGES HANDS, not only at the settle
    /// (#969). The reconcile turns a media page's parked warm OFF (it holds
    /// the slot with no engagement behind it), and the tap that then engages
    /// that very panel settles nothing: the composer stayed put under the
    /// keyboard on every show until the viewer next changed page. The first
    /// engagement after a swipe was the broken one; a tap that outran the
    /// warm, or a reopen (a fresh warm), rose — which is why it was
    /// "sometimes".
    private func syncComposerKeyboardCeilings(activeID: PostID?) {
        let engagedIsRead = commentsEngagedID != nil && commentsEngagedID == activeID
        (commentsContentVC as? PostDetailViewController)?.setComposerTracksKeyboard(engagedIsRead)
        (previewRestingVC as? PostDetailViewController)?.setComposerTracksKeyboard(false)
    }

    private func discardRestingPreview() {
        if let content = previewRestingVC {
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
            previewRestingCell?.setCommentsEngaged(false)
            previewRestingCell?.clearComments()
            if let id = previewRestingID { keepAsNeighbourWarm(content, for: id) }
        }
        previewRestingVC = nil
        previewRestingID = nil
        previewRestingCell = nil
    }

    /// ⚠️ A NEIGHBOUR'S PANEL IS KEPT, NOT THROWN AWAY (#2059): the feed
    /// pages back (#2056), so a text page next to the settled one — the page
    /// just left, a preview that scrolled away — keeps its resting panel,
    /// built and laid out, as that page's warm. Its stream stays where the
    /// reader left it. A page further away lets it go.
    private func keepAsNeighbourWarm(_ content: UIViewController, for id: PostID) {
        guard id != host.activePostID, let index = host.orderedIDs.firstIndex(of: id),
              abs(index - host.settledPageIndex) == 1 else { return }
        restingWarm.insert(content, for: id)
    }

    /// The panel for a post: the one built ahead when it matches, a fresh one
    /// otherwise.
    private func restingPanel(for id: PostID) -> UIViewController? {
        if let warmed = restingWarm.take(id) { return warmed }
        let panel = (host.makeRestingCommentsPanelContent ?? host.makeCommentsPanelContent)?(id)
        host.applyRailSlot(to: panel, hostedByPage: true)
        return panel
    }

    /// Everything a resting panel needs once it has a cell — identical whether
    /// it is the engagement or a preview, because what the VIEWER gets must not
    /// depend on which of the two it is.
    private func installRestingPanel(
        _ content: UIViewController, for id: PostID, host cell: SnapFeedCell
    ) {
        // Whatever path mounts the real panel, a placeholder standing on this
        // cell goes NOW, not on a fade: the panel draws the same caption and
        // either real rows or its own bones, and bones showing through under
        // real rows is exactly what a cross-fade produced on a device.
        let replacesStandIn = deferredResting?.cell === cell
        if let deferred = deferredResting, deferred.cell === cell {
            deferredResting = nil
            cell.removeRestingPlaceholder(deferred.placeholder, animated: false)
        }
        content.view.backgroundColor = .clear
        // Inherited, exactly like the media panel — the cell decides.
        content.overrideUserInterfaceStyle = .unspecified
        // The caption's author face, one more face of the binding (#2300).
        host.bindCaptionAuthor(of: content, for: id)
        host.addChild(content)
        cell.installComments(content.view)
        content.didMove(toParent: host)
        let detail = content as? PostDetailViewController
        detail?.setEngagedInsets(
            top: cell.engagedCommentsTopInset(safeAreaTop: host.view.safeAreaInsets.top),
            bottomInset: host.view.safeAreaInsets.bottom
        )
        // The caption the FEED already has, so the row exists while the hero
        // is in the air rather than arriving with the post fetch.
        let seededVoice = VoicePosts.areDrawn ? host.modelsByID[id]?.voice : nil
        // A showcase's card travels too (#2216): its page opens on it, with
        // no comments.
        let seededEmbed = PostEmbeds.shown(host.modelsByID[id]?.embed)
        let carriesMore = seededVoice != nil || seededEmbed != nil
        if let model = host.modelsByID[id], let caption = model.caption ?? (carriesMore ? "" : nil),
           !caption.isEmpty || carriesMore {
            // The AUTHOR travels with the caption: the row is an avatar beside
            // a bubble for every post now, and this path — the text page's
            // resting interface — is the one that mounts before any fetch, so
            // without it the disc would sit empty for the whole reveal.
            detail?.seedCaption(
                caption,
                timestamp: model.timestampText,
                authorName: model.authorName,
                monogram: CommentsInputBar.monogram(model.authorName),
                avatarURL: model.avatarURL,
                metrics: model.cardMetrics
                    ?? PostCardMetrics(reactions: model.likeCount, comments: nil),
                voice: seededVoice,
                embed: seededEmbed
            )
        }
        // The count the feed knows: no comment bones for a post with none.
        detail?.seedCommentCount(host.modelsByID[id]?.cardMetrics?.comments)
        // No close handler — a resting page is undismissable; the swipe
        // handler pages the feed (the only way off a text post).
        detail?.setEngagedPageSwipeHandler({ [weak self] phase, translation, velocity in
            self?.host.pagerDrive.drivePageSwipe(phase, translation: translation, velocity: velocity)
        }, pagesBack: { [weak self] in self?.host.downwardDragOwner == .pager })
        // The pull past the stream's ends (#2298 § 2), and the page's
        // VoiceOver actions: the feed's own page change, from this page.
        detail?.setPostPull(PostDetailViewController.PostPull(
            target: { [weak self] direction in self?.host.pagerDrive.postPullTarget(direction, from: id) },
            commit: { [weak self] direction, velocity, completion in
                guard let self else { return completion() }
                host.pagerDrive.commitPostPull(direction, from: id, velocity: velocity, completion: completion)
            }
        ))
        host.observeCommentCount(of: detail)
        host.observeCommentsDay(of: detail)
        // INSTANT: composer already onstage, cell engaged synchronously —
        // no spring, no offstage→onstage slide. The interface simply IS,
        // frame one, so scrolling it into view reveals it already formed.
        detail?.setComposerEntranceState(offstage: false)
        // ⚠️ AT THE MOUNT TOO, not only at the next settle.
        //
        // The reconcile derives this, but it runs when a page SETTLES — and the
        // composer is on screen, and wrong, for the whole scroll before that.
        // The rule is the same in both places: the ceiling belongs to the page
        // being read, and a page mounting while another is settled is not it.
        detail?.setComposerTracksKeyboard(id == host.activePostID)
        cell.setCommentsEngaged(true)
        cell.contentView.layoutIfNeeded()
        // The stand-in's bones went at once (above); comments that were
        // already loaded then arrive on the panel's own reveal rather than
        // being there in the same frame the bones vanished.
        if replacesStandIn { detail?.revealVisibleComments() }
    }

    /// Builds a MEDIA page's comments panel on the settle seam, so the tap
    /// that opens it has nothing left to build. The text pages' resting
    /// pre-render doctrine, applied to the cost rather than to the layout:
    /// one page at a time, discarded when it resigns.
    func prewarmComments(for id: PostID, host cell: SnapFeedCell) {
        // NEVER DURING A FLIGHT. This is ~100ms of layout, and `willDisplay`
        // fires inside the hero transition's own `container.layoutIfNeeded` —
        // so warming here paid for the comments panel out of the FLIGHT's
        // frame budget. Measured: the present leg's first layout went from
        // 36–64ms to 139–145ms with this running, which is the same mistake
        // the warm exists to fix, moved to a worse place. Playback is deferred
        // across the flight for exactly this reason; so is this now, and
        // `zoomTransitionDidEnd` picks it up on landing.
        guard !host.flight.isAwaitingZoomPresentation else { return }
        // The sheet's panel waits beside the page, not in it (#2087), and is
        // built over the turns after this one (#2136).
        stageCommentsSheetWarm(for: id)
    }

    /// How long after a transition the warm waits for genuine idle.
    ///
    /// Long enough to clear the flight (0.45s) and the settle behind it. The
    /// warm costs nothing in hit rate for waiting: engaging the comments is a
    /// deliberate act that arrives seconds later, not frames.
    private static let idleWarmDelay: TimeInterval = 0.6

    /// Warms the active page's comments once the screen has actually gone
    /// quiet, re-checking on arrival — the page may have moved on, or the
    /// viewer may have engaged already, in which case there is nothing to do.
    ///
    /// ⚠️ **0.6 s IS A GUESS AT "QUIET", SO THE ARRIVAL CHECKS IT.** The timer
    /// only knew the page, not the screen: a swipe, a grab-to-dismiss or a
    /// pop begun inside the delay got the ~100–150 ms build in the middle of
    /// the gesture — the stall this deferral exists to keep out of sight,
    /// moved into the viewer's hands. On arrival it now needs the screen on
    /// screen and still: no transition, no finger on the pager, no
    /// deceleration, no dismissal. Moving → try again one delay later; gone →
    /// drop it (a new page is warmed by its own settle, a return by its own
    /// landing). One pending warm at most, and leaving calls it off.
    func scheduleIdleCommentsWarm() {
        idleCommentsWarm?.cancel()
        let warm = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.idleCommentsWarm = nil
            guard self.host.isOnScreen, self.host.view.window != nil else { return }
            guard self.isQuietForCommentsWarm else { return self.scheduleIdleCommentsWarm() }
            self.rewarmActivePageComments()
        }
        idleCommentsWarm = warm
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleWarmDelay, execute: warm)
    }

    func cancelIdleCommentsWarm() {
        idleCommentsWarm?.cancel()
        idleCommentsWarm = nil
    }

    /// Nothing is moving that ~100 ms of layout could stall.
    private var isQuietForCommentsWarm: Bool {
        host.transitionCoordinator == nil
            && !host.flight.isAwaitingZoomPresentation
            && !host.flight.isEngagedDismissalActive
            && !host.collectionView.isTracking
            && !host.collectionView.isDragging
            && !host.collectionView.isDecelerating
    }

    /// Warms the page that is active RIGHT NOW — the disengagement's tail,
    /// where the settle seam has long since passed.
    private func rewarmActivePageComments() {
        guard let index = host.lifecycle.activeIndex, host.orderedIDs.indices.contains(index),
              let cell = host.collectionView.cellForItem(
                  at: IndexPath(item: index, section: 0)
              ) as? SnapFeedCell else { return }
        prewarmComments(for: host.orderedIDs[index], host: cell)
    }

    /// Drops a warm panel that was never engaged — the page moved on, or its
    /// cell is being recycled underneath it.
    func discardPrewarmedComments() {
        commentsSheetWarm = nil
        stagedCommentsWarm = nil
    }

    /// The TEXT page's resting engagement, PHASE 2 (settle lock): once the
    /// page has locked into place, freeze the pager (the dead-end doctrine
    /// — over-scroll never chains to a page change) and swap in the
    /// engaged toolbar context. Deferred out of the pre-render so neither
    /// touches the still-in-flight scroll. Runs once per engagement.
    /// Makes the screen match the page it is actually on.
    ///
    /// ⚠️ DERIVED, NOT MAINTAINED — and every leak in this file came from the
    /// difference.
    ///
    /// The resting interface and the pager's lock used to be moved by
    /// TRANSITIONS: mounted here, torn down there, unlocked in a teardown. Each
    /// of those runs only if its callback does, and the callbacks are not
    /// guaranteed — a cell recycled without an end-display, a resign leg that
    /// defers to one, a promotion waiting for a slot nobody freed. Any single
    /// miss leaves the screen describing a page the viewer left: measured as
    /// `settled=1 engaged=post-new-07 scrollEnabled=false`, two pages later,
    /// with the pager locked for a post no longer on screen. Nothing could
    /// scroll and nothing in the trace said why.
    ///
    /// A reconcile cannot leak. It asks what is true NOW — which page is
    /// settled, whether the old one is still visible — and makes the screen
    /// agree. A missed callback costs one settle's delay instead of the rest of
    /// the session.
    func reconcileRestingInterface(activeIndex: Int) {
        let activeID = host.orderedIDs.indices.contains(activeIndex) ? host.orderedIDs[activeIndex] : nil
        let activeIsText = host.isTextPage(activeID)
        #if DEBUG
        // `-grab-log`: what the reconcile saw. An interface that survives its
        // page is invisible in every other line — the screen looks settled and
        // the pager is simply dead.
        if LaunchArgument.grabLog.isPassed() {
            print("[reconcile] active=\(activeID?.rawValue ?? "nil") text=\(activeIsText)"
                + " engaged=\(commentsEngagedID?.rawValue ?? "nil")"
                + " resting=\(commentsEngagementIsResting)"
                + " engagedOnScreen=\(commentsEngagedID.map(isPostOnScreen) ?? false)")
        }
        #endif

        // An engagement belonging to a page that has LEFT is over, whatever
        // failed to say so. Still-visible pages keep theirs: that is what stops
        // the page being left from emptying while the settle animates.
        if let engaged = commentsEngagedID, commentsEngagementIsResting,
           engaged != activeID, !isPostOnScreen(engaged) {
            finishCommentsDisengagement()
        }
        // The settled text page owns the interface: promote what is already
        // mounted, or mount it.
        // ⚠️ NOT WHILE A PLACEHOLDER STANDS FOR THIS PAGE. The settle can land
        // here mid-flight, and mounting the real panel then put real rows
        // over the placeholder's bones for the rest of the flight (filmed on
        // a device, 25 September 2026). The landing mounts it.
        if activeIsText, let activeID, deferredResting?.id != activeID,
           !promoteRestingPreview(for: activeID),
           commentsEngagedID == nil,
           let cell = host.collectionView.cellForItem(
               at: IndexPath(item: activeIndex, section: 0)
           ) as? SnapFeedCell {
            presentRestingComments(for: activeID, host: cell)
        }
        // ⚠️ AND SO DOES THE COMPOSER'S KEYBOARD CEILING.
        //
        // That ceiling is anchored in WINDOW space, so a panel whose cell still
        // hangs below the screen has its composer clamped to the screen's edge
        // instead of travelling with its page — two composers at once, one
        // moving and one stuck.
        //
        // Granting it at the MOUNT was the first attempt and it only covered
        // the page that arrives while another holds the slot. A page arriving
        // from a media post takes the slot outright, mounts as the engagement,
        // and kept the ceiling — which is why it went wrong "sometimes".
        // Derived from the settled page, like everything else here, it cannot
        // depend on which route the panel took.
        syncComposerKeyboardCeilings(activeID: activeID)
        // And so does the bar's day (#757): a swipe that settled, or one
        // that went back home, shows the day of the panel now engaged.
        host.syncCommentsDay()
        // ⚠️ AND SO DOES THE GROUND BEHIND THE PAGES.
        //
        // The pager's own background is what shows through any strip a page has
        // not covered — and there is always such a strip for a frame or two: a
        // cell is recycled the moment the model says it has left, while the
        // pixels of the settle are still arriving. Black behind a light page
        // makes that frame a BLACK BAND across the top of the screen, which is
        // what "the post goes black on the way out" was. Measured on a
        // recording: one frame in a hundred and six, top-of-screen brightness
        // 12 against 90 for every other frame.
        //
        // Matching the ground to the settled page does not fix the timing — it
        // makes the timing invisible, which is better: no amount of care about
        // when a cell is recycled can guarantee the frame, and this needs no
        // guarantee.
        // ⚠️ UNLESS A FLIGHT IS BEING COMPOSITED THROUGH THIS SCREEN.
        //
        // A masked-hero opening (a post opened from its COMMENT COUNT) and an
        // engaged dismissal both clear this screen's floors on purpose: the
        // thread is drawn over the card carrying the photograph, and an opaque
        // ground between them shuts the card out. This rule runs at EVERY
        // settle — which includes the settles a flight triggers — so without
        // the guard it painted the ground black one frame into the opening and
        // the media only reappeared when the card was removed. Reported as the
        // media not transitioning at all; filmed as one frame of photograph
        // followed by black.
        //
        // The floors are restored where the flight ends (`zoomTransitionDidEnd`,
        // `endEngagedDismissalIfNeeded`), which is also the moment this rule
        // becomes true again.
        // Through the resolver, so the ROOT view follows the same rule the
        // pager already did and the two can no longer disagree.
        host.applyGrounds()
        // ⚠️ AND THE LOCK FOLLOWS THE SETTLED PAGE, not the engagement.
        //
        // A text page disables the pager because its own scroll view would
        // chain with it. That is a fact about the page on screen, so it is read
        // off the page on screen — an engagement that outlived its page cannot
        // take the pager down with it.
        host.pagerScrollLock.followSettledPage(isText: activeIsText)
    }

    /// Whether the post still has PIXELS on screen.
    ///
    /// ⚠️ GEOMETRY, AND FROM THE PRESENTATION LAYER — asking UIKit which cells
    /// are visible answers about the MODEL, and during a settle the model is
    /// already at the destination while the pixels are still travelling. A page
    /// half on screen therefore reported itself gone, its interface was torn
    /// down under the viewer, and what was left was the bare cell: a white
    /// strip with an orphaned composer bar, then the black media floor as it
    /// slid away. Reported twice, and both halves are this one line.
    func isPostOnScreen(_ id: PostID) -> Bool {
        guard let index = host.orderedIDs.firstIndex(of: id) else { return false }
        let page = host.collectionView.bounds.height
        guard page > 0 else { return false }
        let top = CGFloat(index) * page
        // ⚠️ THE MODEL, WIDENED BY A SETTLE THAT IS STILL RUNNING.
        //
        // The presentation layer was tried and is not an answer: it reports a
        // stale offset when nothing is animating, so a page two positions back
        // read as on-screen for the rest of the session — measured as
        // `active=post-new-06 engaged=post-new-07 engagedOnScreen=true`, with
        // the pager locked for a post nobody could see.
        //
        // Our own settle is the ONE case where the model has arrived and the
        // pixels have not, and we start that animation ourselves, so its span
        // is known rather than inferred. Everywhere else — a finger, UIKit's
        // deceleration — the model IS where the pixels are.
        let live = host.collectionView.contentOffset.y
        let lower = min(live, host.pagerDrive.settleFromOffset ?? live)
        let upper = max(live, host.pagerDrive.settleFromOffset ?? live)
        return top < upper + page && top + page > lower
    }

    func lockRestingEngagement() {
        guard commentsEngagementIsResting, !restingLockApplied,
              commentsEngagedID != nil else { return }
        restingLockApplied = true
        host.pagerScrollLock.hold(.restingPanel)
        host.commentTabs.bind(to: commentsContentVC as? PostDetailViewController)
        host.syncCommentSortAvailability()
        host.setEngagedChrome(true, hasMedia: false, animated: true)
    }

    /// The comments sheet closed, if one is up: the QA hooks'.
    func dismissComments() {
        commentsSheet?.close()
    }
    func engagedCell() -> SnapFeedCell? {
        guard let id = commentsEngagedID,
              let indexPath = host.pageIndexPath(for: id) else { return nil }
        return host.collectionView.cellForItem(at: indexPath) as? SnapFeedCell
    }

    func finishCommentsDisengagement() {
        // Idempotent: teardown reaches here from several paths (animated
        // dismiss completion, resign leg, didEndDisplaying belt), and a
        // resting pre-render can be torn down by more than one — a second
        // call must be a clean no-op.
        guard commentsEngagedID != nil else { return }
        // The bar is resting from here, whichever path got here — some never
        // pass through `setEngagedChrome(false)` (see below).
        host.engagedChromeOnBar = false
        // Belt and braces for non-animated/interrupted paths.
        let cell = engagedCell()
        cell?.setCommentsEngaged(false)
        if let content = commentsContentVC {
            content.willMove(toParent: nil)
            content.view.removeFromSuperview()
            content.removeFromParent()
        }
        cell?.clearComments()
        // A panel kept for the next engagement starts back in place (#1730).
        (commentsContentVC as? PostDetailViewController)?.setOverlayOffset(0)
        // ⚠️ THE PAGE JUST LEFT KEEPS ITS PANEL (#2059): the feed pages back
        // (#2056), and the text page the viewer just left is the previous
        // page now — its resting panel, built and laid out, is kept as that
        // page's warm instead of being thrown away and built again on the way
        // back. Its stream is where the reader left it, too.
        if commentsEngagementIsResting, let id = commentsEngagedID, let content = commentsContentVC {
            keepAsNeighbourWarm(content, for: id)
        }
        commentsContentVC = nil
        commentsEngagedID = nil
        commentsEngagementIsResting = false
        restingLockApplied = false
        host.pagerScrollLock.release(.restingPanel)
        // REOPENING must be as cheap as opening. The warm is consumed by the
        // engagement, and no further activation is coming for a page that
        // never moved — so without this, engage → close → engage pays the
        // full ~115ms on the second tap. On the idle clock (#2116): the build
        // in the teardown's own turn was a ~100 ms hang after every close.
        scheduleIdleCommentsWarm()
        // The bar's pixels were never touched (keep-and-stack), but its
        // ITEMS are engagement context — settle them for the paths that
        // never ran the animated mirror (orphaned teardown, instant
        // cleanup). Identity-compare first: after a normal dismiss the
        // swap already landed, and re-setting identical items would only
        // churn the bar's layout.
        if !host.defaultToolbarItems.isEmpty {
            host.setEngagedChrome(false, hasMedia: true, animated: false)
        }
    }

    // MARK: - The loading page

    func armLoadingPage(for id: PostID) { loadingPageID = id }

    /// The loading page, drawn on the screen's own view; the screen's view
    /// is loaded first.
    func presentLoadingPage() {
        guard !loadingPageDisarmed, loadingPage == nil, host.orderedIDs.isEmpty,
              commentsEngagedID == nil, commentsContentVC == nil,
              let id = loadingPageID, let makeCommentsPanelContent = host.makeCommentsPanelContent,
              host.view.bounds.width > 0, host.view.bounds.height > 0
        else { return }

        let panel = (host.makeRestingCommentsPanelContent ?? makeCommentsPanelContent)(id)
        host.applyRailSlot(to: panel, hostedByPage: false)
        host.bindCaptionAuthor(of: panel, for: id)
        // Transparent, so the lent ground is still what is on screen — and so a
        // flight that clears both floors is not lidded by this.
        panel.view.backgroundColor = .clear
        panel.overrideUserInterfaceStyle = .unspecified
        panel.view.isUserInteractionEnabled = false
        host.addChild(panel)
        panel.view.frame = host.view.bounds
        panel.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.insertSubview(panel.view, aboveSubview: host.collectionView)
        panel.didMove(toParent: host)

        // The band the CELL owns at rest. The panel brings its own footer and
        // composer; only the header band has to be stood in for.
        let frost = ProgressiveFrostView(
            maskColors: SnapCommentsLayout.headerFrostMaskColors,
            maskLocations: SnapCommentsLayout.headerFrostMaskLocations
        )
        frost.setVeilOpacity(SnapCommentsLayout.frostVeilOpacity(hasMedia: false))
        frost.autoresizingMask = [.flexibleWidth]
        host.view.insertSubview(frost, aboveSubview: panel.view)

        loadingPage = panel
        loadingPageFrost = frost
        (panel as? PostDetailViewController)?.setComposerEntranceState(offstage: false)
        (panel as? PostDetailViewController)?.setComposerTracksKeyboard(false)
        // ⚠️ THE INSETS ARE ZERO HERE — this runs before the push. The geometry
        // is placed by `reapplyEngagedInsets`, which runs again once the
        // transition container resolves the real safe area.
        host.reapplyEngagedInsets()

        #if DEBUG
        if LaunchArgument.mediaLog.isPassed() {
            print(String(format: "[media] %.3f loading-page install id=%@ h=%.0f",
                         CACurrentMediaTime(), id.rawValue, host.view.bounds.height))
        }
        #endif
    }

    /// A completed disappearance: the builder's seed Task is never
    /// cancelled, so a render can still land on a screen that has gone.
    func disarmLoadingPage() {
        loadingPageDisarmed = true
        if let panel = loadingPage {
            loadingPage = nil
            loadingPageID = nil
            fadeOutLoadingPage(panel, animated: false)
        }
        handedOverLoadingPage = nil
    }

    /// A repoint is a second cold window: the old page goes, the next is
    /// armed.
    func rearmLoadingPage(for id: PostID?) {
        if let panel = loadingPage {
            loadingPage = nil
            fadeOutLoadingPage(panel, animated: false)
        }
        handedOverLoadingPage = nil
        loadingPageID = id
        loadingPageDisarmed = false
    }

    #if DEBUG
    /// The screen's `debugPrewarmedRestingID`.
    private(set) var debugPrewarmedRestingID: PostID?
    #endif
}
