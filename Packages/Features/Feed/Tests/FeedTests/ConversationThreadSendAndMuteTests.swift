import CoreModels
import FeedInterface
import Foundation
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The thread's send states and bell (#719): a text on its way is drawn
/// faded with a spinner, a failed one with a red mark that retries on a tap,
/// and the bar's bell mutes the conversation through the driver.
@MainActor
struct ConversationThreadSendAndMuteTests {
    private final class Driver: ConversationThreadDriving {
        var onPhaseChange: ((ConversationThreadPhase) -> Void)?
        var onPeerChange: ((ConversationThreadPerson) -> Void)?
        var onViewerChange: ((ConversationThreadPerson) -> Void)?
        var onSendingChange: ((Bool) -> Void)?
        var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
        var onActionNotice: ((String, String) -> Void)?
        var onPinnedChange: ((Bool?) -> Void)?
        var onMutedChange: ((Bool?) -> Void)?
        var onLoadingOlderChange: ((Bool) -> Void)?

        var initial: ConversationThreadPhase
        /// What the inbox would say about the mute; nil is a draft.
        var muted: Bool?
        private(set) var retried: [String] = []
        private(set) var replies: [String] = []

        init(initial: ConversationThreadPhase, muted: Bool?) {
            self.initial = initial
            self.muted = muted
        }

        func viewDidLoad() {
            onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava", avatarURL: nil))
            onMutedChange?(muted)
            onPhaseChange?(initial)
        }
        func refresh() {}
        func send(_ text: String) {}
        func beginReply(to messageID: String) { replies.append(messageID) }
        func cancelReply() {}
        func forward(_ messageID: String) {}
        func delete(_ messageID: String) {}
        func didTapIdentity() {}
        func togglePinned() {}
        func retry(_ messageID: String) { retried.append(messageID) }
        func toggleMuted() {
            guard let muted else { return }
            self.muted = !muted
            onMutedChange?(self.muted)
        }
    }

    private static func message(
        _ id: String, mine: Bool, minutes: Double, delivery: ConversationThreadDelivery = .sent
    ) -> ConversationThreadMessage {
        ConversationThreadMessage(
            id: id, senderID: ProfileID(mine ? "me" : "them"), body: "Message \(id)",
            sentAt: Calendar.current.startOfDay(for: Date()).addingTimeInterval(minutes * 60),
            isMine: mine, quote: nil, delivery: delivery
        )
    }

    private func makeScreen(
        phase: ConversationThreadPhase, muted: Bool? = false
    ) -> (ConversationThreadViewController, Driver, UIWindow) {
        let driver = Driver(initial: phase, muted: muted)
        let screen = ConversationThreadViewController(
            driver: driver, mode: .full, prefill: "",
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            wallet: nil, makeWalletSheet: nil
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.isHidden = false
        screen.view.layoutIfNeeded()
        return (screen, driver, window)
    }

    private func bell(_ screen: ConversationThreadViewController) -> UIBarButtonItem? {
        screen.navigationItem.rightBarButtonItems?.first { $0.accessibilityLabel == "Notifications" }
    }

    private func cells(in view: UIView) -> [ThreadRowCell] {
        if let cell = view as? ThreadRowCell { return [cell] }
        return view.subviews.flatMap { cells(in: $0) }
    }

    private func cell(_ body: String, in screen: ConversationThreadViewController) -> ThreadRowCell? {
        cells(in: screen.view).first { $0.row.bodyTextLabel.text == body }
    }

    // MARK: - The bell

    /// The bell takes the bar's trailing corner and follows the mute,
    /// wherever it was changed; a tap goes to the driver.
    @Test func theBellMutesThroughTheDriver() throws {
        let (screen, driver, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1)]))
        defer { window.isHidden = true }
        let item = try #require(bell(screen), "no bell in the bar")
        #expect(screen.navigationItem.rightBarButtonItems?.first === item, "the bell is not the trailing corner")
        #expect(item.image == UIImage(systemName: "bell"))
        #expect(item.accessibilityValue == "On")

        #expect(item.primaryAction != nil, "the bell does nothing")
        driver.toggleMuted()
        #expect(driver.muted == true)
        #expect(item.image == UIImage(systemName: "bell.slash"))
        #expect(item.accessibilityValue == "Muted")

        // Unmuted from elsewhere (the inbox's menu): the glyph follows.
        driver.onMutedChange?(false)
        #expect(item.image == UIImage(systemName: "bell"))
    }

    /// A draft has nothing to mute: no bell until there is a conversation.
    @Test func aDraftHasNoBell() {
        let (screen, driver, window) = makeScreen(phase: .content([]), muted: nil)
        defer { window.isHidden = true }
        #expect(bell(screen) == nil)
        driver.onMutedChange?(false)
        #expect(bell(screen) != nil, "the resolved conversation got no bell")
    }

    // MARK: - Sending

    /// A text on its way is faded with a spinner; delivered, plain.
    @Test func aTextOnItsWayIsFadedWithASpinner() throws {
        let sending = Self.message("p1", mine: true, minutes: 2, delivery: .sending)
        let (screen, driver, window) = makeScreen(phase: .content([Self.message("m1", mine: false, minutes: 1), sending]))
        defer { window.isHidden = true }
        let row = try #require(cell("Message p1", in: screen), "the pending text is not drawn")
        #expect(row.delivery == .sending)
        #expect(abs(row.row.alpha - ThreadRowCell.sendingAlpha) < 0.01)
        #expect(row.accessibilityValue == "Sending")

        let other = try #require(cell("Message m1", in: screen))
        #expect(other.delivery == nil, "someone else's message wears a delivery")

        driver.onPhaseChange?(.content([
            Self.message("m1", mine: false, minutes: 1),
            ConversationThreadMessage(
                id: "t1", senderID: ProfileID("me"), body: "Message p1", sentAt: sending.sentAt,
                isMine: true, quote: nil
            )
        ]))
        screen.view.layoutIfNeeded()
        let delivered = try #require(cell("Message p1", in: screen))
        #expect(delivered.delivery == nil)
        #expect(cells(in: screen.view).filter { $0.row.bodyTextLabel.text == "Message p1" }.count == 1)
    }

    /// A failed text says so, and a tap sends it again rather than answering it.
    @Test func aFailedTextRetriesOnATap() throws {
        let (screen, driver, window) = makeScreen(phase: .content([
            Self.message("p1", mine: true, minutes: 2, delivery: .failed)
        ]))
        defer { window.isHidden = true }
        let row = try #require(cell("Message p1", in: screen))
        #expect(row.delivery == .failed)
        #expect(row.row.alpha == 1)
        row.row.onReplyTap?()
        #expect(driver.retried == ["p1"])
        #expect(driver.replies.isEmpty, "a failed message was answered instead of retried")
    }
}
