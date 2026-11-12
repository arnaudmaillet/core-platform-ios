import CoreModels
import CoreStorage
import DesignSystem
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The conversation drawn as a text post's screen, driven
/// by a fake: what it lists, how it groups, what the composer and the footer
/// are wired to, and what a peek leaves out.
@MainActor
struct ConversationThreadViewControllerTests {
    private final class FakeDriver: ConversationThreadDriving {
        var onPhaseChange: ((ConversationThreadPhase) -> Void)?
        var onPeerChange: ((ConversationThreadPerson) -> Void)?
        var onViewerChange: ((ConversationThreadPerson) -> Void)?
        var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
        var onActionNotice: ((String, String) -> Void)?
        var onPinnedChange: ((Bool?) -> Void)?
        var onLoadingOlderChange: ((Bool) -> Void)?

        var initial: ConversationThreadPhase
        private(set) var sent: [String] = []
        private(set) var didLoad = false
        private(set) var replies: [String] = []
        /// What the inbox would say about the pin; nil is a draft.
        var pinned: Bool? = false
        /// Where the thread remembers its shape; nil keeps none.
        var presenceKey: String?

        init(initial: ConversationThreadPhase) { self.initial = initial }

        func viewDidLoad() {
            didLoad = true
            onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava", avatarURL: nil))
            onPinnedChange?(pinned)
            onPhaseChange?(initial)
        }
        private(set) var refreshes = 0
        func refresh() { refreshes += 1 }
        func send(_ text: String) { sent.append(text) }
        func beginReply(to messageID: String) { replies.append(messageID) }
        func cancelReply() {}
        func forward(_ messageID: String) {}
        func delete(_ messageID: String) {}
        func didTapIdentity() {}
        func togglePinned() {
            guard let pinned else { return }
            self.pinned = !pinned
            onPinnedChange?(self.pinned)
        }
    }

    /// Kept as the fixture's fourth member so every destructuring stays put;
    /// the thread has no footer accessory since #680.
    private final class FakeAccessory {}

    /// `minutes` past the START of today — anchored to the calendar day, not
    /// to now, so the fixture's days are the same at 00:10 and at 23:50 (an
    /// "half an hour ago" message falls on yesterday just after midnight).
    private static func message(_ id: String, daysBack: Int, minutes: Double, mine: Bool) -> ConversationThreadMessage {
        let calendar = Calendar.current
        let day = calendar.date(byAdding: .day, value: -daysBack, to: calendar.startOfDay(for: Date()))!
        return ConversationThreadMessage(
            id: id, senderID: ProfileID(mine ? "me" : "them"), body: "Message \(id)",
            sentAt: day.addingTimeInterval(minutes * 60), isMine: mine, quote: nil
        )
    }

    /// A voice message of the viewer's shows its send beside "You", as a
    /// text does — its bubble keeps its play button (the owner,
    /// 2026-11-07); its failure is its bubble's own. A photo shows it on its
    /// picture.
    @Test func aVoiceMessageSendsBesideTheName() {
        func message(_ media: ConversationThreadMedia?, _ delivery: ConversationThreadDelivery, mine: Bool = true)
            -> ConversationThreadMessage {
            ConversationThreadMessage(
                id: "v", senderID: ProfileID("me"), body: "", sentAt: Date(), isMine: mine, quote: nil,
                media: media, delivery: delivery
            )
        }
        let voice = ConversationThreadMedia(kind: .voice, url: nil, duration: 4)
        let photo = ConversationThreadMedia(kind: .image, url: nil)
        typealias Screen = ConversationThreadViewController
        #expect(Screen.deliveryBesideName(of: message(voice, .sending)) == .sending)
        #expect(Screen.deliveryBesideName(of: message(voice, .failed)) == nil)
        #expect(Screen.deliveryBesideName(of: message(nil, .failed)) == .failed)
        #expect(Screen.deliveryBesideName(of: message(photo, .sending)) == nil)
        #expect(Screen.deliveryBesideName(of: message(voice, .sending, mine: false)) == nil)
        // The delivered copy of a voice take is the same send: its spinner
        // hands over to the time.
        #expect(Screen.isSameSend(message(voice, .sending), message(ConversationThreadMedia(kind: .voice, url: nil, duration: 4.2), .sent)))
        #expect(!Screen.isSameSend(message(voice, .sending), message(nil, .sent)))
        #expect(!Screen.isSameSend(message(voice, .sending), message(ConversationThreadMedia(kind: .voice, url: nil, duration: 9), .sent)))
    }

    /// Oldest first: two in the evening two days ago, two early today.
    private static let transcript = [
        message("m1", daysBack: 2, minutes: 20 * 60, mine: false),
        message("m2", daysBack: 2, minutes: 20 * 60 + 30, mine: true),
        message("m3", daysBack: 0, minutes: 1, mine: false),
        message("m4", daysBack: 0, minutes: 2, mine: true),
    ]

