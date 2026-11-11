import CoreModels
import FeedInterface
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The conversation's photos and videos (#681): the composer row's camera
/// and library (#2305), the media bubble in its three states, and the retry.
@MainActor
struct ConversationThreadMediaTests {
    private final class MediaDriver: ConversationThreadDriving {
        var onPhaseChange: ((ConversationThreadPhase) -> Void)?
        var onPeerChange: ((ConversationThreadPerson) -> Void)?
        var onViewerChange: ((ConversationThreadPerson) -> Void)?
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

    /// The footer's actions: stock bar items (#1679), the leading pill left out.
    private func toolbarActions(_ screen: UIViewController) -> [UIBarButtonItem] {
        (screen.toolbarItems ?? []).filter { $0.customView == nil && $0.accessibilityLabel != nil }
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

    // MARK: - The composer's row (#2305)

    /// `[avatar][field][📷][🖼][☺]`: the camera and the library are the
    /// composer's, labelled, in the row's order, and each hands its source
    /// to the driver. The footer is `[peer pill] … [pin] [⋯]` — no camera
    /// or library left on it.
    @Test func theRowOffersTheCameraAndTheLibrary() throws {
        let (screen, driver, window) = screen()
        defer { window.isHidden = true }
        let bar = screen.debugComposeBar
        let buttons = bar.debugAttachmentButtons
        #expect(buttons.map(\.accessibilityLabel) == ["Camera", "Photo Library"])
        #expect(buttons.map(\.accessibilityIdentifier) == [
            ConversationThreadViewController.cameraID, ConversationThreadViewController.libraryID,
        ])
        #expect(bar.debugShowsAttachments, "an empty field at rest hides its attachments")

        for button in buttons { button.sendActions(for: .primaryActionTriggered) }
        #expect(driver.picked == [.camera, .library])

        let items = try #require(screen.toolbarItems)
        #expect(items.first?.customView is SnapAuthorIdentityView)
        let labels = toolbarActions(screen).compactMap(\.accessibilityLabel)
        #expect(labels == ["Pin conversation", "More actions"], "the footer reads \(labels)")
    }

    /// A driver that sends text only: no attachments in the row.
    @Test func aTextOnlyThreadHasNoMediaButtons() {
        let (screen, _, window) = screen(sendsMedia: false)
        defer { window.isHidden = true }
        #expect(screen.debugComposeBar.debugAttachmentButtons.isEmpty)
        #expect(!screen.debugComposeBar.debugShowsAttachments)
        #expect(toolbarActions(screen).compactMap(\.accessibilityLabel) == ["Pin conversation", "More actions"])
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

    // MARK: - Voice messages (#2103)

    /// A voice message is its bubble (#2104), under the row: no photo
    /// bubble; a failed one of the viewer's says "Not sent. Tap to retry",
    /// and the tap sends it again.
    @Test func aFailedVoiceMessageIsItsBubbleAndRetries() throws {
        let voice = ConversationThreadMedia(
            kind: .voice, url: nil, duration: 12.4, waveform: Array(repeating: 9, count: 100),
            localFileURL: URL(fileURLWithPath: "/tmp/take.m4a")
        )
        let (screen, driver, window) = screen(messages: [Self.message("pending-1", media: voice, delivery: .failed)])
        defer { window.isHidden = true }
        let stream = try #require(Self.firstView(UICollectionView.self, in: screen.view))
        stream.layoutIfNeeded()
        let cell = try #require(stream.cellForItem(at: IndexPath(item: 0, section: 0)) as? ThreadRowCell)
        #expect(cell.mediaView.isHidden, "a voice message drew a photo bubble")
        #expect(!cell.voiceView.isHidden)
        #expect(cell.voiceView.state.delivery == .failed)
        #expect(cell.voiceView.debugTimerText == "0:12")
        cell.voiceView.onRetry?()
        #expect(driver.retried == ["pending-1"])
    }

    /// A voice message's long press: Reply and Delete — no text to copy or
    /// select, and forwarding waits (#2103).
    @Test func aVoiceMessagesMenuIsReplyAndDelete() {
        let voice = ConversationThreadMedia(kind: .voice, url: URL(string: "mock://asset/v1"), duration: 4)
        let photo = ConversationThreadMedia(kind: .image, url: URL(string: "mock://asset/p1"), aspectRatio: 1)
        let (screen, _, window) = screen(messages: [
            Self.message("v1", media: voice, mine: false), Self.message("p1", media: photo, mine: false),
        ])
        defer { window.isHidden = true }
        screen.view.layoutIfNeeded()
        #expect(screen.debugMenuTitles(for: "v1") == ["Reply", "Delete"])
        #expect(screen.debugMenuTitles(for: "p1").contains("Copy"), "the photo's menu changed")
    }

    private static func allLabels(in view: UIView) -> [UILabel] {
        var labels = view.subviews.flatMap(allLabels)
        if let label = view as? UILabel { labels.insert(label, at: 0) }
        return labels
    }

    /// #794: the picker is still closing when a photo sent offline fails,
    /// and its "You’re offline" alert used to be dropped. A notice waits
    /// for a screen on its way out, and never covers one still in use.
    ///
    /// The wait itself (the dismissal's coordinator completion) is not
    /// driven here: modal transitions never complete in the test host, so
    /// this pins the decision the alert's timing rests on.
    @Test func aNoticeWaitsForAClosingPickerAndNeverCoversAnOpenOne() {
        final class Closing: UIViewController {
            override var isBeingDismissed: Bool { true }
        }
        #expect(ConversationThreadViewController.noticeTiming(over: nil) == .now)
        #expect(ConversationThreadViewController.noticeTiming(over: Closing()) == .afterDismissal)
        #expect(ConversationThreadViewController.noticeTiming(over: UIViewController()) == .never)
    }
}
