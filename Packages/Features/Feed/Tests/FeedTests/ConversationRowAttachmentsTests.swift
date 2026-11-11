import CoreModels
import DesignSystem
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// #2305: on a conversation's screen the camera and the library stand in the
/// composer's row, between the field and the own bubble, hidden while the
/// reader writes; the pin and the bell left the top bar for the footer,
/// `[peer pill] … [pin] [bell] [⋯]`, each a bubble of its own.
@MainActor
struct ConversationRowAttachmentsTests {
    private final class Driver: ConversationThreadDriving {
        var onPhaseChange: ((ConversationThreadPhase) -> Void)?
        var onPeerChange: ((ConversationThreadPerson) -> Void)?
        var onViewerChange: ((ConversationThreadPerson) -> Void)?
        var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
        var onActionNotice: ((String, String) -> Void)?
        var onPinnedChange: ((Bool?) -> Void)?
        var onMutedChange: ((Bool?) -> Void)?
        var onLoadingOlderChange: ((Bool) -> Void)?
        var onGroupChange: ((ConversationThreadGroup?) -> Void)?

        let sendsMedia: Bool
        /// Nil: a draft conversation, nothing to pin or mute yet.
        var pinned: Bool?
        var muted: Bool?
        private(set) var picked: [ConversationThreadMediaSource] = []
        private(set) var pinToggles = 0
        private(set) var mutes: [Bool] = []

        init(sendsMedia: Bool = true, pinned: Bool? = false, muted: Bool? = false) {
            self.sendsMedia = sendsMedia
            self.pinned = pinned
            self.muted = muted
        }

        func viewDidLoad() {
            onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava", avatarURL: nil))
            onPinnedChange?(pinned)
            onMutedChange?(muted)
            onPhaseChange?(.content([
                ConversationThreadMessage(
                    id: "m1", senderID: ProfileID("them"), body: "Hi", sentAt: Date(), isMine: false, quote: nil
                ),
            ]))
        }
        func refresh() {}
        func send(_ text: String) {}
        func beginReply(to messageID: String) {}
        func cancelReply() {}
        func forward(_ messageID: String) {}
        func delete(_ messageID: String) {}
        func didTapIdentity() {}
        func togglePinned() {
            pinToggles += 1
            guard let pinned else { return }
            self.pinned = !pinned
            onPinnedChange?(self.pinned)
        }
        func setMuted(_ muted: Bool, until: Date?, completion: @escaping @MainActor (Bool) -> Void) {
            mutes.append(muted)
            self.muted = muted
            onMutedChange?(muted)
            completion(true)
        }
        func pickMedia(_ source: ConversationThreadMediaSource, from presenter: UIViewController) {
            picked.append(source)
        }
    }

