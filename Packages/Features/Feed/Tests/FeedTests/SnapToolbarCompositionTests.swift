import CoreModels
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// **What the footer offers, and what the ⋯ folds up.**
///
/// The bar and its menu are one decision, so they are stated together: three
/// glyphs of equal weight say those three things are equally common, and
/// anything demoted into the menu says it is not. The composition IS the
/// product decision, which is why it is pinned rather than left to whoever
/// edits the builder next.
///
/// ```
///  [♫ attribution] ———————————————— [🔖 ⇄] [⋯]
///                                            ├ Share
///                                            ├ Not interested
///                                            └ Report            (destructive)
/// ```
///
/// ⚠️ Asserted through the ITEMS, not through a screenshot: a bar item's
/// custom view is where this composition actually lives, and a picture of it
/// cannot say which action a glyph carries.
@MainActor
struct SnapToolbarCompositionTests {
    private func feed(reporting: (any ContentReporting)? = StubReporter()) -> SnapFeedViewController {
        let controller = SnapFeedViewController(
            viewModel: FeedViewModel(repository: EmptyProvider()),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            reporting: reporting
        )
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.seedProjection([
            FeedItemDisplayModel(
                id: PostID("p1"), authorID: ProfileID("a"), authorName: "Ava", metaText: "",
                avatarURL: nil, caption: "caption",
                mediaURL: URL(string: "https://example.test/a.jpg"), mediaKind: .image,
                thumbnailURL: nil, audioText: nil, likeCount: 0
            )
        ])
        controller.view.layoutIfNeeded()
        return controller
    }

    /// Every button the toolbar draws, in bar order.
    private func toolbarButtons(_ feed: SnapFeedViewController) -> [UIButton] {
        (feed.toolbarItems ?? [])
            .compactMap(\.customView)
            .flatMap { view -> [UIButton] in
                if let button = view as? UIButton { return [button] }
                return view.subviews.compactMap { $0 as? UIButton }
            }
    }

    /// ⚠️ BY LABEL, not by glyph. There is no public way to ask a `UIImage`
    /// which SF Symbol it is, and the label is the better question anyway: it
    /// is what a reader using VoiceOver is offered, so a bar whose composition
    /// is right but whose labels are missing should not pass.
    private func labels(_ buttons: [UIButton]) -> [String] {
        buttons.compactMap(\.accessibilityLabel)
    }

    // MARK: - The bar

    /// ⚠️ SAVE AND REPOST, in that order, and nothing else beside the ⋯.
    ///
    /// Share used to hold the middle slot. It moved into the menu: saving and
    /// passing on are the two things a reader does WITH a post, and share is
    /// something they do to it once in a while.
    @Test func theTrailingRunIsSaveRepostAndTheMenu() {
        let buttons = toolbarButtons(feed())

        #expect(labels(buttons) == ["Save", "Repost", "More actions"],
                "the trailing run is not [save, repost, ⋯]: \(labels(buttons))")
    }

    /// Share is GONE from the bar — not hidden, not disabled.
    @Test func theBarNoLongerCarriesShare() {
        #expect(labels(toolbarButtons(feed())).contains("Share") == false)
    }

    /// The attribution keeps the leading end, with the dynamic space between:
    /// the audio credit is about the post, the actions are about what you do
    /// with it, and the gap is what says so.
    @Test func theAudioCreditKeepsTheLeadingEnd() throws {
        let items = try #require(feed().toolbarItems)

        #expect(items.first?.customView is SnapMediaAttributionView)
        // The spaces are system items with no custom view of their own — which
        // is exactly how a space reads from out here.
        let space = try #require(items.dropFirst().first)
        #expect(space.customView == nil, "no dynamic space after the credit")
        // ⚠️ FIVE, because ⋯ HAS ITS OWN BUBBLE: [credit][flex][actions]
        // [fixed][⋯]. iOS 26 fuses adjacent bar items into one platter, so the
        // fixed space between the last two IS the separation — see
        // `theMenuStandsInItsOwnPlatter`.
        #expect(items.count == 5, "the bar is [credit][flex][actions][fixed][⋯]: \(items.count)")
    }

    /// ⚠️ THE ⋯ STANDS APART, in a platter of its own.
    ///
    /// The capsule holds what you DO to this post — save it, pass it on — and
    /// ⋯ holds what is folded away; a shared platter said the three were three
    /// of a kind. The separation is a fixed space, because iOS 26 groups
    /// ADJACENT items into one platter and a spacer is the only way to make
    /// two.
    @Test func theMenuStandsInItsOwnPlatter() throws {
        let items = try #require(feed().toolbarItems)

        let actions = try #require(items.dropFirst(2).first?.customView as? UIStackView)
        #expect(actions.arrangedSubviews.count == 2, "the capsule is not [save, repost]")
        #expect(items.dropFirst(3).first?.customView == nil, "no separator before the ⋯")
        let more = try #require(items.last?.customView as? UIButton)
        #expect(more.accessibilityLabel == "More actions")
    }

    // MARK: - The menu

    /// ⚠️ NOT NAVIGATION. "View comments" and "View profile" are gone: both
    /// were second doors to places one tap already opens (the comment count,
    /// the author pill), and a menu of things you can reach anyway crowds out
    /// the things that have nowhere else to live.
    @Test func theMenuOffersShareNotInterestedAndReport() {
        let titles = feed().debugMoreMenuTitles(for: PostID("p1"))

        #expect(titles == ["Share", "Not interested", "Report"], "the menu reads: \(titles)")
    }

    /// Report is destructive and LAST — the gallery card's own menu ordering.
    @Test func reportIsTheDestructiveRowAtTheEnd() throws {
        let actions = feed().debugMoreMenuActions(for: PostID("p1"))

        let report = try #require(actions.last as? UIAction)
        #expect(report.title == "Report")
        #expect(report.attributes.contains(.destructive))
    }

    /// ⚠️ WITHHELD, NOT DISABLED. With nobody to file a report with, the row
    /// is absent — an action that cannot act is not offered. The other two
    /// stand: neither needs a backend.
    @Test func theReportRowIsAbsentWithoutSomewhereToFileIt() {
        let titles = feed(reporting: nil).debugMoreMenuTitles(for: PostID("p1"))

        #expect(titles == ["Share", "Not interested"])
    }
}

/// Accepts every report, so a test can assert the row EXISTS without asserting
/// anything about what filing one does.
private final class StubReporter: ContentReporting, @unchecked Sendable {
    func report(_ subject: ReportSubject, reason: ReportReason, surface: String) async throws {}
}

private final class EmptyProvider: FeedProviding, @unchecked Sendable {
    func cachedFirstPage() async -> [FeedEntry]? { nil }
    func loadFirstPage() async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPage(afterToken token: String) async throws -> FeedPage {
        FeedPage(entries: [], nextPageToken: nil, isCold: false)
    }
    func loadPost(_ id: PostID) async throws -> FeedEntry {
        FeedEntry(
            post: Post(
                id: id, authorID: ProfileID("p"), caption: "",
                attachments: [], publishedAt: Date(timeIntervalSince1970: 0)
            ),
            author: AuthorSummary(
                id: ProfileID("p"), handle: "ava", displayName: "Ava", avatarURL: nil
            ),
            likeCount: 0
        )
    }
}
