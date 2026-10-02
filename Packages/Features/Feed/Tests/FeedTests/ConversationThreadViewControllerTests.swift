import CoreModels
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
        var onSendingChange: ((Bool) -> Void)?
        var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
        var onActionNotice: ((String, String) -> Void)?
        var onPinnedChange: ((Bool?) -> Void)?

        var initial: ConversationThreadPhase
        private(set) var sent: [String] = []
        private(set) var didLoad = false
        private(set) var replies: [String] = []
        /// What the inbox would say about the pin; nil is a draft.
        var pinned: Bool? = false

        init(initial: ConversationThreadPhase) { self.initial = initial }

        func viewDidLoad() {
            didLoad = true
            onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava", avatarURL: nil))
            onPinnedChange?(pinned)
            onPhaseChange?(initial)
        }
        func refresh() {}
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

    private final class FakeAccessory: ConversationThreadAccessory {
        let view: UIView = UIView()
        var onInsertText: ((String) -> Void)?
    }

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
        phase: ConversationThreadPhase = .content(transcript)
    ) -> (ConversationThreadViewController, FakeDriver, FakeAccessory, UIWindow) {
        let driver = FakeDriver(initial: phase)
        let accessory = FakeAccessory()
        let screen = ConversationThreadViewController(
            driver: driver, mode: mode, prefill: prefill,
            accessory: mode == .full ? accessory : nil,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            wallet: nil, makeWalletSheet: nil
        )
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        screen.view.layoutIfNeeded()
        return (screen, driver, accessory, window)
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
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

    /// ⚠️ Under the header frost the system's own edge effect would still draw
    /// — a fade on iOS 26, a hard band with a hairline cutting a message in half
    /// on iOS 27 (measured). It is hidden: the frost is the only material here.
    /// See `prefersClearTopEdge`.
    @Test func theStreamRunsUnderTheHeaderWithNoSystemEffect() throws {
        let (screen, _, _, _) = makeScreen()
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        #expect(stream.topEdgeEffect.isHidden)
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
        #expect(abs(composer.field.maxY - (footerLine + SnapActionColumn.toolbarGlassDrop - SnapActionColumn.glassGap)) < 0.5,
                "the field ends at \(composer.field.maxY), not glassGap above the toolbar's glass")
        #expect(!composer.bar.debugRailButton.isHidden, "the slot is the pin")
    }

    /// ⚠️ THE GAP ON SCREEN, against the real toolbar this screen shows: the
    /// field's bottom to the ⋯ bubble's glass top — read off the glass UIKit
    /// drew (`SnapActionColumnLayoutTests.glassFrame`) — is `glassGap`, the
    /// gap UIKit leaves between neighbouring bubbles of that bar.
    @Test func theFieldStandsOneGlassGapAboveTheToolbar() async throws {
        let (screen, _, _, window) = makeScreen()
        screen.navigationController?.setToolbarHidden(false, animated: false)
        let more = try #require(screen.toolbarItems?.last?.customView)
        for _ in 0..<30 where more.window == nil || more.bounds.height == 0 {
            screen.navigationController?.view.setNeedsLayout()
            screen.navigationController?.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(more.window != nil, "the bar never hosted ⋯")
        let composer = try SnapActionColumnLayoutTests.composerColumn(in: screen.view, space: window)
        let glass = try #require(SnapActionColumnLayoutTests.glassFrame(of: more, in: window))
        let gap = glass.minY - composer.field.maxY
        #expect(abs(gap - SnapActionColumn.glassGap) < 0.5,
                "iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion): the field stands \(gap)pt above the toolbar's glass (field \(composer.field.maxY), glass \(glass))")
    }

    /// The thread shares the post's composer, so it shares the post's action
    /// column — at rest the rail slot stands exactly where
    /// the snap feed's repost bubble stands under the same footer
    /// (`SnapActionColumnLayoutTests` holds the post to it), wearing a PIN.
    /// Nothing stands at the like bubble's place.
    @Test func thePinStandsWhereTheFeedsRepostBubbleStands() throws {
        let (screen, _, _, window) = makeScreen()
        screen.view.layoutIfNeeded()
        let media = SnapActionColumnLayoutTests.mediaColumn(insets: UIEdgeInsets(
            top: screen.view.safeAreaInsets.top, left: 0,
            bottom: screen.view.safeAreaInsets.bottom, right: 0
        ))
        let composer = try SnapActionColumnLayoutTests.composerColumn(in: screen.view, space: window)

        #expect(composer.stake == nil)
        #expect(composer.rail == media.repost, "pin \(composer.rail) vs repost \(media.repost)")
        #expect(composer.bar.debugRailSymbol == "pin")
        #expect(!composer.bar.debugFieldActionButton.isHidden, "the waveform is in the field")
    }

    /// ⚠️ KEYBOARD UP, THE PIN STAYS (asked 2026-10-02). Only the input row
    /// rides the keyboard — `sm` over it, widened into the pin's width — and
    /// the pin keeps the feed's repost coordinates, under the keyboard. The
    /// stream clears the risen row, not the resting bar.
    @Test func theKeyboardLiftsTheInputRowAndLeavesThePin() throws {
        let (screen, _, _, window) = makeScreen()
        let rest = try SnapActionColumnLayoutTests.composerColumn(in: screen.view, space: window)
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        let restInset = stream.contentInset.bottom
        // No keyboard: the guide's top well below the bar. (Not the window's
        // bottom: the package test host shows no toolbar, so its footer line
        // is the window's edge and the resting row stands only 2pt above it —
        // closer than the ceiling's `sm`.)
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
        #expect(up.rail == rest.rail, "the pin moved: \(up.rail) vs \(rest.rail)")
        #expect(up.bar.debugRailSymbol == "pin")
        let keyboardTopInWindow = screen.view.convert(CGPoint(x: 0, y: keyboardTop), to: window).y
        #expect(abs(up.field.maxY - (keyboardTopInWindow - Spacing.sm)) < 0.5)
        #expect(abs(up.field.maxX - up.rail.maxX) < 0.5, "the risen field does not take the pin's width")
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

    /// The pin is the inbox's: a tap goes to the driver, and what the driver
    /// reports — from here or from the inbox — is the glyph, filled when
    /// pinned. Typing never turns it into send: the send is in the field.
    @Test func thePinPinsThroughTheDriverAndNeverTurnsIntoSend() throws {
        let (screen, driver, _, _) = makeScreen()
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        let rail = bar.debugRailButton
        #expect(rail.accessibilityLabel == "Pin conversation")

        rail.sendActions(for: .primaryActionTriggered)
        #expect(driver.pinned == true)
        #expect(bar.debugRailSymbol == "pin.fill")
        #expect(rail.accessibilityLabel == "Unpin conversation")

        bar.draftText = "On my way"
        #expect(bar.debugRailSymbol == "pin.fill", "the pin turned into \(bar.debugRailSymbol ?? "-")")
        bar.debugFieldActionButton.sendActions(for: .primaryActionTriggered)
        #expect(driver.sent == ["On my way"])
        #expect(driver.pinned == true, "a send is not a pin")
        #expect(bar.debugRailSymbol == "pin.fill")

        // Unpinned from elsewhere (the inbox's menu): the glyph follows.
        driver.onPinnedChange?(false)
        #expect(bar.debugRailSymbol == "pin")
    }

    /// A draft conversation has nothing to pin yet: the pin is drawn, quiet —
    /// and stays so over a draft, whose send is the field's.
    @Test func aDraftConversationsPinWaitsForTheConversation() throws {
        let (screen, driver, _, _) = makeScreen()
        driver.onPinnedChange?(nil)
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        #expect(bar.debugRailSymbol == "pin")
        #expect(bar.debugRailButton.isEnabled == false)
        bar.draftText = "Hi"
        #expect(bar.debugRailButton.isEnabled == false)
        #expect(bar.debugFieldActionButton.isEnabled, "send is never held back by the pin")
    }

    /// A draft is sendable with the keyboard down (a shared link or an emote
    /// lands in the field to be sent), and an empty field wears the waveform,
    /// keyboard up or down.
    @Test func aDraftIsSendableWithTheKeyboardDown() throws {
        let (screen, driver, _, _) = makeScreen()
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        let action = bar.debugFieldActionButton

        // Empty, keyboard down: the waveform.
        #expect(bar.debugFieldActionSymbol == CommentsInputBar.waveformSymbol)

        // A draft with the keyboard down: SEND.
        bar.draftText = "https://example.test/p/1"
        #expect(bar.debugFieldActionSymbol == CommentsInputBar.sendSymbol)
        #expect(action.isEnabled)

        // Keyboard up over the draft: still send.
        bar.setKeyboardOpen(true)
        #expect(bar.debugFieldActionSymbol == CommentsInputBar.sendSymbol)

        // Emptied with the keyboard up: the waveform — no dismiss-keyboard face.
        bar.draftText = ""
        #expect(bar.debugFieldActionSymbol == CommentsInputBar.waveformSymbol)
        #expect(bar.subviews.compactMap { $0 as? UIButton }.allSatisfy { $0.accessibilityLabel != "Dismiss keyboard" })

        bar.draftText = "Sent with the keyboard down"
        bar.setKeyboardOpen(false)
        action.sendActions(for: .primaryActionTriggered)
        #expect(driver.sent == ["Sent with the keyboard down"])
    }

    @Test func anEmoteGoesIntoTheDraftAndIsNotSent() throws {
        let (screen, driver, accessory, _) = makeScreen()
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        accessory.onInsertText?("🔥")
        #expect(bar.draftText == "🔥")
        #expect(driver.sent.isEmpty)
    }

    /// The post's footer, with the emote strip where the music would be — its
    /// own capsule, not one inside the bar's bubble, which pads it and cuts its
    /// content short of the visible ends — and nothing else but ⋯: a post's
    /// save and repost have nothing to act on here, and the strip takes their
    /// room. [emotes ………………][⋯].
    @Test func theFooterIsTheStripFillingUpToTheMenu() throws {
        let (screen, _, accessory, _) = makeScreen()
        let items = try #require(screen.toolbarItems)
        #expect(items.first?.customView === accessory.view)
        #expect(items.first?.hidesSharedBackground == true, "a capsule in a bubble")
        let labels = items.compactMap(\.customView).flatMap { view -> [String] in
            if let button = view as? UIButton { return [button.accessibilityLabel].compactMap { $0 } }
            return view.subviews.compactMap { ($0 as? UIButton)?.accessibilityLabel }
        }
        #expect(labels == ["More actions"])
        // [strip][fixed][⋯]: no flexible space to claim the strip's room.
        #expect(items.count == 3)
        #expect(items[1].customView == nil)
        #expect(items.last?.customView is UIButton)
    }

    @Test func aPeekHasNoComposerNoFooterAndNoMenu() throws {
        let (screen, _, _, _) = makeScreen(mode: .preview)
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        #expect(Self.firstView(CommentsInputBar.self, in: screen.view) == nil)
        #expect(screen.toolbarItems?.isEmpty ?? true)
        #expect(!stream.interactions.contains { $0 is UIContextMenuInteraction })
    }
}
