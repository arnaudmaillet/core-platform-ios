#if DEBUG
import CoreModels
import CoreStorage
import DesignSystem
import LaunchArguments
import PostSurfaces
import UIKit

/// What the full-screen feed's launch-argument hooks ask of their screen
/// (#2514): the pages and the pager, the sheets and the spends they drive,
/// and the close.
///
/// A view controller: the hooks drive what the viewer would, on the screen
/// itself.
@MainActor
protocol SnapFeedDebugHooksHost: UIViewController {
    var isClosable: Bool { get }
    var orderedIDs: [PostID] { get }
    var collectionView: UICollectionView! { get }
    var lifecycle: SnapLifecycleDispatcher { get }
    var activeModel: FeedItemDisplayModel? { get }
    var bookmarks: PostBookmarkStore { get }
    var toolbarComposer: SnapToolbarComposer { get }
    var commentsCoordinator: SnapCommentsCoordinator { get }
    /// The sound sheet the last `presentSoundSheet` raised.
    var debugPresentedSoundSheet: SoundSheetViewController? { get }
    func closeFeed()
    func updateActiveItem()
    func presentSoundSheet()
    func presentWalletSheet()
    func performBoost(on id: PostID, spend: WalletStakeSpend, from source: UIResponder?)
    func performBoostUndo(on id: PostID, from source: UIResponder?)
    func debugDrivePageSwipe(steps: Int, distance: CGFloat)
    func debugFlingPages(_ remaining: Int, back: Int)
    func dumpBarHierarchy()
}

/// The full-screen feed's launch-argument hooks (#2514): what `viewDidAppear`
/// arms in a DEBUG build, each once per screen (or once per launch), so a run
/// in the simulator can drive what a finger would — a page, a fling, a close,
/// the sound sheet, a boost, the comments.
///
/// The `debug*` drives and probes the tests read stay on the screen
/// (`SnapFeedViewController+QA.swift`); this owns only the hooks and their
/// one-shot flags.
@MainActor
final class SnapFeedDebugHooks {
    private unowned let host: any SnapFeedDebugHooksHost

    init(host: any SnapFeedDebugHooksHost) {
        self.host = host
    }

    private var didDebugPause = false
    private var didDebugScroll = false
    private var didDebugScrollDemo = false
    private var didDebugCommentsDemo = false
    /// `-snap-start-paused`: pauses the active cell shortly after appearing so
    /// the pause glyph can be screenshotted (taps can't be injected in the sim).
    /// `-snap-auto-dismiss`: dismisses a presented (map-opened) feed shortly
    /// after it settles, so the zoom-out leg can be recorded in the sim.
    /// `-snap-start-index N`: snaps to page N shortly after appearing (mock:
    /// every index%3==2 is text-only) — deterministic access to a given page
    /// kind without scroll injection.
    private var didDebugPageSwipe = false
    private var didDebugFling = false
    private var didDebugAutoDismiss = false
    /// ONCE PER LAUNCH, not per feed: a feed opened from the sheet's own grid
    /// ran the hook again and stacked a second sheet over it.
    private static var didDebugSoundSheet = false
    /// Once per launch, like the sound sheet's.
    private static var didDebugSaveElsewhere = false

