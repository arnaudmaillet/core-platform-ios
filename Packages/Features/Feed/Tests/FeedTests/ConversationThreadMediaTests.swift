import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The conversation's photos and videos (#681): the footer's camera and
/// library, the media bubble in its three states, and the retry.
@MainActor
struct ConversationThreadMediaTests {
    private final class MediaDriver: ConversationThreadDriving {
        var onPhaseChange: ((ConversationThreadPhase) -> Void)?
        var onPeerChange: ((ConversationThreadPerson) -> Void)?
        var onViewerChange: ((ConversationThreadPerson) -> Void)?
        var onSendingChange: ((Bool) -> Void)?
        var onReplyStateChange: ((ConversationThreadReplyDraft?) -> Void)?
        var onActionNotice: ((String, String) -> Void)?
        var onPinnedChange: ((Bool?) -> Void)?
        var onLoadingOlderChange: ((Bool) -> Void)?

        let sendsMedia: Bool
        let messages: [ConversationThreadMessage]
        private(set) var picked: [ConversationThreadMediaSource] = []
        private(set) var retried: [String] = []

        init(sendsMedia: Bool, messages: [ConversationThreadMessage]) {
            self.sendsMedia = sendsMedia
            self.messages = messages
        }

        func viewDidLoad() {
            onPeerChange?(ConversationThreadPerson(id: ProfileID("them"), name: "Ava", avatarURL: nil))
            onPhaseChange?(.content(messages))
        }
        func refresh() {}
        func send(_ text: String) {}
        func beginReply(to messageID: String) {}
        func cancelReply() {}
        func forward(_ messageID: String) {}
        func delete(_ messageID: String) {}
        func didTapIdentity() {}
        func togglePinned() {}
        func pickMedia(_ source: ConversationThreadMediaSource, from presenter: UIViewController) { picked.append(source) }
        func retry(_ messageID: String) { retried.append(messageID) }
    }

