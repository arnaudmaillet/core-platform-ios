#if DEBUG
import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import MediaCore
import MediaPlayback
import PostGrid
import UIKit

// MARK: - QA hooks
//
// The launch-argument automation (`installDebugHooks`, run from
// `viewDidLoad`), the scripted grab cycles and the `debug*` accessors.
// Private methods stay private: this file reaches them through thin `debug*`
// wrappers in the main file (`debugOpenFeed`, `debugApplyContext`,
// `debugFloatingBarCover`). `auditPostMenu` and `logRowSource` stay in `ForYouViewController.swift`:
// they read private menu and flight state that only they use. Stored DEBUG
// properties stay with the type.

// MARK: - Launch-argument hooks

extension ForYouViewController {
    /// Re-opens the feed for the next scripted cycle, if any are left.
    ///
    /// Repetition is the point: a state leak that survives ONE return is a bug
    /// anyone would catch, so the ones that reach a release are the ones that
    /// need several round trips to show. Driven off the completed return rather
    /// than a timer, so each cycle starts from a genuinely settled grid.
    func debugAdvanceGrabCycleIfNeeded() {
        guard Self.remainingGrabCycles > 0 else { return }
        Self.remainingGrabCycles -= 1
        let index = ProcessInfo.processInfo.arguments
            .firstIndex(of: "-foryou-open")
            .flatMap { $0 + 1 < ProcessInfo.processInfo.arguments.count
                ? Int(ProcessInfo.processInfo.arguments[$0 + 1]) : nil } ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            debugOpenFeed(at: index)
        }
    }

    /// Steps the active page down the corpus, reporting at each stop what the
    /// page thinks SHOULD be playing.
    ///
    /// The independent half matters as much as the scrolling: the page
    /// recomputes the visible video rows and their distance from the viewport
    /// centre from geometry, and `[grid-rank]` reports what the coordinator
    /// actually chose. Agreement between two answers derived separately is the
    /// evidence; the coordinator agreeing with itself would be none.
    private func scheduleScrollDemo(steps: Int) {
        var attempts = 0
        func begin() {
            attempts += 1
            // Wait for content: a page with nothing in it scrolls nowhere, and
            // a fixed delay silently no-ops under `-mock-latency`.
            guard page.debugScrollableHeight > 0 else {
                if attempts < 80 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: begin) }
                return
            }
            for step in 0...steps {
                // 2.5s a stop: a start is asynchronous (the URL resolves, then
                // the player attaches), so a shorter dwell reports the previous
                // stop's answer.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 * Double(step)) { [weak self] in
                    guard let self else { return }
                    let target = min(page.debugScrollableHeight,
                                     CGFloat(step) * page.debugViewportHeight * 0.6)
                    print("[foryou-scroll] step \(step)/\(steps) y=\(Int(target)) "
                          + "expect=\(page.debugVisibleVideoRanking.map { "\($0.id)@\($0.distance)" })")
                    page.debugScroll(toY: target)
                }
            }
        }
        begin()
    }

    /// `-foryou-open <index>` taps a tile once content has landed (the sim
    /// injects no taps); `-foryou-source <trending|recent|following>` drives the
    /// drop-down (a `UIMenu` needs a real tap to open); and
    /// `-foryou-grab-cycles <n>` repeats the whole open→grab→return round trip
    /// `n` more times, for hunting state that only leaks after several returns.
    func installDebugHooks() {
        let arguments = ProcessInfo.processInfo.arguments
        let openDelay = 0.5
        if let position = arguments.firstIndex(of: "-foryou-grab-cycles"),
           position + 1 < arguments.count, let count = Int(arguments[position + 1]) {
            Self.remainingGrabCycles = count
        }
        // `-foryou-context <entertainment|work|focus|gaming>` drives the lens.
        // A `UIMenu` needs a real tap to open, so this is the only way to reach
        // a non-default context from a script.
        if let position = arguments.firstIndex(of: "-foryou-context"),
           position + 1 < arguments.count,
           let context = ContentContext(rawValue: arguments[position + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.debugApplyContext(context)
            }
        }
        // `-foryou-scroll-demo <steps>` walks the active page down the corpus,
        // pausing long enough at each stop for playback to settle. The only way
        // to exercise autoplay's ranking under scroll: the reconcile that
        // decides which videos play is driven by scroll callbacks, and the
        // simulator injects no touches.
        if let position = arguments.firstIndex(of: "-foryou-scroll-demo"),
           position + 1 < arguments.count, let steps = Int(arguments[position + 1]) {
            scheduleScrollDemo(steps: steps)
        }
        // `-foryou-expand <index> [delay]`: presses a row's "Show more". Polls
        // for content rather than firing on a delay, for the same reason
        // `-foryou-open` does — a fixed wait silently no-ops under
        // `-mock-latency`.
        //
        // The optional delay is for FILMING it. A capture has to be started
        // after the app has settled or it is mostly launch, and by then the
        // default one-second press has already happened: three recordings in a
        // row caught nothing but the expanded end state.
        if let position = arguments.firstIndex(of: "-foryou-expand"),
           position + 1 < arguments.count, let index = Int(arguments[position + 1]) {
            let delay = position + 2 < arguments.count
                ? (Double(arguments[position + 2]) ?? 1.0)
                : 1.0
            var attempts = 0
            func attempt() {
                attempts += 1
                if page.debugTapShowMore(atIndex: index) {
                    print("[foryou-expand] expanded row \(index)")
                    return
                }
                if attempts < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                } else {
                    print("[foryou-expand] NOTHING TO EXPAND at row \(index)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: attempt)
        }
        // `-foryou-carousel <row> <page>`: swipes a collection row's pages.
        // Polls for the same reason `-foryou-expand` does — the row has to be
        // realized and its pages built, and a fixed delay silently no-ops.
        if let position = arguments.firstIndex(of: "-foryou-carousel"),
           position + 2 < arguments.count,
           let index = Int(arguments[position + 1]),
           let page = Int(arguments[position + 2]) {
            var attempts = 0
            func attempt() {
                attempts += 1
                if self.page.debugScrollCarousel(atIndex: index, toPage: page) {
                    print("[foryou-carousel] row \(index) → page \(page)")
                    return
                }
                if attempts < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                } else {
                    print("[foryou-carousel] NO COLLECTION at row \(index)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: attempt)
        }
        // `-foryou-view-all [delay]`: presses the first chunk's "View all"
        // once Discover has a chunk on screen, and `-foryou-gallery-open N`
        // then opens tile N of the pushed mosaic once its cover is up. Both
        // poll, like `-foryou-open`, because a fixed delay silently no-ops
        // under `-mock-latency`.
        if let position = arguments.firstIndex(of: "-foryou-view-all") {
            let delay = position + 1 < arguments.count ? (Double(arguments[position + 1]) ?? 1.0) : 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                QAWait.until("-foryou-view-all", { [weak self] in
                    guard let self else { return false }
                    return page.segments.contains { $0.chunk != nil }
                        && navigationController?.transitionCoordinator == nil
                }) { [weak self] in
                    guard let self else { return }
                    print("[qa] -foryou-view-all: pushing the mosaic")
                    pushDiscoverGallery()
                    scheduleGalleryOpenIfRequested()
                }
            }
        }
        installRowDebugHooks(arguments)
        // `-foryou-open-comments N` is `-foryou-open N` through the comment
        // count instead of the card, so the shorter route is exercised by the
        // same waiting-for-content machinery rather than by a second one.
        let viaComments = arguments.firstIndex(of: "-foryou-open-comments")
        guard let position = viaComments ?? arguments.firstIndex(of: "-foryou-open"),
              position + 1 < arguments.count,
              let index = Int(arguments[position + 1])
        else { return }
        // Polls rather than firing on a fixed delay: the tap needs landed
        // content, and a fixed delay silently no-ops under `-mock-latency`.
        //
        // It waits for the tile's COVER, not just the model. A person taps a
        // tile they can see, and the hero card is built from the pixels that
        // tile is rendering — firing the instant the model lands flies a blank
        // card and misreports the transition as broken. (It is not: an
        // unloaded tile and its card are both the same empty placeholder. But
        // the capture is worthless.) Text-only rows never get a cover, so the
        // attempt budget is the backstop that still lets them through.
        var attempts = 0
        func attempt() {
            attempts += 1
            let posts = page.posts
            // ⚠️ BOTH ENDS OF THE BUDGET SAY SO. Running out of attempts with
            // no row used to stop without a word — a run that opened nothing
            // read like one that opened something — and opening a row whose
            // cover never arrived was just as quiet, though that capture is
            // the "blank card" the paragraph above warns about.
            guard posts.indices.contains(index) else {
                if attempts < 60 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                } else {
                    QAWait.fail("-foryou-open \(index)",
                                "row not loaded after \(attempts) attempts (\(posts.count) posts)")
                }
                return
            }
            // ⚠️ BROUGHT ON SCREEN FIRST: a person taps a post they can see.
            // On Discover the scripts open index 3 — the first chunk's first
            // tile, under three cards — which is below the fold at launch; an
            // unrealized cell has no cover to wait for and no hero to fly, so
            // the open fell back to the plain push and the case measured the
            // wrong transition. Minimal, and a no-op for a post already in view.
            if !page.isPostVisible(posts[index].id) {
                page.revealPost(
                    posts[index].id,
                    clearing: UIEdgeInsets(top: view.safeAreaInsets.top, left: 0,
                                           bottom: debugFloatingBarCover, right: 0)
                )
            }
            let ready = page.heroAppearance(for: posts[index].id)?.cover != nil
            guard ready || attempts >= 60 else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: attempt)
                return
            }
            if !ready {
                print("[qa] -foryou-open \(index): opening WITHOUT a cover after \(attempts) attempts"
                    + " (kind=\(posts[index].kind); expected for a text row, a blank card otherwise)")
            }
            // Through the page's own selection path, so a scripted open runs
            // the same code a tap does — including the scroll-into-view
            // bookkeeping that `openFeed` alone would skip.
            if viaComments != nil {
                if !page.debugTapComments(at: index) {
                    print("[foryou-comments] row \(index) has no comment chip to press")
                }
            } else if !page.debugSelectItem(at: index) {
                debugOpenFeed(at: index)
            }
            // `-foryou-demo-close`: the chevron's close, as the rows' hooks
            // schedule it — with `-snap-fling N`, the close from wherever the
            // feed was paged to (a chunk tile's close from a words page).
            scheduleDemoCloseIfRequested()
            // `-zoom-repeat`: open, pop, open again (twice over). The hero's
            // stall has only ever been measured on the FIRST push of a
            // process, which cannot distinguish per-push cost from one-time
            // warm-up of whatever the push touches first. Two more rounds
            // separate them.
            //
            // ⚠️ EACH LEG WAITS FOR THE ONE BEFORE IT TO LAND. The rounds were
            // scheduled on a fixed 3s / +1.5s grid from the first open, and on
            // a cold run the first push was still in the air at 3s: the pop
            // landed mid-present, and every later leg ran against a stack in a
            // state nobody had asked for. The delays stay as floors; past
            // them a pop waits for the feed to be on top with no transition
            // running, and a reopen for this screen to be back the same way.
            if ProcessInfo.processInfo.arguments.contains("-zoom-repeat") {
                func runRound(_ round: Int) {
                    guard round <= 2 else { return }
                    // A DIFFERENT tile each round. Reopening the same one
                    // cannot tell a re-pointed feed from a stale one — both
                    // render the same post — so the harness would pass while
                    // reuse served the previous window.
                    // `-zoom-repeat-same` reopens the SAME tile, which is what
                    // a re-entry bug needs: a different tile exercises a fresh
                    // window and hides state the previous flight left behind.
                    let reopen = ProcessInfo.processInfo.arguments.contains("-zoom-repeat-same")
                        ? index : index + round
                    let popFloor = round == 1 ? 3.0 : 1.5
                    DispatchQueue.main.asyncAfter(deadline: .now() + popFloor) { [weak self] in
                        QAWait.until("-zoom-repeat round \(round) pop", { [weak self] in
                            guard let self, let nav = self.navigationController else { return false }
                            return nav.topViewController !== self && nav.transitionCoordinator == nil
                        }) { [weak self] in
                            self?.navigationController?.popViewController(animated: true)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                                QAWait.until("-zoom-repeat round \(round) reopen", { [weak self] in
                                    guard let self, let nav = self.navigationController else { return false }
                                    return nav.topViewController === self && nav.transitionCoordinator == nil
                                }) { [weak self] in
                                    self?.debugOpenFeed(at: reopen)
                                    runRound(round + 1)
                                }
                            }
                        }
                    }
                }
                runRound(1)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + openDelay, execute: attempt)
    }

    /// The rows' QA hooks — the simulator injects no taps, so each drives the
    /// row's own selection path once there is something to press:
    ///
    /// - `-foryou-open-story N [delay]`: taps friend N's avatar (the hero out
    ///   of the disc). With `-foryou-demo-close [delay]` the feed pops itself
    ///   once it has landed, so the close back onto the face — and the ring
    ///   clearing after it — can be filmed without a finger.
    /// - `-foryou-open-card N [delay]`: taps Following card N once its cover
    ///   is up.
    /// - `-foryou-push-list friends|following [delay]`: presses a row's
    ///   header; `-foryou-list-open N` then opens row N of the pushed list.
    ///
    /// All poll through `QAWait`, like `-foryou-open`: a fixed delay silently
    /// no-ops under `-mock-latency`, and a run that pressed nothing says so.
    private func installRowDebugHooks(_ arguments: [String]) {
        func value(after flag: String) -> (String, Double)? {
            guard let position = arguments.firstIndex(of: flag), position + 1 < arguments.count else {
                return nil
            }
            let delay = position + 2 < arguments.count ? Double(arguments[position + 2]) ?? 1.0 : 1.0
            return (arguments[position + 1], delay)
        }
        let isAtRest: () -> Bool = { [weak self] in
            guard let self, let nav = navigationController else { return false }
            return nav.topViewController === self && nav.transitionCoordinator == nil
        }
        if let (raw, delay) = value(after: "-foryou-open-story"), let index = Int(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                QAWait.until("-foryou-open-story \(index)", { [weak self] in
                    guard let self, isAtRest() else { return false }
                    return rails.stories.indices.contains(index)
                }) { [weak self] in
                    guard let self else { return }
                    let story = rails.stories[index]
                    print("[qa] -foryou-open-story \(index): \(story.handle) unseen=\(story.hasUnseen)"
                        + " posts=\(story.posts.map(\.id.rawValue))")
                    scheduleDemoCloseIfRequested()
                    _ = rails.debugTapStory(at: index)
                }
            }
        }
        if let (raw, delay) = value(after: "-foryou-open-card"), let index = Int(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                QAWait.until("-foryou-open-card \(index)", { [weak self] in
                    guard let self, isAtRest() else { return false }
                    return rails.debugCardIsReady(at: index)
                }) { [weak self] in
                    guard let self else { return }
                    let card = rails.cards[index]
                    let place = rails.debugCardPlaceName(at: index).map { " row=\($0)" } ?? ""
                    print("[qa] -foryou-open-card \(index): \(card.id.rawValue) kind=\(card.kind)\(place)")
                    scheduleDemoCloseIfRequested()
                    _ = rails.debugTapCard(at: index)
                }
            }
        }
        // `-foryou-open-paired K [delay]`:
        // opens the K-th half-width card of Discover, counted across blocks,
        // once it is on screen with its cover — the hero out of a paired card,
        // and with `-foryou-demo-close` the close back onto it.
        if let (raw, delay) = value(after: "-foryou-open-paired"), let ordinal = Int(raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let pairedIndex: () -> Int? = { [weak self] in
                    guard let page = self?.page else { return nil }
                    let paired = page.posts.indices.filter { page.drawsAsPairedCard(page.posts[$0].id) }
                    return paired.indices.contains(ordinal) ? paired[ordinal] : nil
                }
                QAWait.until("-foryou-open-paired \(ordinal)", { [weak self] in
                    guard let self, isAtRest(), let index = pairedIndex() else { return false }
                    let id = page.posts[index].id
                    if !page.isPostVisible(id) {
                        page.revealPost(id, clearing: UIEdgeInsets(
                            top: view.safeAreaInsets.top, left: 0, bottom: debugFloatingBarCover, right: 0
                        ))
                        return false
                    }
                    return page.heroAppearance(for: id)?.cover != nil
                }) { [weak self] in
                    guard let self, let index = pairedIndex() else { return }
                    print("[qa] -foryou-open-paired \(ordinal): flat index \(index)"
                        + " id=\(page.posts[index].id.rawValue) aspect=\(page.posts[index].aspectRatio)")
                    scheduleDemoCloseIfRequested()
                    if !page.debugSelectItem(at: index) { debugOpenFeed(at: index) }
                }
            }
        }
        if let (raw, delay) = value(after: "-foryou-push-list"),
           let kind = ForYouPostListViewController.Kind(rawValue: raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                QAWait.until("-foryou-push-list \(raw)", { [weak self] in
                    guard let self, isAtRest() else { return false }
                    return kind == .friends ? !rails.stories.isEmpty : !rails.cards.isEmpty
                }) { [weak self] in
                    guard let self else { return }
                    print("[qa] -foryou-push-list \(raw)")
                    kind == .friends ? rails.debugTapFriendsHeader() : rails.debugTapFollowingHeader()
                    scheduleListOpenIfRequested(kind)
                }
            }
        }
    }

    /// `-foryou-demo-close [delay]`: pops the feed a row opened once it has
    /// landed — the chevron's close, so the flight home is the tap-back's.
    private func scheduleDemoCloseIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-foryou-demo-close") else { return }
        let delay = position + 1 < arguments.count ? Double(arguments[position + 1]) ?? 2.5 : 2.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            QAWait.until("-foryou-demo-close", { [weak self] in
                guard let nav = self?.navigationController else { return false }
                return nav.topViewController is any ZoomTransitionDestination
                    && nav.transitionCoordinator == nil
            }) { [weak self] in
                print("[qa] -foryou-demo-close: popping the feed")
                self?.navigationController?.popViewController(animated: true)
            }
        }
    }

    /// `-foryou-list-open N`, once `-foryou-push-list` has pushed a list.
    private func scheduleListOpenIfRequested(_ kind: ForYouPostListViewController.Kind) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-foryou-list-open"),
              position + 1 < arguments.count, let index = Int(arguments[position + 1])
        else { return }
        let label = "-foryou-list-open \(index)"
        QAWait.until(label, { [weak self] in
            guard let list = kind == .friends ? self?.friendsList : self?.followingList,
                  list.navigationController?.topViewController === list,
                  list.navigationController?.transitionCoordinator == nil
            else { return false }
            return list.debugRowIsReady(at: index)
        }) { [weak self] in
            guard let list = kind == .friends ? self?.friendsList : self?.followingList else { return }
            print("[qa] \(label): opening \(list.posts[index].id.rawValue) of \(list.posts.count)")
            self?.preScrollIfRequested({ list.debugScroll(to: $0) }) { [weak self, weak list] in
                self?.scheduleDemoCloseIfRequested()
                _ = list?.debugOpenRow(at: index)
            }
        }
    }

    /// `-foryou-pushed-scroll Y`: scrolls a pushed list or the mosaic Y points
    /// into its content before `-foryou-list-open` / `-foryou-gallery-open`
    /// taps, so a return can be filmed away from the top as well as at it.
    /// Opens at once without the flag.
    private func preScrollIfRequested(_ scroll: (CGFloat) -> Void, then open: @escaping () -> Void) {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-foryou-pushed-scroll"),
              position + 1 < arguments.count,
              let offset = Double(arguments[position + 1])
        else { return open() }
        print("[qa] -foryou-pushed-scroll \(offset)")
        scroll(CGFloat(offset))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: open)
    }

    /// `-foryou-gallery-open N`, once `-foryou-view-all` has pushed the mosaic:
    /// waits for the push to land and tile N to have a cover, then taps it.
    private func scheduleGalleryOpenIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let position = arguments.firstIndex(of: "-foryou-gallery-open"),
              position + 1 < arguments.count,
              let index = Int(arguments[position + 1])
        else { return }
        let label = "-foryou-gallery-open \(index)"
        QAWait.until(label, { [weak self] in
            guard let gallery = self?.discoverGallery,
                  gallery.navigationController?.topViewController === gallery,
                  gallery.navigationController?.transitionCoordinator == nil
            else { return false }
            return gallery.debugTileIsReady(at: index)
        }) { [weak self] in
            guard let gallery = self?.discoverGallery else { return }
            print("[qa] \(label): opening \(gallery.posts[index].id.rawValue) of \(gallery.posts.count)")
            self?.preScrollIfRequested({ gallery.debugScroll(to: $0) }) { [weak self, weak gallery] in
                self?.scheduleDemoCloseIfRequested()
                _ = gallery?.debugOpenTile(at: index)
            }
        }
    }

    /// `-foryou-tab-away <seconds> [<back after seconds>]`: switch to another
    /// tab after a delay — the way to see what is still drawing or playing
    /// once the tab is left — and, with the second number, come back to For
    /// You that long after (the Friends row re-sorts across the round trip,
    /// `ForYouRailsView.releaseStoryOrder`).
    func scheduleTabAwayIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        guard !hasScheduledTabAway,
              let position = arguments.firstIndex(of: "-foryou-tab-away"),
              position + 1 < arguments.count,
              let delay = Double(arguments[position + 1])
        else { return }
        hasScheduledTabAway = true
        let back = position + 2 < arguments.count ? Double(arguments[position + 2]) : nil
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let tabs = tabBarController else { return }
            // For You's own index: it is the selected tab until this switch.
            let home = tabs.selectedIndex
            print("[zoom-live] TAB AWAY -> index 2")
            tabs.selectedIndex = 2
            guard let back else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + back) {
                print("[foryou] TAB BACK -> index \(home)")
                tabs.selectedIndex = home
            }
        }
    }
}

extension ForYouViewController: DebugItemSelectable {
    /// Taps the active page's first item through its own delegate method, so
    /// the stress harness exercises the hero rather than a router push.
    func debugSelectFirstItem() -> Bool {
        page.debugSelectItem(at: 0)
    }
}

extension ForYouViewController {
    /// The rows leading the list — their headers' own tap paths.
    var debugRails: ForYouRailsView { rails }
    /// Whether Discover's chunk tiles wear their words (`PostTileInfo`).
    var debugShowsTileInfo: Bool { page.showsTileInfo }
    /// Presses a chunk's "View all", as its footer does.
    func debugPressViewAll() { page.onViewAllTapped?() }
}
#endif