    private func makeScreen(
        mode: ConversationThreadMode = .full,
        prefill: String = "",
        phase: ConversationThreadPhase = .content(transcript),
        now: Date? = nil,
        skeletonClock: LoadingClock? = nil,
        presence: SectionPresenceStore? = nil,
        presenceKey: String? = nil,
        anchorsShortStream: Bool = false
    ) -> (ConversationThreadViewController, FakeDriver, FakeAccessory, UIWindow) {
        let driver = FakeDriver(initial: phase)
        driver.presenceKey = presenceKey
        let accessory = FakeAccessory()
        let screen = ConversationThreadViewController(
            driver: driver, mode: mode, prefill: prefill,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        // One "now" for the seed and the titles: a run crossing midnight
        // read the clock on either side of it.
        if let now { screen.dayClock = { now } }
        if let skeletonClock { screen.skeletonClock = skeletonClock }
        if let presence { screen.presence = presence }
        screen.anchorsShortStream = anchorsShortStream
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        // ⚠️ NOT THE SYSTEM KEYBOARD. Its guide is app-wide: a suite running
        // alongside that focuses a field (on CI, with no hardware keyboard)
        // lifted this field by the keyboard's height, and the slack, the
        // clearance and the toolbar gap with it — the same numbers on every
        // starved run (#2392). The composer rests on a keyboard parked below
        // the screen; the keyboard tests move one of their own
        // (`SnapActionColumnLayoutTests.fakeKeyboard`).
        // A screen with no composer on show (a reader's channel, say) has
        // nothing to park.
        if screen.debugComposeBar.isDescendant(of: screen.view) {
            _ = SnapActionColumnLayoutTests.fakeKeyboard(
                in: screen.view, for: screen.debugComposeBar,
                top: max(screen.view.bounds.height, window.bounds.height) + 100
            )
        }
        screen.view.layoutIfNeeded()
        return (screen, driver, accessory, window)
    }

    /// ⚠️ ON THE CONDITION, NOT A FIXED SLEEP (#2092). The bar's day lands
    /// a turn after `shown` — later still behind a transition — and a
    /// starved runner lost a 50 ms sleep: wait for it.
    private static func settleDay(_ screen: ConversationThreadViewController, inBar: Bool) async -> Bool {
        await settle { screen.debugDayItem.inBar == inBar }
    }

    /// ⚠️ IN ITS WINDOW, ITS APPEARANCE OVER (#2092). Out of a window the
    /// day is placed at once, unanimated: the navigation controller installs
    /// the screen at the window's first layout, laid out here rather than
    /// left to a later turn. During the appearance the day's placement waits
    /// for its end, which a starved runner stretched.
    private static func settleOnScreen(_ screen: ConversationThreadViewController, in window: UIWindow) async -> Bool {
        window.layoutIfNeeded()
        return await settle { screen.view.window != nil && screen.transitionCoordinator == nil }
    }

    /// What a day wait that gave up found.
    private static func dayDiagnostic(_ screen: ConversationThreadViewController) -> String {
        "\(screen.debugDayPlacement), holds tail: \(screen.debugHoldsTail), offset: \(screen.debugStreamOffset)"
    }

    /// ⚠️ LOOKS, NOT A WALL-CLOCK DEADLINE: a starved main thread can spend
    /// a deadline's seconds with no look at all (the runs #2092 failed took
    /// 240–255 s). 6,000 looks is about a minute on a free main actor.
    private static func settle(looks: Int = 6_000, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    /// ⚠️ A FAILED FIRST LOAD HAS A WAY OUT (#797). It said "Pull to retry"
    /// on a screen with no pull; it now offers Try Again, which reloads.
    @Test func aFailedFirstLoadOffersTryAgain() throws {
        let (screen, driver, _, window) = makeScreen(phase: .failed("Couldn't load this conversation"))
        defer { window.isHidden = true }
        let status = try #require(Self.firstView(EmptyStateView.self, in: screen.view))
        #expect(!status.isHidden, "the failure was not shown")
        let button = try #require(Self.firstView(UIButton.self, in: status))
        #expect(!button.isHidden)
        #expect(button.configuration?.title == "Try Again")

        button.sendActions(for: .primaryActionTriggered)

        #expect(driver.refreshes == 1)
    }

    /// The first load's skeleton on the kit's timing (#1770): nothing for
    /// the delay, the bones after it, and after 10 s "Taking longer than
    /// usual" with Try Again, which loads again.
    @Test func theFirstLoadsBonesFollowTheGate() throws {
        let time = ManualLoadingClock()
        let (screen, driver, _, window) = makeScreen(phase: .loading, skeletonClock: time.clock)
        defer { window.isHidden = true }
        #expect(screen.debugSkeletonRowCount == 0, "bones before the delay")
        time.advance(LoadingTiming.skeletonDelay)
        #expect(screen.debugSkeletonRowCount > 0)

        time.advance(LoadingTiming.takingLonger)
        #expect(screen.debugSkeletonRowCount == 0)
        let status = try #require(Self.firstView(EmptyStateView.self, in: screen.view))
        #expect(!status.isHidden)
        #expect(status.debugTitle == TakingLongerCopy.title)
        status.debugTapAction()
        #expect(driver.refreshes == 1)
        #expect(status.isHidden, "Try Again keeps the status up")
    }

    /// The cold skeleton is the thread's last-known shape (#1774): as many
    /// message rows as it had (up to the fold), the day chip's bone over
    /// them, a picture's bone where it had pictures — and nothing at all for
    /// a thread that was empty.
    @Test func theSkeletonIsTheThreadsLastKnownShape() throws {
        let presence = SectionPresenceStore(defaults: try #require(UserDefaults(suiteName: "thread-\(UUID().uuidString)")))
        presence.remember(2, screen: "thread.c1", section: "messages")
        presence.remember(1, screen: "thread.c1", section: "media")
        let time = ManualLoadingClock()
        let (screen, _, _, window) = makeScreen(
            phase: .loading, skeletonClock: time.clock, presence: presence, presenceKey: "thread.c1"
        )
        defer { window.isHidden = true }
        time.advance(LoadingTiming.skeletonDelay)
        #expect(screen.debugSkeletonRowCount == 2)
        #expect(screen.debugShowsSkeletonDay)

        presence.remember(0, screen: "thread.c2", section: "messages")
        let (empty, _, _, emptyWindow) = makeScreen(
            phase: .loading, skeletonClock: time.clock, presence: presence, presenceKey: "thread.c2"
        )
        defer { emptyWindow.isHidden = true }
        time.advance(LoadingTiming.skeletonDelay)
        #expect(empty.debugSkeletonRowCount == 0, "bones for a thread that was empty")
    }

    @Test func messagesAreGroupedByDayOldestFirst() throws {
        let (screen, driver, _, _) = makeScreen()
        #expect(driver.didLoad)
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        #expect(stream.numberOfSections == 2)
        #expect(stream.numberOfItems(inSection: 0) == 2)
        #expect(stream.numberOfItems(inSection: 1) == 2)
        #expect(stream.cellForItem(at: IndexPath(item: 0, section: 0)) is ThreadRowCell)
    }

    /// Older history on its way shows at the top of the thread, and only
    /// while it is on its way (#600); a peek, which pages nothing, never shows it.
    @Test func olderHistoryOnItsWayShowsAtTheTop() {
        let (screen, driver, _, window) = makeScreen()
        #expect(!screen.isShowingOlderSpinner)

        driver.onLoadingOlderChange?(true)
        #expect(screen.isShowingOlderSpinner)
        driver.onLoadingOlderChange?(false)
        #expect(!screen.isShowingOlderSpinner)

        let (peek, peekDriver, _, peekWindow) = makeScreen(mode: .preview)
        peekDriver.onLoadingOlderChange?(true)
        #expect(!peek.isShowingOlderSpinner)
        _ = (window, peekWindow)
    }

    /// ⚠️ NO BLUR UNDER THE HEADER (#750, the owner's call 2026-10-09, back
    /// from #741): as on every other screen, only the window's status-bar
    /// blur is up there — the stream clears its own top edge.
    @Test func theHeaderHasNoBlurOfItsOwn() throws {
        let (screen, _, _, _) = makeScreen()
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        #expect(stream.topEdgeEffect.isHidden, "a blur under the header")
    }

    /// ⚠️ THE DAY IS A BAR ITEM LEFT OF THE BELL (#750), and the flow keeps
    /// its own day chips, NOT sticky (#755). The item says the day of the
    /// last chip gone under the header — none at the conversation's start.
    /// A tap scrolls to that day's chip. Each day is its own item under its
    /// own identifier, so a change of day morphs.
    @Test func theDayIsABarItemLeftOfTheBell() async throws {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let messages = (0..<60).map { index -> ConversationThreadMessage in
            let day = index < 30 ? yesterday : today
            return ConversationThreadMessage(
                id: "m\(index)", senderID: ProfileID(index.isMultiple(of: 2) ? "me" : "them"),
                body: "Message \(index)", sentAt: day.addingTimeInterval(Double(index % 30) * 60),
                isMine: index.isMultiple(of: 2), quote: nil
            )
        }
        let (screen, _, _, window) = makeScreen(phase: .content(messages), now: now)
        defer { window.isHidden = true }
        screen.view.layoutIfNeeded()
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))

        // At the tail: today, as a bar item.
        let tail = screen.debugDayItem
        #expect(tail.shown, "no day in the bar")
        #expect(tail.title == "Today")
        #expect(tail.item.identifier == ConversationThreadViewController.dayItemID(today))

        // Yesterday's chip scrolled away with its day: not sticky.
        let visibleTop = stream.contentOffset.y + stream.adjustedContentInset.top
        let yesterdayChip = try #require(stream.layoutAttributesForSupplementaryElement(
            ofKind: DayPillHeaderView.elementKind, at: IndexPath(item: 0, section: 0)
        ))
        #expect(yesterdayChip.frame.maxY < visibleTop, "the chip pinned to the top: \(yesterdayChip.frame)")

