import CoreModels
import MediaCore
import MediaPlayback
import FeedInterface
import PostGrid
import Testing
import UIKit
@testable import Feed

/// **A FEED PUSHED BEFORE ITS CORPUS ARRIVES HAS NOTHING TO DRAW, so what fills
/// the screen is whatever colour its floors were built with.**
///
/// The reveal already lends the page the tone of the card it opened from, so
/// the window opens as the thing that was tapped. But that loan is routed to
/// `activeSnapCell?`, and a cold open has no cell: `makeSnapFeedViewController`
/// seeds synchronously only when the cache answers for EVERY id, so one miss
/// pushes the feed with zero items and the write goes nowhere. What remained
/// were two literal blacks assigned at construction. Filmed from a map text
/// pin as a black flash between the marker's face and the post — on the FIRST
/// open of a pin and never on the second, because the first is what populates
/// the cache the seed reads.
///
/// ⚠️ AND RE-ROUTING THE LOAN WOULD NOT HAVE BEEN ENOUGH. The transition hands
/// the ground back — `setDestinationGround(nil)` — from INSIDE the opening
/// spring. A borrowed colour is therefore returned mid-window, so what `nil`
/// resolves to has to be right on its own; with no data there is no format to
/// derive it from. Hence a stored ground, set from the route that opened the
/// screen. `theLentGroundSurvivesTheTransitionHandingItBack` is the test that
/// separates a real fix from one that merely moves the black later.
@MainActor
struct SnapFeedEmptyGroundTests {
    private func model(_ id: String, media: URL?) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID(id), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
            avatarURL: nil, caption: "caption", mediaURL: media, mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: 0
        )
    }

    private func feed() -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: SilentFeed()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            makeCommentsPanelContent: { _ in
                let panel = UIViewController()
                panel.view.backgroundColor = .clear
                return panel
            }
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()
        return controller
    }

    private func collection(_ feed: SnapFeedViewController) -> UICollectionView? {
        feed.view.subviews.compactMap { $0 as? UICollectionView }.first
    }

    /// The premise: nothing lends a ground, nothing changes. Every route that
    /// is not a reveal is byte for byte what it was.
    @Test func anEmptyFeedIsBlackByDefault() throws {
        let feed = feed()
        #expect(feed.view.backgroundColor == .black)
        #expect(try #require(collection(feed)).backgroundColor == .black)
    }

    /// The user's frame 0: a feed with no pages wears what was tapped, on BOTH
    /// floors — they used to disagree, the pager following the format and the
    /// root view holding a literal black.
    @Test func aRevealLendsItsGroundToAFeedWithNoPages() throws {
        let feed = feed()
        feed.setEmptyGround(.secondarySystemBackground)

        #expect(feed.view.backgroundColor == .secondarySystemBackground)
        #expect(try #require(collection(feed)).backgroundColor == .secondarySystemBackground)
    }

    /// ⚠️ THE CENTRAL ONE. The tint is lent and handed back while the window is
    /// still opening; the floors must not fall to black when it is.
    @Test func theLentGroundSurvivesTheTransitionHandingItBack() throws {
        let feed = feed()
        feed.setEmptyGround(.secondarySystemBackground)

        feed.setRevealGroundTint(.secondarySystemBackground)
        feed.setRevealGroundTint(nil)

        #expect(feed.view.backgroundColor == .secondarySystemBackground)
        #expect(try #require(collection(feed)).backgroundColor == .secondarySystemBackground)
    }

    /// The inverse flash: a light window resolving to a MEDIA page must take
    /// the ground back at the first render, without waiting for a settle.
    @Test func aMediaPageTakesTheGroundBackFromTheLoan() throws {
        let feed = feed()
        feed.setEmptyGround(.secondarySystemBackground)

        feed.seedProjection([model("a", media: URL(string: "https://example.test/a.jpg"))])

        #expect(feed.view.backgroundColor == .black)
        #expect(try #require(collection(feed)).backgroundColor == .black)
    }

    /// …and a TEXT page keeps a light one, so the arrival is a tone change
    /// rather than a black frame.
    @Test func aTextPageKeepsALightGroundAcrossTheHandover() throws {
        let feed = feed()
        feed.setEmptyGround(.secondarySystemBackground)

        feed.seedProjection([model("a", media: nil)])

        #expect(feed.view.backgroundColor == .systemBackground)
        #expect(try #require(collection(feed)).backgroundColor == .systemBackground)
    }

    /// ⚠️ ONE DECISION, TWO CONSUMERS. The geometry's fill and the screen's
    /// pre-data ground are the same answer, so they are written in one place —
    /// the drift `TextRevealInstaller` exists to prevent.
    @Test func theInstallerLendsExactlyTheFillItPutsInTheGeometry() {
        let marker = TextRevealInstaller.sourceFill(
            for: TextRevealOrigin(
                rowFrame: { _ in nil }, captionEnd: nil, fill: .secondarySystemBackground
            )
        )
        #expect(marker == .secondarySystemBackground)
        // A row says nothing, and takes the card's own fill.
        let row = TextRevealInstaller.sourceFill(
            for: TextRevealOrigin(rowFrame: { _ in nil }, captionEnd: nil)
        )
        #expect(row == PostGridListRowCell.cardFillColor)
    }
}

/// A repository that answers nothing, so the screen under test is the only
/// thing deciding what is drawn.
private final class SilentFeed: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        throw FeedError.transport(message: "silent")
    }
}
