import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// The owner's second device check of the single layout (#683): the like pill
/// and the sound bubble fly in with the toolbar's ink, the record follows the
/// sound, and the field centres its line.
@MainActor
struct SnapDeviceRound2Tests {
    private typealias Layout = SnapActionColumnLayoutTests

    private static func media(_ id: String = "p1") -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "caption",
            mediaURL: URL(string: "mock://media/1"), mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 12
        )
    }

    /// ⚠️ THE CHROME CARRIES ITS OWN THEME: over media its glass is dark and
    /// its ink white from `configure`, before any window themes a cell — in a
    /// LIGHT window, which is what the hero flight's container is.
    @Test func theChromeWearsItsThemeFromConfigure() {
        let window = UIWindow(frame: Layout.screen)
        window.overrideUserInterfaceStyle = .light
        window.isHidden = false
        defer { window.isHidden = true }

        let chrome = SnapChromeView(frame: Layout.screen)
        window.addSubview(chrome)
        chrome.configure(with: Self.media())
        chrome.layoutIfNeeded()
        #expect(chrome.overrideUserInterfaceStyle == .dark)
        #expect(chrome.debugBoostButton.traitCollection.userInterfaceStyle == .dark, "the like pill flew light")
        #expect(chrome.debugSoundBubble.traitCollection.userInterfaceStyle == .dark)

        let text = SnapChromeView(frame: Layout.screen)
        text.configure(with: FeedItemDisplayModel(
            id: PostID("t"), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "words", mediaURL: nil, mediaKind: .image,
            thumbnailURL: nil, audioText: nil
        ))
        #expect(text.overrideUserInterfaceStyle == .unspecified, "a text page takes the device's theme")
    }

    /// The hero flight's replica wears the sound bubble, so it flies in with
    /// the page instead of appearing at the landing.
    @Test func theFlightReplicaWearsTheSoundBubble() throws {
        let feed = SnapFeedViewController(
            viewModel: FeedViewModel(repository: RoundTwoSilentProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        feed.loadViewIfNeeded()
        feed.view.frame = Layout.screen
        feed.seedProjection([Self.media()])
        feed.view.layoutIfNeeded()

        let replica = try #require(feed.zoomFlightChrome() as? SnapChromeView)
        replica.frame = Layout.screen
        replica.layoutIfNeeded()
        #expect(!replica.debugSoundBubble.isHidden, "the sound bubble waits for the landing")
        #expect(replica.overrideUserInterfaceStyle == .dark)
    }

    /// The record turns while asked to, and stops when asked to — the host
    /// asks for play AND sound on (#683).
    @Test func theRecordTurnsWhileTheSoundPlays() {
        guard !MotionPreference.reducesMotion else { return }
        let bubble = SnapSoundBubbleButton()
        bubble.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        bubble.setFace(SnapSoundFace(coverURL: nil, isAvailable: true, isMuted: false), pipeline: nil)
        bubble.layoutIfNeeded()
        bubble.setSpinning(true)
        #expect(bubble.debugIsSpinning)
        bubble.setSpinning(false)
        #expect(!bubble.debugIsSpinning)
        bubble.setSpinning(true)
        #expect(bubble.debugIsSpinning, "the record did not turn again")
    }

    /// ONE LINE, CENTRED: the caret's middle is the field's, within a point,
    /// and the placeholder rides the same centre.
    @Test func oneLineIsCentredInTheField() throws {
        let bar = CommentsInputBar()
        bar.onPageSwipe = { _, _, _ in }
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        host.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        host.layoutIfNeeded()

        let field = bar.debugField
        let text = try #require(Layout.firstView(UITextView.self, in: field))
        let caret = text.caretRect(for: text.beginningOfDocument)
        let caretMid = text.convert(caret, to: field).midY
        #expect(abs(caretMid - field.bounds.midY) < 1, "caret at \(caretMid), field middle \(field.bounds.midY)")
        #expect(abs(field.bounds.height - SnapActionColumn.bubbleSize) < 0.5)
    }
}

/// A repository that vends nothing: these tests are about the chrome.
private final class RoundTwoSilentProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry { throw CancellationError() }
}