        // A tap lands today's chip just below the bar.
        screen.debugTapDayItem()
        stream.setContentOffset(stream.contentOffset, animated: false)
        stream.layoutIfNeeded()
        let todayChip = try #require(stream.layoutAttributesForSupplementaryElement(
            ofKind: DayPillHeaderView.elementKind, at: IndexPath(item: 0, section: 1)
        ))
        let landed = stream.convert(todayChip.frame, to: screen.view).minY - screen.view.safeAreaInsets.top
        #expect(abs(landed - ConversationThreadViewController.dayStartLanding) < 2, "today's chip landed at \(landed)")

        // Yesterday's chip under the header, today's still below: yesterday
        // — a new item, a new identifier: the bar morphs, never retitles.
        let barBottom = stream.convert(CGPoint(x: 0, y: screen.view.safeAreaInsets.top), from: screen.view).y
            - stream.contentOffset.y
        stream.setContentOffset(CGPoint(x: 0, y: yesterdayChip.frame.maxY + 40 - barBottom), animated: false)
        stream.layoutIfNeeded()
        screen.scrollViewDidScroll(stream)
        let middle = screen.debugDayItem
        #expect(middle.shown)
        #expect(middle.title == "Yesterday")
        #expect(middle.item !== tail.item, "the day was retitled in place: no morph")
        #expect(middle.item.identifier == ConversationThreadViewController.dayItemID(yesterday))
        #expect(middle.item.identifier != tail.item.identifier)
        // ⚠️ In the bar a turn later (#756): placed from inside a diffable
        // apply, it lost UIKit's appearance transition and morph.
        #expect(await Self.settleDay(screen, inBar: true), "the day never reached the bar: \(Self.dayDiagnostic(screen))")
        // Right of the back button (the owner, 2026-11-07).
        #expect(screen.navigationItem.leftBarButtonItems?.first === middle.item, "the day is not right of the back button")
        #expect(screen.navigationItem.leftItemsSupplementBackButton, "the day took the back button's place")
        #expect(!(screen.navigationItem.leftBarButtonItems ?? []).contains { $0 === tail.item }, "both days in the bar")

        // At the start of the conversation no chip has gone under: no item.
        stream.setContentOffset(CGPoint(x: 0, y: -stream.adjustedContentInset.top), animated: false)
        stream.layoutIfNeeded()
        screen.scrollViewDidScroll(stream)
        #expect(!screen.debugDayItem.shown, "a day in the bar before any chip went under the header")
    }

    /// ⚠️ ONE PLACEMENT PER TURN (#756). Opening on a long thread, the
    /// tail pin's passes showed the day and changed it in one turn; two
    /// `setRightBarButtonItems` back to back cut the first one's appearance
    /// short, and the item popped in on the device.
    @Test func theDayAppearsInOnePlacementEvenWhenItChangesInTheSameTurn() async throws {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let messages = (0..<60).map { index -> ConversationThreadMessage in
            ConversationThreadMessage(
                id: "m\(index)", senderID: ProfileID(index.isMultiple(of: 2) ? "me" : "them"),
                body: "Message \(index)",
                sentAt: (index < 30 ? yesterday : today).addingTimeInterval(Double(index % 30) * 60),
                isMine: index.isMultiple(of: 2), quote: nil
            )
        }
        let (screen, _, _, window) = makeScreen(phase: .content(messages), now: now)
        defer { window.isHidden = true }
        screen.view.layoutIfNeeded()
        try #require(await Self.settleOnScreen(screen, in: window), "the screen never arrived: \(Self.dayDiagnostic(screen))")
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))

        // The start: no day. The reader's own scroll, begun as a finger
        // begins it: until then the stream holds its tail for the arrival
        // (until a turn after `viewDidAppear`, seconds late in a busy suite),
        // and the rows sizing at the top took the scroll back down to today —
        // the day never left the bar (#2092).
        screen.scrollViewWillBeginDragging(stream)
        stream.setContentOffset(CGPoint(x: 0, y: -stream.adjustedContentInset.top), animated: false)
        screen.scrollViewDidScroll(stream)
        #expect(await Self.settleDay(screen, inBar: false), "the day never left the bar: \(Self.dayDiagnostic(screen))")
        let before = screen.debugAnimatedBarPlacements

        // One turn: yesterday's chip under the header, then the tail.
        let chip = try #require(stream.layoutAttributesForSupplementaryElement(
            ofKind: DayPillHeaderView.elementKind, at: IndexPath(item: 0, section: 0)
        ))
        stream.setContentOffset(CGPoint(x: 0, y: chip.frame.maxY + 40 - screen.view.safeAreaInsets.top), animated: false)
        screen.scrollViewDidScroll(stream)
        #expect(screen.debugDayItem.title == "Yesterday", "guard: the day showed mid-turn")
        // The tail as it is now: rows sized at the top since the open.
        let insets = stream.adjustedContentInset
        let tail = max(-insets.top, stream.contentSize.height + insets.bottom - stream.bounds.height)
        stream.setContentOffset(CGPoint(x: 0, y: tail), animated: false)
        screen.scrollViewDidScroll(stream)
        #expect(screen.debugDayItem.title == "Today")
        #expect(await Self.settleDay(screen, inBar: true), "the day never reached the bar: \(Self.dayDiagnostic(screen))")

        #expect(screen.debugAnimatedBarPlacements - before == 1, "the appearance was placed again and cut short")
        let days = screen.navigationItem.leftBarButtonItems?.filter { $0.identifier?.hasPrefix("conversation.day.") == true }
        #expect(days?.count == 1)
    }

    /// ⚠️ NO FROSTED TOP (asked 2026-10-02). The thread drew its own 132pt
    /// frost band under the window's status-bar blur — a blur over a blur.
    /// The only band left on the screen is the composer's footer, below the
    /// middle; a peek has none at all at the top either.
    @Test func theThreadHasNoFrostedTop() throws {
        for mode in [ConversationThreadMode.full, .preview] {
            let (screen, _, _, _) = makeScreen(mode: mode)
            screen.view.layoutIfNeeded()
            // The bands, not the day pills' chips (blur too, pinned up there
            // by design).
            let bands = Self.descendants(of: screen.view).filter { $0 is ProgressiveFrostView }
            for band in bands {
                let frame = band.convert(band.bounds, to: screen.view)
                #expect(frame.minY > screen.view.bounds.midY,
                        "\(mode): a \(type(of: band)) at the top \(frame)")
            }
            #expect(bands.count == (mode == .full ? 1 : 0), "\(mode): \(bands.map { type(of: $0) })")
        }
    }

    /// The send arrow is the post's tint (`CommentsInputBar.sendTint`), not
    /// the conversation's inherited tint.
    @Test func theSendArrowIsThePostsBlue() throws {
        let (screen, _, _, _) = makeScreen()
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        bar.draftText = "On my way"
        #expect(bar.debugOwnBubbleSymbol == CommentsInputBar.sendSymbol)
        let color = bar.debugRowActionButton.configuration?.baseForegroundColor
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            #expect(color?.resolvedColor(with: traits) == CommentsInputBar.sendTint.resolvedColor(with: traits))
        }
    }

    /// ⚠️ A LINE BREAK MOVES THE THREAD IN ONE ANIMATION. The field grows, the
    /// bar with it, the footer band riding the input row and the stream's
    /// clearance and offset (`syncBottomClearance`) all land in the same
    /// spring — and on the way back down. The pin never moves.
    @Test func aLineBreakMovesTheStreamInTheFieldsAnimation() throws {
        let long = (0..<60).map { index in
            Self.message("m\(index)", daysBack: 0, minutes: Double(index), mine: index.isMultiple(of: 3))
        }
        let (screen, _, _, window) = makeScreen(phase: .content(long))
        // ON SCREEN: off a window the field takes its height at once (there
        // is nothing to watch), and the navigation controller installs the
        // screen's view in the window on its own layout pass.
        window.layoutIfNeeded()
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        try #require(bar.window === window, "guard: the composer is not on screen")
        let band = try #require(Self.descendants(of: screen.view).first { $0 is ProgressiveFrostView })
        let pin = bar.debugRailButton.convert(bar.debugRailButton.bounds, to: window)
        Self.removeAllAnimations(in: window)
        let inset = stream.contentInset.bottom

        bar.draftText = "One\nTwo\nThree\nFour"
        #expect(stream.contentInset.bottom > inset + 20, "guard: the grown bar moved the clearance")
        #expect(Self.isAnimated(bar.debugField), "the field jumped")
        #expect(Self.isAnimated(stream), "the stream jumped while the field grew")
        #expect(Self.isAnimated(band), "the footer band jumped while the field grew")
        let pinNow = bar.debugRailButton.convert(bar.debugRailButton.bounds, to: window)
        #expect(abs(pinNow.minY - pin.minY) < 0.5, "the pin moved: \(pinNow) vs \(pin)")

        Self.removeAllAnimations(in: window)
        bar.draftText = ""
        #expect(abs(stream.contentInset.bottom - inset) < 0.5)
        #expect(Self.isAnimated(bar.debugField), "the field snapped back")
        #expect(Self.isAnimated(stream), "the stream snapped back")
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }

    private static func removeAllAnimations(in view: UIView) {
        view.layer.removeAllAnimations()
        for subview in view.subviews { removeAllAnimations(in: subview) }
    }

    private static func isAnimated(_ view: UIView) -> Bool {
        !(view.layer.animationKeys() ?? []).isEmpty
    }

    /// ⚠️ **ON THE TAIL IN THE SAME TURN, NOT ONE TURN LATER.** Estimated row
    /// heights refine as the tail realises, so a single pass lands short; the
    /// correction used to be a second pass a run-loop turn later — after the
    /// short frame had been committed, and with nothing left to retry when that
    /// pass refined the heights again. Read synchronously, with no hop allowed.
    @Test func aLongTranscriptOpensExactlyOnItsNewestMessage() throws {
        let long = (0..<80).map { index in
            Self.message("m\(index)", daysBack: 0, minutes: Double(index),
                         mine: index.isMultiple(of: 3))
        }
        let (screen, _, _, _) = makeScreen(phase: .content(long))
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))

        let tail = stream.contentSize.height + stream.adjustedContentInset.bottom - stream.bounds.height
        #expect(stream.contentSize.height > stream.bounds.height * 2, "guard: the transcript scrolls")
        #expect(abs(stream.contentOffset.y - tail) < 1,
                "opened \(Int(tail - stream.contentOffset.y))pt short of the newest message")
        let newest = IndexPath(item: long.count - 1, section: 0)
        #expect(stream.indexPathsForVisibleItems.contains(newest), "the newest message is not on screen")
    }

    // MARK: - #1799: a short transcript starts from the bottom

    /// Where the stream's content ends on screen, and where the composer's
    /// clearance begins: the two meet when the transcript rests at its tail.
    private static func contentBottomAndClearance(_ stream: UICollectionView) -> (content: CGFloat, clearance: CGFloat) {
        (stream.contentSize.height - stream.contentOffset.y,
         stream.bounds.height - stream.adjustedContentInset.bottom)
    }

    /// The experiment on: four messages rest just above the composer, the
    /// room above them worn in the top inset.
    @Test func aShortTranscriptRestsAboveTheComposer() throws {
        let (screen, _, _, window) = makeScreen(anchorsShortStream: true)
        window.layoutIfNeeded()
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))

        #expect(screen.bottomAnchorSlack > 100, "a four-message transcript wears no slack: \(screen.bottomAnchorSlack)")
        let edges = Self.contentBottomAndClearance(stream)
        #expect(abs(edges.content - edges.clearance) < 1, "the transcript ends at \(edges.content), the composer at \(edges.clearance)")
        #expect(abs(stream.contentInset.top - (SnapCommentsLayout.streamTopBreath + screen.bottomAnchorSlack)) < 0.5)
        #expect(abs(stream.contentOffset.y + stream.adjustedContentInset.top) < 1, "a short transcript scrolled")
    }

    /// The experiment off: the same transcript is top-aligned, as before.
    @Test func withoutTheExperimentAShortTranscriptHangsFromTheTop() throws {
        let (screen, _, _, window) = makeScreen()
        window.layoutIfNeeded()
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))

        #expect(screen.bottomAnchorSlack == 0)
        #expect(abs(stream.contentInset.top - SnapCommentsLayout.streamTopBreath) < 0.5)
        let edges = Self.contentBottomAndClearance(stream)
        #expect(edges.content < edges.clearance - 100, "guard: the transcript is short")
    }

    /// A transcript taller than the stream has no slack: exactly as before,
    /// on its newest message.
    @Test func aLongTranscriptWearsNoSlack() throws {
        let long = (0..<80).map { index in
            Self.message("m\(index)", daysBack: 0, minutes: Double(index), mine: index.isMultiple(of: 3))
        }
        let (screen, _, _, _) = makeScreen(phase: .content(long), anchorsShortStream: true)
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))

        #expect(screen.bottomAnchorSlack == 0)
        #expect(abs(stream.contentInset.top - SnapCommentsLayout.streamTopBreath) < 0.5)
        let tail = stream.contentSize.height + stream.adjustedContentInset.bottom - stream.bounds.height
        #expect(abs(stream.contentOffset.y - tail) < 1)
    }

    /// The keyboard up: the composer's travel is the slack's — the short
    /// transcript rises with it, still resting just above it — and settles
    /// back when the keyboard goes.
    @Test func aShortTranscriptRisesWithTheKeyboard() throws {
        let (screen, _, _, window) = makeScreen(anchorsShortStream: true)
        window.layoutIfNeeded()
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        let rest = try SnapActionColumnLayoutTests.composerColumn(in: screen.view, space: window)
        let keyboard = SnapActionColumnLayoutTests.fakeKeyboard(
            in: screen.view, for: rest.bar, top: screen.view.bounds.height + 100
        )
        screen.view.layoutIfNeeded()
        let restSlack = screen.bottomAnchorSlack
        let restClearance = stream.contentInset.bottom

        keyboard.constant = screen.view.bounds.height - 336
        screen.view.setNeedsLayout()
        screen.view.layoutIfNeeded()
        let travel = stream.contentInset.bottom - restClearance
        #expect(travel > 200, "guard: the keyboard moved the clearance")
        #expect(abs(screen.bottomAnchorSlack - (restSlack - travel)) < 1,
                "the slack did not absorb the travel: \(restSlack) → \(screen.bottomAnchorSlack), travel \(travel)")
        var edges = Self.contentBottomAndClearance(stream)
        #expect(abs(edges.content - edges.clearance) < 1, "the transcript did not rise with the composer")

        keyboard.constant = screen.view.bounds.height + 100
        screen.view.setNeedsLayout()
        screen.view.layoutIfNeeded()
        #expect(abs(screen.bottomAnchorSlack - restSlack) < 1)
        edges = Self.contentBottomAndClearance(stream)
        #expect(abs(edges.content - edges.clearance) < 1, "the transcript did not settle back")
    }

    /// The empty page is full height and centred: never anchored.
    @Test func anEmptyConversationWearsNoSlack() throws {
        let (screen, _, _, window) = makeScreen(phase: .content([]), anchorsShortStream: true)
        window.layoutIfNeeded()
        #expect(screen.bottomAnchorSlack == 0)
    }

    @Test func theSlackIsTheRoomLeftAboveTheContent() {
        #expect(StreamBottomAnchor.slack(viewport: 600, contentHeight: 200) == 400)
        #expect(StreamBottomAnchor.slack(viewport: 600, contentHeight: 600) == 0)
        #expect(StreamBottomAnchor.slack(viewport: 600, contentHeight: 900) == 0)
    }

    @Test func anEmptyConversationIsThePostsEmptyPage() throws {
        let (screen, _, _, _) = makeScreen(phase: .content([]))
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        #expect(stream.numberOfSections == 1)
        #expect(stream.cellForItem(at: IndexPath(item: 0, section: 0)) is CommentsEmptyPageCell)
    }

    @Test func theComposerIsThePostsAndSendsThroughTheDriver() throws {
        let (screen, driver, _, _) = makeScreen(prefill: "https://example.test/p/1")
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        #expect(bar.draftText == "https://example.test/p/1", "a shared link lands in the draft")
        bar.onSend?("On my way")
        #expect(driver.sent == ["On my way"])
    }

    /// A tap on a message answers it while the keyboard is down. (With the
    /// keyboard up the same tap only retires it — `retireKeyboardOr`. That half
    /// needs a real first responder, which the package test host, having no
    /// window scene, cannot give; it is verified on the simulator.)
    @Test func aRowTapWithTheKeyboardDownAnswersTheMessage() throws {
        let (screen, driver, _, _) = makeScreen()
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        let cell = try #require(stream.cellForItem(at: IndexPath(item: 0, section: 0)) as? ThreadRowCell)
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        #expect(!bar.isEditingDraft)

        cell.row.onReplyTap?()
        #expect(driver.replies == ["m1"])
    }

    /// A conversation has nothing to like: no stake bubble over the pin. The
    /// field rests on the toolbar, `glassGap` above its glass.
    @Test func theComposerHasNoStakeAndItsFieldRestsOnTheToolbar() throws {
        let (screen, _, _, window) = makeScreen()
        let composer = try SnapActionColumnLayoutTests.composerColumn(in: screen.view, space: window)
        #expect(composer.stake == nil, "a like bubble over a conversation's pin")
        #expect(SnapActionColumnLayoutTests.button(composer.bar, "Boost post")?.isHidden == true)
        let footerLine = screen.view.convert(
            CGPoint(x: 0, y: screen.view.bounds.height - screen.view.safeAreaInsets.bottom), to: window
        ).y
        #expect(abs(composer.field.maxY - (footerLine + SnapActionColumn.toolbarGlassDrop - SnapActionColumn.glassGap - SnapActionColumn.bottomBreath)) < 0.5,
                "the field ends at \(composer.field.maxY), not glassGap above the toolbar's glass")
        #expect(composer.bar.debugRailButton.isHidden, "no column slot: the row's own bubble acts")
        #expect(composer.bar.debugShowsRowAction)
    }

    /// ⚠️ THE GAP ON SCREEN, against the real toolbar this screen shows: the
    /// field's bottom to the ⋯ bubble's glass top — read off the glass UIKit
    /// drew (`SnapActionColumnLayoutTests.glassFrame`) — is `glassGap`, the
    /// gap UIKit leaves between neighbouring bubbles of that bar.
    @Test func theFieldStandsOneGlassGapAboveTheToolbar() async throws {
        let (screen, _, _, window) = makeScreen()
        screen.navigationController?.setToolbarHidden(false, animated: false)
        // ⋯ is a stock item (#1679): its view is UIKit's.
        var hosted: UIView?
        for _ in 0..<30 where hosted == nil || hosted?.bounds.height == 0 {
            screen.navigationController?.view.setNeedsLayout()
            screen.navigationController?.view.layoutIfNeeded()
            hosted = screen.toolbarItems?.last.flatMap(SnapActionColumnLayoutTests.hostedView(of:))
            if hosted == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let more = try #require(hosted, "the bar never hosted ⋯")
        let composer = try SnapActionColumnLayoutTests.composerColumn(in: screen.view, space: window)
        let glass = try #require(SnapActionColumnLayoutTests.glassFrame(of: more, in: window))
        let gap = glass.minY - composer.field.maxY
        // `glassGap`, and the breath every composer stands on (#1722).
        #expect(abs(gap - SnapActionColumn.glassGap - SnapActionColumn.bottomBreath) < 0.5,
                "iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion): the field stands \(gap)pt above the toolbar's glass (field \(composer.field.maxY), glass \(glass))")
    }

    /// The composer's own bubble ends the input row, the field's height,
    /// right of the field — the emote button over an empty field, the send
    /// over a draft (#2308: every host's).
    @Test func theOwnBubbleEndsTheInputRow() throws {
        let (screen, _, _, window) = makeScreen()
        screen.view.layoutIfNeeded()
        let composer = try SnapActionColumnLayoutTests.composerColumn(in: screen.view, space: window)
        let bubble = composer.bar.debugRowActionButton.convert(composer.bar.debugRowActionButton.bounds, to: window)
        #expect(composer.stake == nil)
        #expect(abs(bubble.maxY - composer.field.maxY) < 0.5, "\(bubble) vs field \(composer.field)")
        #expect(bubble.minX >= composer.field.maxX, "the bubble overlaps the field")
        #expect(composer.bar.debugRowActionButton.accessibilityLabel == "Emotes")
        #expect(composer.bar.debugOwnBubbleSymbol == CommentsInputBar.emoteSymbol)
    }

    /// Keyboard up, the input row rides it — the field and its own bubble,
    /// `sm` over it — and the stream clears the risen row, not the resting
    /// bar.
    @Test func theKeyboardLiftsTheInputRowAndItsBubble() throws {
        let (screen, _, _, window) = makeScreen()
        let rest = try SnapActionColumnLayoutTests.composerColumn(in: screen.view, space: window)
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        let restInset = stream.contentInset.bottom
        let keyboard = SnapActionColumnLayoutTests.fakeKeyboard(
            in: screen.view, for: rest.bar, top: screen.view.bounds.height + 100
        )
        screen.view.layoutIfNeeded()
        let settled = try SnapActionColumnLayoutTests.composerColumn(in: screen.view, space: window)
        #expect(settled.field == rest.field, "no keyboard moved the field: \(settled.field) vs \(rest.field)")

        let keyboardTop = screen.view.bounds.height - 336
        keyboard.constant = keyboardTop
        screen.view.setNeedsLayout()
        screen.view.layoutIfNeeded()
        let up = try SnapActionColumnLayoutTests.composerColumn(in: screen.view, space: window)
        let keyboardTopInWindow = screen.view.convert(CGPoint(x: 0, y: keyboardTop), to: window).y
        #expect(abs(up.field.maxY - (keyboardTopInWindow - Spacing.sm)) < 0.5)
        let bubble = up.bar.debugRowActionButton.convert(up.bar.debugRowActionButton.bounds, to: window)
        #expect(abs(bubble.maxY - up.field.maxY) < 0.5, "the bubble stayed under the keyboard: \(bubble)")
        #expect(bubble.minX >= up.field.maxX)
        #expect(stream.contentInset.bottom > restInset + 200,
                "the stream clears the resting bar (\(stream.contentInset.bottom)), not the risen row")
    }

    /// A conversation is live: no pull-to-refresh, no loader over the thread.
    @Test func theThreadHasNoPullToRefresh() throws {
        let (screen, _, _, _) = makeScreen()
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        #expect(stream.refreshControl == nil)
        #expect(Self.firstView(UIRefreshControl.self, in: screen.view) == nil)
        let (preview, _, _, _) = makeScreen(mode: .preview)
        #expect(Self.firstView(UIRefreshControl.self, in: preview.view) == nil)
    }

    /// The pin is the inbox's, on the footer (#2305): a tap goes to the
    /// driver, and what the driver reports — from here or from the inbox —
    /// is the glyph, filled when pinned. The bubble's send is never a pin.
    @Test func thePinPinsThroughTheDriverFromTheBar() throws {
        let (screen, driver, _, _) = makeScreen()
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        let pin = screen.debugPinItem
        #expect(pin.accessibilityLabel == "Pin conversation")
        #expect(pin.image == UIImage(systemName: "pin"))

        // Through the footer item's own action.
        pin.primaryAction?.performWithSender(nil, target: nil)
        #expect(driver.pinned == true)
        #expect(pin.accessibilityLabel == "Unpin conversation")
        #expect(pin.image == UIImage(systemName: "pin.fill"))
        #expect(screen.toolbarItems?.first { $0.identifier == "conversation.pin" } === pin, "the pin left the footer")

        bar.draftText = "On my way"
        bar.debugRowActionButton.sendActions(for: .primaryActionTriggered)
        #expect(driver.sent == ["On my way"])
        #expect(driver.pinned == true, "a send is not a pin")

        // Unpinned from elsewhere (the inbox's menu): the glyph follows.
        driver.onPinnedChange?(false)
        #expect(pin.accessibilityLabel == "Pin conversation")
    }

    /// A draft conversation has nothing to pin yet: the pin is drawn, quiet;
    /// the send never waits on it.
    @Test func aDraftConversationsPinWaitsForTheConversation() throws {
        let (screen, driver, _, _) = makeScreen()
        driver.onPinnedChange?(nil)
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        #expect(screen.debugPinItem.isEnabled == false)
        bar.draftText = "Hi"
        #expect(bar.debugRowActionButton.isEnabled, "send is never held back by the pin")
    }

    /// A draft is sendable with the keyboard down (a shared link or an emote
    /// lands in the field to be sent), and an empty field's own bubble is the
    /// emote button, keyboard up or down.
    @Test func aDraftIsSendableWithTheKeyboardDown() throws {
        let (screen, driver, _, _) = makeScreen()
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        let action = bar.debugRowActionButton

        // Empty, keyboard down: the emote button.
        #expect(bar.debugOwnBubbleSymbol == CommentsInputBar.emoteSymbol)

        // A draft with the keyboard down: SEND.
        bar.draftText = "https://example.test/p/1"
        #expect(bar.debugOwnBubbleSymbol == CommentsInputBar.sendSymbol)
        #expect(action.isEnabled)

        // Keyboard up over the draft: still send.
        bar.setKeyboardOpen(true)
        #expect(bar.debugOwnBubbleSymbol == CommentsInputBar.sendSymbol)

        // Emptied with the keyboard up: the emote button — no dismiss-keyboard face.
        bar.draftText = ""
        #expect(bar.debugOwnBubbleSymbol == CommentsInputBar.emoteSymbol)
        #expect(bar.subviews.compactMap { $0 as? UIButton }.allSatisfy { $0.accessibilityLabel != "Dismiss keyboard" })

        bar.draftText = "Sent with the keyboard down"
        bar.setKeyboardOpen(false)
        action.sendActions(for: .primaryActionTriggered)
        #expect(driver.sent == ["Sent with the keyboard down"])
    }

    /// ⚠️ NO SPINNER IN THE FIELD (#886): the sent message's own bubble says
    /// it is on its way, so the composer is ready for the next one the
    /// moment a text leaves — emptied, wearing the emote button, never busy.
    @Test func theComposerIsReadyTheMomentATextLeaves() throws {
        let (screen, driver, _, _) = makeScreen()
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        let action = bar.debugRowActionButton

        bar.draftText = "One"
        action.sendActions(for: .primaryActionTriggered)
        #expect(bar.draftText.isEmpty)
        #expect(bar.isSending == false, "the composer waits on the send")
        #expect(action.configuration?.showsActivityIndicator == false, "a spinner in the bubble")
        #expect(bar.debugOwnBubbleSymbol == CommentsInputBar.emoteSymbol)
        #expect(action.isEnabled)

        bar.draftText = "Two"
        #expect(action.configuration?.showsActivityIndicator == false)
        action.sendActions(for: .primaryActionTriggered)
        #expect(driver.sent == ["One", "Two"], "the next text was held back")
    }

    /// The footer: [peer pill] … [pin] [⋯] (#671, the layout since #680; the
    /// pin since #2305) — no emote strip (the composer's emote button is the
    /// way to emotes), and no peer pill, pin or bell left in the nav bar.
    @Test func thePeerPillLeadsTheFooter() throws {
        let (screen, _, _, _) = makeScreen()
        let items = try #require(screen.toolbarItems)
        #expect(items.first?.customView is SnapAuthorIdentityView)
        #expect(items.last?.accessibilityLabel == "More actions")
        #expect(items.last?.customView == nil, "⋯ is not a stock bar item")
        #expect(items.contains { $0 === screen.debugPinItem }, "the pin is not on the footer")
        let nav = screen.navigationItem.rightBarButtonItems ?? []
        #expect(!nav.contains { $0.customView is SnapAuthorIdentityView }, "the peer pill is still in the nav bar")
        #expect(!nav.contains { $0 === screen.debugPinItem }, "the pin is still on the top bar")
        #expect(nav.isEmpty, "the top bar's trailing side holds \(nav.compactMap(\.identifier))")
    }

    @Test func aPeekHasNoComposerNoFooterAndNoMenu() throws {
        let (screen, _, _, _) = makeScreen(mode: .preview)
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        #expect(Self.firstView(CommentsInputBar.self, in: screen.view) == nil)
        #expect(screen.toolbarItems?.isEmpty ?? true)
        #expect(!stream.interactions.contains { $0 is UIContextMenuInteraction })
    }

    // MARK: - #1929: scrolled away, the way back floats over the composer

    private static let longTranscript = (0..<80).map { index in
        message("long\(index)", daysBack: 0, minutes: Double(index), mine: index.isMultiple(of: 2))
    }

    /// The reader scrolls more than a screen up: the way back floats over the
    /// composer (the owner, 2026-11-07, Telegram's); a tap goes back to the
    /// newest message, and it goes.
    @Test func scrolledAwayTheWayBackFloatsOverTheComposer() async throws {
        let (screen, _, _, window) = makeScreen(phase: .content(Self.longTranscript))
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let bottom = screen.debugBottomOffset
        try #require(bottom > 1500, "the premise: a transcript several screens long")
        #expect(!screen.debugShowsReturnButton)

        // A programmatic move (a quote jump) never shows it.
        screen.debugScroll(to: bottom - 1200, userScroll: false)
        #expect(!screen.debugShowsReturn)
        // The reader's own scroll does.
        screen.debugScroll(to: bottom - 1200, userScroll: true)
        #expect(screen.debugShowsReturn)
        #expect(screen.debugShowsReturnButton)

        let away = screen.debugStreamOffset
        screen.debugTapReturn()
        // On the outcome, not a fixed second: the animated scroll moves on
        // display ticks, which a starved CI host hands out late (#2173's
        // run: still at `away` after the second, the test 389 s long).
        let deadline = ContinuousClock.now + .seconds(20)
        while screen.debugStreamOffset <= away, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            screen.debugStreamOffset > away,
            """
            the tap did not head for the newest message: offset \(screen.debugStreamOffset), away \(away), \
            bottom then \(bottom), now \(screen.debugBottomOffset), way back shown \(screen.debugShowsReturnButton), \
            window key \(window.isKeyWindow)
            """
        )
        // Arriving there — as the animation's scroll callbacks report it.
        screen.debugScroll(to: bottom, userScroll: false)
        #expect(!screen.debugShowsReturn, "back at the newest message, the way back stayed")
    }

    /// A voice take in the field's place: the lock rises over the held
    /// bubble, where the way back floats — it gives the column up, and takes
    /// it back once the take is gone. Apart from the tap's test: the take's
    /// strip re-lays the composer, and the tap after it never scrolled on
    /// CI's iOS 26 (#2173).
    @Test func theWayBackGivesTheLockItsColumn() throws {
        let (screen, _, _, window) = makeScreen(phase: .content(Self.longTranscript))
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        let bottom = screen.debugBottomOffset
        try #require(bottom > 1500, "the premise: a transcript several screens long")
        screen.debugComposeBar.showVoiceOverlay(VoiceRecordingStrip())
        window.layoutIfNeeded()
        screen.debugScroll(to: bottom - 1200, userScroll: true)
        try #require(screen.debugShowsReturn, "the premise: scrolled away")
        #expect(!screen.debugShowsReturnButton, "the way back stood over the lock's column")
        screen.debugComposeBar.showVoiceOverlay(nil)
        #expect(screen.debugShowsReturnButton, "the way back did not come back after the take")
        window.layoutIfNeeded()
        // Back at the newest message, and away again mid-fade: it shows.
        screen.debugScroll(to: bottom, userScroll: false)
        #expect(!screen.debugShowsReturn)
        screen.debugScroll(to: bottom - 1200, userScroll: true)
        // The model value: where the fade now heads.
        #expect(screen.debugShowsReturnButton && screen.debugReturnButtonAlpha > 0.99,
                "shown again mid-fade, the way back stayed invisible")
    }

    /// The composer has no column (#2308: the conversation's contract): its
    /// own bubble is the emote button and the send, and the pin is the
    /// footer's (#2305).
    @Test func theComposersOwnBubbleAndThePinInTheBar() throws {
        let (screen, driver, _, window) = makeScreen(phase: .content(Self.longTranscript))
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        #expect(screen.debugRailFace == .noSlot)
        #expect(screen.debugComposeBar.configuration.column == .none)
        #expect(screen.debugComposeBar.debugShowsRowAction)
        #expect(screen.toolbarItems?.contains { $0 === screen.debugPinItem } == true)
        #expect(screen.navigationItem.rightBarButtonItems?.contains { $0 === screen.debugPinItem } != true)
        #expect(screen.debugPinItem.isEnabled)
        screen.debugTapPin()
        #expect(driver.pinned == true, "the footer's pin did not pin the conversation")
    }

}
