import CoreModels
import MediaCore
import MediaPlayback
import Testing
import UIKit
@testable import Feed

/// **What the footer offers, and what the ⋯ folds up.**
///
/// The bar and its menu are one decision, so they are stated together: what
/// the capsule holds says what is common, and anything demoted into the menu
/// says it is not. The composition IS the product decision, which is why it
/// is pinned rather than left to whoever edits the builder next.
///
/// ```
///  [author pill] ——————————————— [🔖 ⇄] [⋯]
///                                         ├ Share
///                                         ├ Not interested
///                                         └ Report            (destructive)
/// ```
///
/// (#671, the layout since #680: the author pill leads, where the audio
/// capsule was; the sound is a bubble on the page.)
///
/// ⚠️ Asserted through the ITEMS, not through a screenshot: a picture
/// cannot say which action a glyph carries. Every action is a STOCK bar item
/// with an identifier (#1679, `dev/BAR_CONTRACT.md`) — the bar draws them.
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

    /// Every action the toolbar draws, in bar order — hidden items draw
    /// nothing, spaces are not actions, and the author pill is a container.
    private func toolbarActions(_ feed: SnapFeedViewController) -> [UIBarButtonItem] {
        (feed.toolbarItems ?? []).filter { !$0.isHidden && $0.customView == nil && $0.accessibilityLabel != nil }
    }

    /// ⚠️ BY LABEL, not by glyph: the label is what a reader using VoiceOver
    /// is offered, so a bar whose composition is right but whose labels are
    /// missing should not pass.
    private func labels(_ items: [UIBarButtonItem]) -> [String] {
        items.compactMap(\.accessibilityLabel)
    }

    // MARK: - The bar

    /// ⚠️ SAVE AND REPOST, in that order (#865), and nothing else beside the
    /// ⋯. Share moved into the menu.
    @Test func theTrailingRunIsSaveRepostAndTheMenu() {
        let actions = toolbarActions(feed())
        #expect(labels(actions) == ["Save", "Repost", "More actions"],
                "the trailing run is not [save, repost, ⋯]: \(labels(actions))")
        #expect(actions.map(\.identifier) == [
            SnapFooterToolbar.ID.save, SnapFooterToolbar.ID.repost, SnapFooterToolbar.ID.more,
        ], "an action lost its identity")
    }

    /// Save then repost, SIDE BY SIDE — two stock items with nothing between,
    /// which the bar puts in one platter (#865, #1679) — the order VoiceOver
    /// walks and the text post composer's footer draws too.
    @Test func saveLeadsRepostInsideTheCapsule() throws {
        let items = try #require(feed().toolbarItems)
        let pair = Array(items.dropFirst(2).prefix(2))
        #expect(pair.map(\.accessibilityLabel) == ["Save", "Repost"], "the capsule reads \(pair.map(\.accessibilityLabel))")
        #expect(pair.allSatisfy { $0.customView == nil }, "a button in a custom view (#1679)")
    }

    /// The author pill keeps the leading end, with the dynamic space between,
    /// and no audio capsule or mute button is left in the bar.
    @Test func theAuthorPillKeepsTheLeadingEnd() throws {
        let items = try #require(feed().toolbarItems)
        #expect(items.first?.customView is SnapAuthorIdentityView)
        #expect(items.dropFirst().first?.customView == nil, "no dynamic space after the pill")
        #expect(!items.contains { $0.customView is SnapMediaAttributionView }, "the audio capsule is back")
        #expect(!labels(toolbarActions(feed())).contains("Mute"))
        // ⚠️ SIX, because ⋯ HAS ITS OWN BUBBLE: [pill][flex][save][repost]
        // [fixed][⋯]. iOS 26 fuses adjacent bar items into one platter, so the
        // fixed space before ⋯ IS the separation.
        #expect(items.count == 6, "the bar is [pill][flex][save][repost][fixed][⋯]: \(items.count)")
    }

    /// And the nav bar no longer wears the pill.
    @Test func theNavBarHasNoAuthorPill() {
        let nav = feed().navigationItem.rightBarButtonItems ?? []
        #expect(!nav.contains { $0.customView is SnapAuthorIdentityView })
    }

    /// ⚠️ THE ⋯ STANDS APART, in a platter of its own: the capsule holds what
    /// you DO to this post, ⋯ what is folded away.
    @Test func theMenuStandsInItsOwnPlatter() throws {
        let items = try #require(feed().toolbarItems)
        let separator = try #require(items.dropFirst(4).first)
        #expect(separator.customView == nil && separator.accessibilityLabel == nil, "no separator before the ⋯")
        let more = try #require(items.last)
        #expect(more.accessibilityLabel == "More actions")
        #expect(more.customView == nil, "⋯ is a button in a custom view (#1679)")
        #expect(more.menu != nil, "⋯ opens no menu")
    }

    // MARK: - The menu

    /// Share first (it left the capsule, #671), then Not interested and Report.
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
    /// is absent — an action that cannot act is not offered.
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