    private func makeScreen(
        _ driver: Driver = Driver(), mode: ConversationThreadMode = .full
    ) -> (ConversationThreadViewController, UIWindow) {
        let screen = ConversationThreadViewController(
            driver: driver, mode: mode, prefill: "", imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        screen.view.layoutIfNeeded()
        return (screen, window)
    }

    private static let step = CommentsInputBar.Metrics.controlSize + Spacing.sm

    // MARK: - The composer's row

    /// `[avatar][field][📷][🖼][☺]`: the two bubbles the own bubble's size, on
    /// the field's line, one `sm` apart — after the field, before the own
    /// bubble.
    @Test func theCameraAndTheLibraryStandBetweenTheFieldAndTheOwnBubble() throws {
        let (screen, window) = makeScreen()
        defer { window.isHidden = true }
        let bar = screen.debugComposeBar
        window.layoutIfNeeded()
        bar.layoutIfNeeded()
        let buttons = bar.debugAttachmentButtons
        try #require(buttons.count == 2)
        #expect(bar.debugShowsAttachments)
        #expect(buttons.allSatisfy { !$0.isHidden && $0.isAccessibilityElement })
        let field = bar.inputRowView.frame
        let camera = buttons[0].frame
        let library = buttons[1].frame
        let bubble = bar.debugRowActionButton.frame
        let side = CommentsInputBar.Metrics.controlSize
        #expect(abs(camera.width - side) < 0.5 && abs(camera.height - side) < 0.5)
        #expect(abs(camera.minX - (field.maxX + Spacing.sm)) < 0.5, "camera \(camera), field \(field)")
        #expect(abs(library.minX - (camera.maxX + Spacing.sm)) < 0.5, "library \(library), camera \(camera)")
        #expect(abs(bubble.minX - (library.maxX + Spacing.sm)) < 0.5, "own bubble \(bubble), library \(library)")
        #expect(abs(camera.maxY - field.maxY) < 0.5 && abs(library.maxY - field.maxY) < 0.5, "off the field's line")
        #expect(abs(bar.debugFieldTrailingInset - 3 * Self.step) < 0.5)
    }

    /// A draft hides them, keyboard down or not, and the field takes their
    /// room; the own bubble never moves. Emptied, they come back.
    @Test func aDraftHidesThemAndTheFieldTakesTheirRoom() throws {
        let (screen, window) = makeScreen()
        defer { window.isHidden = true }
        let bar = screen.debugComposeBar
        window.layoutIfNeeded()
        bar.layoutIfNeeded()
        let bubble = bar.debugRowActionButton.frame
        try #require(bar.debugShowsAttachments)

        bar.draftText = "On my way"
        bar.layoutIfNeeded()
        #expect(!bar.debugShowsAttachments, "a draft narrowed the field")
        #expect(bar.debugAttachmentButtons.allSatisfy { !$0.isAccessibilityElement }, "hidden, still VoiceOver elements")
        #expect(abs(bar.debugFieldTrailingInset - Self.step) < 0.5, "the field did not take their room")
        #expect(abs(bar.debugRowActionButton.frame.minX - bubble.minX) < 0.5, "the own bubble moved")

        bar.draftText = ""
        bar.layoutIfNeeded()
        #expect(bar.debugShowsAttachments, "an emptied field at rest did not give them back")
        #expect(bar.debugAttachmentButtons.allSatisfy { !$0.isHidden && $0.isAccessibilityElement })
        #expect(abs(bar.debugFieldTrailingInset - 3 * Self.step) < 0.5)
        #expect(abs(bar.debugRowActionButton.frame.minX - bubble.minX) < 0.5, "the own bubble moved")
    }

    /// A voice take is the row's: they go while it shows, and come back
    /// after it.
    @Test func aVoiceTakeHidesThem() {
        let (screen, window) = makeScreen()
        defer { window.isHidden = true }
        let bar = screen.debugComposeBar
        window.layoutIfNeeded()
        bar.showVoiceOverlay(VoiceRecordingStrip())
        #expect(!bar.debugShowsAttachments, "the attachments stood beside a take")
        bar.showVoiceOverlay(nil)
        #expect(bar.debugShowsAttachments)
    }

    /// Messenger's rule: shown only while the reader is not writing — not
    /// while the field is edited, nor while it holds a draft (text or a
    /// voice take), and never without sources.
    @Test func theRuleHidesThemWhileTheReaderWrites() {
        let rule = CommentsInputBar.showsAttachments
        #expect(rule(true, false, false, false))
        #expect(!rule(true, true, false, false), "shown while the field is edited")
        #expect(!rule(true, false, true, false), "shown beside a draft")
        #expect(!rule(true, false, false, true), "shown beside a voice take")
        #expect(!rule(false, false, false, false), "shown with no sources")
    }

    /// Each hands its own source to the driver, ending editing first.
    @Test func eachPicksItsSourceThroughTheDriver() {
        let driver = Driver()
        let (screen, window) = makeScreen(driver)
        defer { window.isHidden = true }
        let buttons = screen.debugComposeBar.debugAttachmentButtons
        buttons.last?.sendActions(for: .primaryActionTriggered)
        buttons.first?.sendActions(for: .primaryActionTriggered)
        #expect(driver.picked == [.library, .camera])
    }

    /// None where the footer offered none: a driver that sends no media, a
    /// channel's reader (#2215). A group the viewer posts in keeps them.
    @Test func noneForATextOnlyDriverOrAChannelsReader() {
        let (textOnly, textWindow) = makeScreen(Driver(sendsMedia: false))
        defer { textWindow.isHidden = true }
        #expect(textOnly.debugComposeBar.debugAttachmentButtons.isEmpty)

        let driver = Driver()
        let (screen, window) = makeScreen(driver)
        defer { window.isHidden = true }
        driver.onGroupChange?(ConversationThreadGroup(
            name: "Daily light", photoURL: nil, subtitle: "12 members", members: [:], isChannel: false
        ))
        #expect(screen.debugComposeBar.debugAttachmentButtons.count == 2, "a group's member lost the camera")
        driver.onGroupChange?(ConversationThreadGroup(
            name: "Daily light", photoURL: nil, subtitle: "12.4K subscribers", members: [:],
            isChannel: true, readerStanding: .subscribed
        ))
        #expect(screen.debugComposeBar.debugAttachmentButtons.isEmpty, "a channel's reader can attach")
    }

    /// A preview has no composer, so nothing to attach from.
    @Test func aPreviewHasNoAttachments() {
        let (screen, window) = makeScreen(mode: .preview)
        defer { window.isHidden = true }
        #expect(screen.toolbarItems?.isEmpty ?? true)
        #expect(!Self.contains(CommentsInputBar.self, in: screen.view))
    }

    /// The post's composer declares none: its row is unchanged. And a list
    /// given to a composer without the own bubble (a post's, with its
    /// column) never shows: the attachments are counted from that bubble.
    @Test func thePostsComposerHasNoAttachments() {
        let post = CommentsInputBar()
        #expect(post.attachmentSources.isEmpty)
        #expect(post.debugAttachmentButtons.isEmpty)
        #expect(!post.debugShowsAttachments)

        post.attachmentSources = [
            ComposerAttachmentSource(id: "test.camera", symbol: "camera", accessibilityLabel: "Camera") {},
        ]
        #expect(!post.debugShowsAttachments, "shown without the own bubble")
        post.actsFromOwnBubble = true
        #expect(post.debugShowsAttachments)
    }

    /// The same entries with new actions keep their bubbles; a tap runs the
    /// newest action.
    @Test func newActionsKeepTheBubbles() {
        let bar = CommentsInputBar()
        bar.actsFromOwnBubble = true
        let taps = Taps()
        bar.attachmentSources = [
            ComposerAttachmentSource(id: "test.camera", symbol: "camera", accessibilityLabel: "Camera") { taps.names.append("old") },
        ]
        let button = bar.debugAttachmentButtons.first
        bar.attachmentSources = [
            ComposerAttachmentSource(id: "test.camera", symbol: "camera", accessibilityLabel: "Camera") { taps.names.append("new") },
        ]
        #expect(bar.debugAttachmentButtons.first === button, "the bubble was rebuilt for a new action")
        button?.sendActions(for: .primaryActionTriggered)
        #expect(taps.names == ["new"])
    }

    // MARK: - The footer

    /// `[peer pill] … [pin] [bell] [⋯]`, each its own bubble — a separator
    /// between every two — and the top bar holds neither the pin nor the
    /// bell.
    @Test func thePinAndTheBellStandOnTheFooterEachItsOwnBubble() throws {
        let (screen, window) = makeScreen()
        defer { window.isHidden = true }
        let items = try #require(screen.toolbarItems)
        #expect(items.compactMap(\.identifier) == [
            "conversation.peer-pill", "conversation.pin", ConversationThreadViewController.bellID, SnapFooterToolbar.ID.more,
        ])
        let pin = try #require(items.firstIndex { $0.identifier == "conversation.pin" })
        let bell = try #require(items.firstIndex { $0.identifier == ConversationThreadViewController.bellID })
        let more = try #require(items.firstIndex { $0.identifier == SnapFooterToolbar.ID.more })
        // A separator — no identifier, no view — between neighbours, so the
        // bar does not join them in one platter.
        #expect(bell == pin + 2 && more == bell + 2, "\(items.map { $0.identifier ?? "·" })")
        for gap in [items[pin + 1], items[bell + 1]] {
            #expect(gap.identifier == nil && gap.customView == nil && gap.primaryAction == nil)
        }
        #expect(items[pin].image == UIImage(systemName: "pin"))
        #expect(items[bell].image == UIImage(systemName: "bell"))
        #expect(items[pin].accessibilityLabel == "Pin conversation")
        #expect(items[bell].accessibilityLabel == "Notifications")