    func runDebugAppearanceHooks() {
        // Once per screen, like every other hook here: this runs from
        // `viewDidAppear`, and without the flag each re-appearance (a sheet
        // dismissed over the feed, a pop back onto it) armed ANOTHER close —
        // a second `closeFeed()` 2.5s later against whatever was then on top.
        let arguments = ProcessInfo.processInfo.arguments
        // `-snap-auto-dismiss [delay]`: the delay (2.5s by default) lets a run
        // page first (`-snap-fling`, +3s) and film the close from another post
        // on any surface (#951), not only For You's (`-foryou-demo-close`).
        if !didDebugAutoDismiss, LaunchArgument.snapAutoDismiss.isPassed(in: arguments), host.isClosable {
            didDebugAutoDismiss = true
            let delay = LaunchArgument.snapAutoDismiss.doubleValue(in: arguments) ?? 2.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.host.closeFeed()
            }
        }
        // `-snap-page-demo [delay]`: drive the page swipe once the feed has
        // settled, so the animated page change can be filmed.
        if !didDebugPageSwipe, LaunchArgument.snapPageDemo.isPassed(in: arguments) {
            didDebugPageSwipe = true
            let delay = LaunchArgument.snapPageDemo.doubleValue(in: arguments) ?? 3.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.host.debugDrivePageSwipe(steps: 12, distance: 520)
            }
        }
        // `-snap-page-back-demo [delay]`: the same drive downward — the
        // previous post (#2058). Pair with `-snap-start-index N`.
        if !didDebugPageSwipe, LaunchArgument.snapPageBackDemo.isPassed(in: arguments) {
            didDebugPageSwipe = true
            let delay = LaunchArgument.snapPageBackDemo.doubleValue(in: arguments) ?? 3.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.host.debugDrivePageSwipe(steps: 12, distance: -520)
            }
        }
        // `-snap-fling [pages]`: scrolls the pager one page at a time the way a
        // FLICK does — a stream of small offset changes, each with its own
        // delegate callback, then a settle.
        //
        // Nothing before this could exercise a scroll at all. `-snap-page-demo`
        // drives the text page's own swipe gesture, and `-snap-start-index`
        // teleports; both reach the settle without ever passing through the
        // middle of the screen, which is exactly where the picture now changes
        // hands (`updateViewportPlayback`). Read the run with `-media-log`: a
        // `[page-play]` between `[fling] begin` and `[fling] settle` is the
        // clip starting mid-scroll, which is the whole claim.
        if !didDebugFling, LaunchArgument.snapFling.isPassed(in: arguments) {
            didDebugFling = true
            let pages = LaunchArgument.snapFling.intValue(in: arguments) ?? 1
            let back = LaunchArgument.snapFlingBack.isPassed(in: arguments) ? pages : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.host.debugFlingPages(pages, back: back)
            }
        }
        // ⚠️ WAITS FOR THE PAGE TO EXIST, not for 1.5s. On a cold run the
        // posts had not arrived by then, `indices.contains(target)` failed and
        // the hook returned without a word — the screenshot showed page 0 and
        // read as the page asked for. The 1.5s stays as the floor (the feed's
        // own settle); past it the jump waits for the data, and says so if it
        // never comes or the jump does not land.
        if !didDebugScroll,
           let target = LaunchArgument.snapStartIndex.intValue(in: arguments) {
            didDebugScroll = true
            let label = "-snap-start-index \(target)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                QAWait.until(label, { [weak self] in
                    guard let self else { return false }
                    return self.host.orderedIDs.indices.contains(target) && self.host.collectionView.bounds.height > 0
                }) { [weak self] in
                    guard let self else { return }
                    self.host.collectionView.scrollToItem(at: IndexPath(item: target, section: 0), at: .top, animated: false)
                    self.host.updateActiveItem()
                    if self.host.lifecycle.activeIndex == target {
                        print("[qa] \(label): active page \(target) of \(self.host.orderedIDs.count)")
                    } else {
                        QAWait.fail(label, "jumped but active page is \(self.host.lifecycle.activeIndex.map(String.init) ?? "nil")")
                    }
                }
            }
        }
        // `-snap-sound-sheet [large|roundtrip|push]`: opens the active page's
        // sound sheet — the attribution's tap — once the page (or
        // `-snap-start-index`'s target) is settled; `large` then raises it to
        // large 2s later, `roundtrip` also comes back to collapsed 2.5s after
        // that; `push` presses Popular's "View all" 2s later (at collapsed:
        // the sheet must not move) and comes back 3s after that. Pair with
        // `-sound-sheet-trace` for the collapsed detent's measures and the
        // reveal's progress.
        if !Self.didDebugSoundSheet, LaunchArgument.snapSoundSheet.isPassed(in: arguments) {
            Self.didDebugSoundSheet = true
            let mode = LaunchArgument.snapSoundSheet.value(in: arguments) ?? ""
            let expands = mode == "large" || mode == "roundtrip"
            let jumpTarget = LaunchArgument.snapStartIndex.intValue(in: arguments)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                QAWait.until("-snap-sound-sheet", { [weak self] in
                    guard let self, let index = self.host.lifecycle.activeIndex else { return false }
                    return jumpTarget == nil || index == jumpTarget
                }) { [weak self] in
                    guard let self else { return }
                    self.host.presentSoundSheet()
                    guard let sheet = self.host.debugPresentedSoundSheet else {
                        QAWait.fail("-snap-sound-sheet", "the active page has no sound")
                        return
                    }
                    print("[qa] -snap-sound-sheet: opened")
                    if mode == "push" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak sheet] in
                            sheet?.debugShowPopular()
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak sheet] in
                            sheet?.debugPopSection()
                        }
                        return
                    }
                    guard expands else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak sheet] in
                        sheet?.debugExpand()
                    }
                    guard mode == "roundtrip" else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak sheet] in
                        sheet?.debugCollapse()
                    }
                }
            }
        }
        // `-feed-open-wallet`: presents the wallet sheet over the feed ~2s
        // after settle — the header badge opens it on tap, which the sim
        // can't deliver. The map's `-open-wallet` stays separate: both
        // firing at once would race two presentations of one sheet.
        if LaunchArgument.feedOpenWallet.isPassed(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.host.presentWalletSheet()
            }
        }
        // `-wallet-demo-boost [amount]`: boosts the ACTIVE post through the
        // real spend path (wallet debit → haptic → "+N" float) shortly after
        // settle — the rail anchor opens it on tap, which the sim can't
        // deliver. Pair with `-wallet-log` for the ledger line and
        // `-wallet-balance 0` for the denied shake. `-wallet-demo-shot` fires
        // one ×100 shot instead (pair with `-wallet-stake-shots N`).
        if LaunchArgument.walletDemoBoost.isPassed(in: arguments) || LaunchArgument.walletDemoShot.isPassed(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self else { return }
                let index = self.host.lifecycle.activeIndex ?? 0
                guard self.host.orderedIDs.indices.contains(index) else { return }
                let amount: Int
                if let chosen = LaunchArgument.walletDemoBoost.intValue(in: arguments) {
                    amount = chosen
                } else {
                    amount = WalletStore.Policy.defaultStakeAmount
                }
                let cell = self.host.collectionView.visibleCells
                    .compactMap { $0 as? SnapFeedCell }.first
                let spend: WalletStakeSpend = LaunchArgument.walletDemoShot.isPassed(in: arguments) ? .shot : .likes(amount)
                self.host.performBoost(on: self.host.orderedIDs[index], spend: spend, from: cell)
            }
        }
        // `-wallet-demo-undo`: takes back the active post's session boosts
        // ~2s after `-wallet-demo-boost` landed them — the menu's Undo
        // entry, minus the long-press the sim can't deliver. The pair
        // exercises the full loop: spend, receipt face, refund, glyph face.
        if LaunchArgument.walletDemoUndo.isPassed(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) { [weak self] in
                guard let self else { return }
                let index = self.host.lifecycle.activeIndex ?? 0
                guard self.host.orderedIDs.indices.contains(index) else { return }
                let cell = self.host.collectionView.visibleCells
                    .compactMap { $0 as? SnapFeedCell }.first
                self.host.performBoostUndo(on: self.host.orderedIDs[index], from: cell)
            }
        }
        // `-save-elsewhere [seconds]` (#1067): toggles the active post's save
        // `seconds` (default 3) after appearing THROUGH THE APP'S PILE, as a
        // card or a grid saves — never this screen's own toggle, which draws
        // its glyph itself. Only the saved fact's observation can redraw the
        // glyph; the log line reads it back right after the write.
        if !Self.didDebugSaveElsewhere, LaunchArgument.saveElsewhere.isPassed(in: arguments) {
            Self.didDebugSaveElsewhere = true
            let delay = LaunchArgument.saveElsewhere.doubleValue(in: arguments) ?? 3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                QAWait.until("-save-elsewhere", { [weak self] in self?.host.activeModel != nil }) { [weak self] in
                    guard let self, let id = self.host.activeModel?.id else { return }
                    let before = self.host.toolbarComposer.drawnBookmarkSymbol
                    let saved = self.host.bookmarks.toggle(id.rawValue)
                    print("[qa] -save-elsewhere: \(id.rawValue) saved=\(saved) glyph \(before) -> \(self.host.toolbarComposer.drawnBookmarkSymbol)")
                }
            }
        }
        // `-snap-scroll-demo`: animated-scrolls one page forward shortly
        // after settle, so a page *transition* can be recorded in the sim
        // (scroll gestures can't be injected) — the comment ticker must be
        // flowing on both pages during the motion, not pop in at rest.
        if !didDebugScrollDemo, LaunchArgument.snapScrollDemo.isPassed(in: arguments) {
            didDebugScrollDemo = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self else { return }
                let target = (self.host.lifecycle.activeIndex ?? 0) + 1
                guard self.host.orderedIDs.indices.contains(target) else { return }
                // Settles in scrollViewDidEndScrollingAnimation.
                self.host.collectionView.scrollToItem(at: IndexPath(item: target, section: 0), at: .top, animated: true)
            }
        }
        // `-snap-comments-demo`: opens the comments engagement on the active
        // page ~2.5s after appear (after any `-snap-start-index` jump at
        // 1.5s settles) — the mutated layout can be screenshotted without
        // tap injection.
        //
        // ⚠️ "AFTER THE JUMP" IS A STATE, not a time. With `-snap-start-index`
        // the 2.5s used to race the jump's own 1.5s + data arrival: on a cold
        // run the engagement opened on page 0 and the jump then scrolled away
        // under it. It now waits for the active page to BE the jump's target
        // (or, alone, for any active page), and says so if that never happens.
        if !didDebugCommentsDemo, LaunchArgument.snapCommentsDemo.isPassed(in: arguments) {
            didDebugCommentsDemo = true
            let jumpTarget = LaunchArgument.snapStartIndex.intValue(in: arguments)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                QAWait.until("-snap-comments-demo", { [weak self] in
                    guard let self, let index = self.host.lifecycle.activeIndex,
                          self.host.orderedIDs.indices.contains(index) else { return false }
                    return jumpTarget == nil || index == jumpTarget
                }) { [weak self] in
                    guard let self, let index = self.host.lifecycle.activeIndex,
                          self.host.orderedIDs.indices.contains(index) else { return }
                    self.host.commentsCoordinator.presentComments(for: self.host.orderedIDs[index])
                    // `-snap-comments-close N`: dismisses the engagement N
                    // seconds after it opens, landing the page back at rest.
                    // The RETURN leg is a state change of its own — the page's
                    // chrome comes back and the empty state re-reads its words
                    // — and it was the one leg no launch arg could reach, so it
                    // could only be reasoned about. Chained off the open rather
                    // than scheduled from appear, so the delay means what it
                    // says whatever the open cost.
                    guard let after = LaunchArgument.snapCommentsClose.doubleValue(in: arguments) else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                        self?.host.commentsCoordinator.dismissComments()
                        // `-snap-comments-reopen N`: taps the entry point again N
                        // seconds after the close. The REOPEN is what a broken
                        // teardown kills — the page still looks right, and every
                        // comment surface is simply dead — so the QA path has to
                        // go all the way round.
                        guard let reopenAfter = LaunchArgument.snapCommentsReopen.doubleValue(in: arguments) else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + reopenAfter) { [weak self] in
                            guard let self, let index = self.host.lifecycle.activeIndex,
                                  self.host.orderedIDs.indices.contains(index) else { return }
                            self.host.commentsCoordinator.presentComments(for: self.host.orderedIDs[index])
                        }
                    }
                }
            }
        }
        // `-dump-bars`: prints the navigation view hierarchy (class, frame,
        // alpha, hidden) plus each toolbar item's superview chain ~5s after
        // appear — the tool that pins down WHERE iOS 26 hosts the Liquid
        // Glass item platters (they are not in the toolbar's subtree).
        if LaunchArgument.dumpBars.isPassed(in: arguments) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                self?.host.dumpBarHierarchy()
            }
        }
        guard !didDebugPause,
              LaunchArgument.snapStartPaused.isPassed() else { return }
        didDebugPause = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, let index = self.host.lifecycle.activeIndex,
                  let cell = self.host.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? SnapFeedCell
            else { return }
            cell.togglePlayback()
        }
    }
}
#endif