    private static let picture = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
        UIColor.systemTeal.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    }

    private static func message(
        _ id: String, media: ConversationThreadMedia?, delivery: ConversationThreadDelivery = .sent, mine: Bool = true
    ) -> ConversationThreadMessage {
        ConversationThreadMessage(
            id: id, senderID: ProfileID(mine ? "me" : "them"), body: "", sentAt: Date(),
            isMine: mine, quote: nil, media: media, delivery: delivery
        )
    }

    private func screen(sendsMedia: Bool = true, messages: [ConversationThreadMessage] = [])
        -> (ConversationThreadViewController, MediaDriver, UIWindow) {
        let driver = MediaDriver(sendsMedia: sendsMedia, messages: messages)
        let screen = ConversationThreadViewController(
            driver: driver, mode: .full, prefill: "",
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        let navigation = UINavigationController(rootViewController: screen)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = navigation
        window.isHidden = false
        screen.view.layoutIfNeeded()
        return (screen, driver, window)
    }

    private func toolbarButtons(_ screen: UIViewController) -> [UIButton] {
        (screen.toolbarItems ?? []).compactMap(\.customView).flatMap { view -> [UIButton] in
            if let button = view as? UIButton { return [button] }
            if let stack = view as? UIStackView { return stack.arrangedSubviews.compactMap { $0 as? UIButton } }
            return []
        }
    }

    private func mediaView(_ screen: UIViewController, item: Int = 0) throws -> ThreadMediaView {
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        stream.layoutIfNeeded()
        let cell = try #require(stream.cellForItem(at: IndexPath(item: item, section: 0)) as? ThreadRowCell)
        cell.layoutIfNeeded()
        return cell.mediaView
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = firstView(type, in: subview) { return match }
        }
        return nil
    }

    // MARK: - The footer

    /// `[peer pill] … [📷 🖼] [⋯]`, labelled, and each hands its source to
    /// the driver.
    @Test func theFooterOffersTheCameraAndTheLibrary() throws {
        let (screen, driver, window) = screen()
        defer { window.isHidden = true }
        let items = try #require(screen.toolbarItems)
        #expect(items.first?.customView is SnapAuthorIdentityView)
        let labels = toolbarButtons(screen).compactMap(\.accessibilityLabel)
        #expect(labels == ["Camera", "Photo Library", "More actions"], "the footer reads \(labels)")

        let buttons = toolbarButtons(screen)
        buttons[0].sendActions(for: .primaryActionTriggered)
        buttons[1].sendActions(for: .primaryActionTriggered)
        #expect(driver.picked == [.camera, .library])
    }

    /// A driver that sends text only keeps the bare footer.
    @Test func aTextOnlyThreadHasNoMediaButtons() {
        let (screen, _, window) = screen(sendsMedia: false)
        defer { window.isHidden = true }
        #expect(toolbarButtons(screen).compactMap(\.accessibilityLabel) == ["More actions"])
    }

    // MARK: - The bubble

    /// A received photo: drawn at its shape, 240 points wide at most, and a
    /// tap opens it full screen.
    @Test func aPhotoIsDrawnAtItsShape() throws {
        let photo = ConversationThreadMedia(kind: .image, url: URL(string: "mock://photo/x"), aspectRatio: 4.0 / 3.0)
        let (screen, _, window) = screen(messages: [Self.message("m1", media: photo, mine: false)])
        defer { window.isHidden = true }
        let view = try mediaView(screen)
        #expect(!view.isHidden)
        #expect(abs(view.debugFrameSize.width - ThreadMediaView.maxWidth) < 0.5)
        #expect(abs(view.debugFrameSize.height - ThreadMediaView.maxWidth * 3 / 4) < 0.5)
        #expect(!view.debugShowsPlay)
        #expect(view.accessibilityLabel == "Photo")
    }

    /// A video wears its play glyph and its length.
    @Test func aVideoWearsPlayAndItsLength() throws {
        let clip = ConversationThreadMedia(kind: .video, url: URL(string: "mock://asset/c"), aspectRatio: 9.0 / 16.0, duration: 12.4)
        let (screen, _, window) = screen(messages: [Self.message("m1", media: clip)])
        defer { window.isHidden = true }
        let view = try mediaView(screen)
        #expect(view.debugShowsPlay)
        // Clamped to 3:4 — a tall clip does not take the screen.
        #expect(abs(view.debugFrameSize.height - ThreadMediaView.maxWidth / 0.75) < 0.5)
        #expect(ThreadMediaView.durationText(12.4) == "0:12")
    }

    /// ⚠️ ON ITS WAY: the picture picked, dimmed under a spinner.
    @Test func aSendingPhotoWearsThePictureUnderASpinner() throws {
        let pending = ConversationThreadMedia(kind: .image, url: nil, preview: Self.picture, aspectRatio: 4.0 / 3.0)
        let (screen, driver, window) = screen(messages: [Self.message("pending-1", media: pending, delivery: .sending)])
        defer { window.isHidden = true }
        let view = try mediaView(screen)
        #expect(view.image === Self.picture)
        #expect(view.debugIsSpinning)
        #expect(!view.debugShowsFailure)
        view.onTap?()
        #expect(driver.retried.isEmpty, "a sending photo was sent again")
    }

    /// ⚠️ FAILED: it says so, and a tap sends it again.
    @Test func aFailedPhotoSaysSoAndRetriesOnATap() throws {
        let failed = ConversationThreadMedia(kind: .image, url: nil, preview: Self.picture, aspectRatio: 1)
        let (screen, driver, window) = screen(messages: [Self.message("pending-1", media: failed, delivery: .failed)])
        defer { window.isHidden = true }
        let view = try mediaView(screen)
        #expect(view.debugShowsFailure)
        #expect(!view.debugIsSpinning)
        #expect(view.accessibilityLabel == "Photo, not sent")
        view.onTap?()
        #expect(driver.retried == ["pending-1"])
    }
}