        let top = screen.navigationItem.rightBarButtonItems ?? []
        #expect(!top.contains { $0.identifier == "conversation.pin" || $0.identifier == ConversationThreadViewController.bellID })
        #expect(screen.debugMuteItem === items[bell])
    }

    /// A draft conversation: the pin drawn, disabled; no bell until there is
    /// a conversation to mute.
    @Test func aDraftsFooterHasAQuietPinAndNoBell() throws {
        let driver = Driver(pinned: nil, muted: nil)
        let (screen, window) = makeScreen(driver)
        defer { window.isHidden = true }
        let items = try #require(screen.toolbarItems)
        #expect(items.compactMap(\.identifier) == ["conversation.peer-pill", "conversation.pin", SnapFooterToolbar.ID.more])
        #expect(screen.debugPinItem.isEnabled == false)
        #expect(screen.debugMuteItem == nil)

        driver.onPinnedChange?(false)
        driver.onMutedChange?(false)
        #expect(screen.debugPinItem.isEnabled)
        #expect(screen.debugMuteItem != nil, "the resolved conversation got no bell")
    }

    /// Pin and Mute from the footer go to the same driver actions as from
    /// the top bar; the glyphs follow — the bell's in place, one item.
    @Test func pinAndMuteFromTheFooterCallTheDriver() throws {
        let driver = Driver()
        let (screen, window) = makeScreen(driver)
        defer { window.isHidden = true }
        let items = try #require(screen.toolbarItems)
        let pin = try #require(items.first { $0.identifier == "conversation.pin" })
        let bell = try #require(items.first { $0.identifier == ConversationThreadViewController.bellID })

        pin.primaryAction?.performWithSender(nil, target: nil)
        #expect(driver.pinToggles == 1)
        #expect(pin.image == UIImage(systemName: "pin.fill"))
        #expect(pin.accessibilityLabel == "Unpin conversation")

        bell.primaryAction?.performWithSender(nil, target: nil)
        #expect(driver.mutes == [true])
        let after = try #require(screen.toolbarItems?.first { $0.identifier == ConversationThreadViewController.bellID })
        #expect(after === bell, "a new item per state")
        #expect(after.image == UIImage(systemName: "bell.slash"))
        #expect(after.accessibilityValue == "Muted")
    }

    @MainActor private final class Taps {
        var names: [String] = []
    }

    private static func contains<T: UIView>(_ type: T.Type, in view: UIView) -> Bool {
        if view is T { return true }
        return view.subviews.contains { contains(type, in: $0) }
    }
}
