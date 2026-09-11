import CoreModels
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

        var initial: ConversationThreadPhase
        private(set) var sent: [String] = []
        private(set) var didLoad = false

        init(initial: ConversationThreadPhase) { self.initial = initial }

        func viewDidLoad() {
            didLoad = true
            onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava", avatarURL: nil))
            onPhaseChange?(initial)
        }
        func refresh() {}
        func send(_ text: String) { sent.append(text) }
        func beginReply(to messageID: String) {}
        func cancelReply() {}
        func forward(_ messageID: String) {}
        func delete(_ messageID: String) {}
        func didTapIdentity() {}
    }

    private final class FakeAccessory: ConversationThreadAccessory {
        let view: UIView = UIView()
        var onInsertText: ((String) -> Void)?
        private(set) var widths: [CGFloat] = []
        func setPreferredWidth(_ width: CGFloat) { widths.append(width) }
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

    /// The conversation's trailing slot: the post's faces, except that a draft
    /// is NEVER parked behind the mic — a shared link or an emote lands in
    /// the field to be sent, and the mic there answered with a notice.
    @Test func aDraftIsSendableWithTheKeyboardDown() throws {
        let bar = CommentsInputBar()
        bar.showsIdleUtilityFaces = true
        func button(_ label: String) -> UIButton? {
            bar.subviews.compactMap { $0 as? UIButton }.first { $0.accessibilityLabel == label }
        }
        let send = try #require(button("Send comment"))

        // Empty, keyboard down: the mic, as on the post.
        #expect(button("Record voice comment") != nil)
        #expect(send.alpha == 0)

        // A draft with the keyboard down: SEND, where the post keeps the mic.
        bar.draftText = "https://example.test/p/1"
        #expect(send.alpha == 1)
        #expect(send.isEnabled)
        #expect(send.isUserInteractionEnabled)

        // Keyboard up over the draft: still send.
        bar.setKeyboardOpen(true)
        #expect(send.alpha == 1)

        // Emptied with the keyboard up: the dismiss-keyboard face.
        bar.draftText = ""
        #expect(button("Dismiss keyboard") != nil)
        #expect(send.alpha == 0)
    }

    @Test func anEmoteGoesIntoTheDraftAndIsNotSent() throws {
        let (screen, driver, accessory, _) = makeScreen()
        let bar = try #require(Self.firstView(CommentsInputBar.self, in: screen.view))
        accessory.onInsertText?("🔥")
        #expect(bar.draftText == "🔥")
        #expect(driver.sent.isEmpty)
    }

    /// The post's footer, with the emote strip where the music would be.
    @Test func theFooterIsThePostsWithTheAccessoryLeading() throws {
        let (screen, _, accessory, _) = makeScreen()
        let items = try #require(screen.toolbarItems)
        #expect(items.first?.customView === accessory.view)
        let labels = items.compactMap(\.customView).flatMap { view -> [String] in
            if let button = view as? UIButton { return [button.accessibilityLabel].compactMap { $0 } }
            return view.subviews.compactMap { ($0 as? UIButton)?.accessibilityLabel }
        }
        #expect(labels == ["Save", "Repost", "More actions"])
    }

    @Test func aPeekHasNoComposerNoFooterAndNoMenu() throws {
        let (screen, _, _, _) = makeScreen(mode: .preview)
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        #expect(Self.firstView(CommentsInputBar.self, in: screen.view) == nil)
        #expect(screen.toolbarItems?.isEmpty ?? true)
        #expect(!stream.interactions.contains { $0 is UIContextMenuInteraction })
    }
}
