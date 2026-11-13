import CoreModels
import EntityStore
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import ThreadKit

/// A TEXT POST'S AUTHOR WEARS THE RELATION MARK (#2300, the owner's rule of
/// 2026-11-02: one mark, the same on every avatar that carries one). A media
/// post's author row wore it; a text post's author — its page's caption row,
/// and its card's band in the lists — wore a bare face.
///
/// Both faces are the shared marked face (`RelationMarkedAvatarView`), bound
/// by the same `AuthorBadgeBinding` over the same store as the author row and
/// the bar's pill; the "+" is the same follow; the tap and the hold are the
/// shared contract's (`PersonOpening`, role 1).
@MainActor
struct TextPostAuthorMarkTests {
    private let ava = ProfileID("ava")
    private let viewer = ProfileID("me")

    /// Lets the store's lookups land — bounded, and never on the clock.
    private static func settle(until condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
    }

    private static func captionCell() -> CaptionBubbleCell {
        let cell = CaptionBubbleCell(frame: CGRect(x: 0, y: 0, width: 360, height: 200))
        cell.configureSeed(
            caption: "Shipping the new build tonight.", timestamp: "2h", authorName: "Ava Moreau",
            monogram: "AM", avatarURL: nil, likeCount: 3, imagePipeline: nil
        )
        cell.layoutIfNeeded()
        return cell
    }

    private static func listCell(author: ProfileID?) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: 360, height: 220))
        cell.configure(
            with: GalleryPost(
                id: PostID("text-1"), kind: .text, isRepost: false, thumbnailURL: nil,
                caption: "Refactor landed and the office survived it.", publishedAtMS: 1_780_000_000_000,
                authorID: author, authorName: author == nil ? nil : "Ava Moreau",
                authorHandle: author == nil ? nil : "ava", reactionCount: 4
            ),
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher())
        )
        cell.layoutIfNeeded()
        return cell
    }

    private func binding(_ graph: MarkGraph, entities: EntityStore = EntityStore()) -> AuthorBadgeBinding {
        let store = SnapAuthorFollowStore(writer: graph, reader: graph, entities: entities, viewer: { [viewer] in viewer })
        let binding = AuthorBadgeBinding(store: store)
        store.onRelationChange = { binding.relationDidChange(for: $0) }
        store.onEveryRelationChange = { binding.viewerDidChange() }
        return binding
    }

    // MARK: - The text page's caption row

    /// The caption row is one more face of the screen's binding: the badge
    /// known at bind, the answer drawn when it lands — on a page configured
    /// ahead of time, in no window, included.
    @Test func theCaptionRowDrawsTheBindingsBadge() async {
        let graph = MarkGraph(answers: [ava: .following])
        let binding = binding(graph)
        let cell = Self.captionCell()
        binding.bind(cell, to: ava)
        #expect(cell.authorMark == .loading, "an unknown relation is the skeleton's badge (#2098)")
        await Self.settle { cell.authorMark == .following }
        #expect(cell.authorMark == .following, "the answer missed a prefetched page's caption row")
        #expect(cell.window == nil)
        #expect(cell.debugAuthorBadge?.drawn == .following)
    }

    /// A viewer change redraws the caption row and asks again.
    @Test func aViewerChangeRedrawsTheCaptionRow() async {
        let entities = EntityStore()
        let graph = MarkGraph(answers: [ava: .mutual])
        let binding = binding(graph, entities: entities)
        let cell = Self.captionCell()
        binding.bind(cell, to: ava)
        await Self.settle { cell.authorMark == .friends }
        #expect(cell.authorMark == .friends)
        graph.answers[ava] = .notFollowing
        entities.viewerDidChange()
        await Self.settle { cell.authorMark == .follow }
        #expect(cell.authorMark == .follow, "the new viewer's answer missed the caption row")
    }

    /// Unbound — a media page's comments sheet, a pushed post — the caption
    /// row draws no mark: a media post's author row wears it.
    @Test func anUnboundCaptionRowDrawsNone() {
        let cell = Self.captionCell()
        #expect(cell.authorMark == .none)
        #expect(cell.debugAuthorBadge?.drawn == PersonPill.Badge.none)
    }

    /// The viewer's own post: nothing.
    @Test func theViewersOwnCaptionRowDrawsNone() {
        let binding = binding(MarkGraph(answers: [:]))
        let cell = Self.captionCell()
        binding.bind(cell, to: viewer)
        #expect(cell.authorMark == .none)
    }

    /// The face's "+", tap and hold are the host's: the follow, then a person
    /// beside content — the card on a tap, the profile on a hold.
    @Test func theCaptionFacesPlusTapAndHold() throws {
        let cell = Self.captionCell()
        var events: [String] = []
        cell.onAvatarTap = { events.append("card") }
        cell.onAvatarHold = { events.append("profile") }
        cell.onAuthorFollowTap = { events.append("follow") }
        cell.setAuthorMark(.follow, animated: false)
        cell.debugTapAuthor()
        cell.debugHoldAuthor()
        try #require(cell.debugAuthorBadge).sendActions(for: .primaryActionTriggered)
        #expect(events == ["card", "profile", "follow"])
        // A recycled row forgets the author's mark and the routes.
        cell.prepareForReuse()
        #expect(cell.authorMark == .none)
        #expect(cell.onAvatarHold == nil)
        #expect(cell.onAuthorFollowTap == nil)
    }

    /// The other rows of the stream stay bare: the mark is the post's
    /// author's, as on a media post.
    @Test func aCommentsRowWearsNoMark() {
        let row = CommentRowView()
        row.setAuthorMark(.follow, animated: false)
        #expect(row.authorMark == .none)
        #expect(row.debugAuthorBadge == nil)
        #expect(row.debugCaptionOpening == nil)
    }

    // MARK: - The lists' author band

    /// A list card's band, bound through the lists' binding: the badge
    /// drawn as known, the answer landing on a card in no window.
    @Test func theListsBandDrawsTheBindingsBadge() async {
        let graph = MarkGraph(answers: [ava: .requested])
        let marks = PostAuthorMarks(writer: graph, reader: graph, entities: EntityStore(), viewer: { [viewer] in viewer })
        let cell = Self.listCell(author: ava)
        marks.bind(cell, to: ava)
        await Self.settle { cell.authorRelationMark == .pending }
        #expect(cell.authorRelationMark == .pending)
        #expect(cell.debugAuthorBadge.drawn == .pending)
    }

    /// The viewer's own post wears nothing on its band.
    @Test func theViewersOwnBandWearsNothing() {
        let graph = MarkGraph(answers: [:])
        let marks = PostAuthorMarks(writer: graph, reader: graph, entities: EntityStore(), viewer: { [viewer] in viewer })
        let cell = Self.listCell(author: viewer)
        marks.bind(cell, to: viewer)
        #expect(cell.authorRelationMark == .none)
    }

    /// The band's "+" follows through the shared follow: the optimistic flip
    /// lands on every face bound to the author — the band, and a text page's
    /// caption row by the same author on the same store.
    @Test func theBandsPlusFollowsThroughTheSharedFollow() async {
        let entities = EntityStore()
        let graph = MarkGraph(answers: [ava: .notFollowing])
        let marks = PostAuthorMarks(writer: graph, reader: graph, entities: entities, viewer: { [viewer] in viewer })
        let cell = Self.listCell(author: ava)
        let caption = Self.captionCell()
        marks.bind(cell, to: ava)
        marks.bind(caption, to: ava)
        await Self.settle { cell.authorRelationMark == .follow }
        #expect(cell.authorRelationMark == .follow)

        cell.onAuthorFollowTapped = { [ava] in
            marks.follow(ava, handle: "ava", name: "Ava Moreau", from: cell)
        }
        cell.debugAuthorBadge.sendActions(for: .primaryActionTriggered)
        #expect(cell.authorRelationMark == .following, "the optimistic flip missed the band")
        #expect(caption.authorMark == .following, "a follow on the band missed the caption row")
        await Self.settle { graph.follows == [ava] }
        #expect(graph.follows == [ava])
    }

    // MARK: - The guard

    /// ⚠️ A REPO GUARD (#2300): a post author's face in Feed or PostGrid is
    /// the shared marked face, and nothing there draws a badge by hand.
    /// Source: no `RelationBadgeView(` or `FaceCutout(` built in Feed or
    /// PostGrid; the two post-author faces build `RelationMarkedAvatarView(`.
    /// Runtime: the caption row and the band hold one.
    @Test func noPostAuthorFaceWithoutTheMark() throws {
        let packages = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FeedTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // Feed
            .deletingLastPathComponent() // Features
            .deletingLastPathComponent() // Packages
        var handDrawn: [String] = []
        var sources: [String: String] = [:]
        for folder in ["Features/Feed/Sources", "Core/PostGrid/Sources", "Core/ThreadKit/Sources"] {
            let enumerator = FileManager.default.enumerator(
                at: packages.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            while let url = enumerator?.nextObject() as? URL {
                guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                sources[url.lastPathComponent] = text
                if text.contains("RelationBadgeView(") || text.contains("FaceCutout(") {
                    handDrawn.append(url.lastPathComponent)
                }
            }
        }
        #expect(sources["PostAuthorBandView.swift"] != nil, "the guard reads no source")
        #expect(handDrawn.isEmpty, "a badge drawn outside `RelationMarkedAvatarView`: \(handDrawn)")
        #expect(sources["PostAuthorBandView.swift"]?.contains("RelationMarkedAvatarView(") == true)
        #expect(sources["CommentRowView.swift"]?.contains("RelationMarkedAvatarView(") == true)

        func holdsMarkedFace(_ view: UIView) -> Bool {
            view is RelationMarkedAvatarView || view.subviews.contains(where: holdsMarkedFace)
        }
        #expect(holdsMarkedFace(Self.captionCell()), "the caption row's face is unmarked")
        #expect(holdsMarkedFace(Self.listCell(author: ava)), "the band's face is unmarked")
    }
}

/// A follow graph that answers at once from `answers`, recording each ask
/// and each follow.
@MainActor
private final class MarkGraph: SocialGraphReading, SocialGraphWriting {
    var answers: [ProfileID: FollowRelation]
    private(set) var lookups: [ProfileID] = []
    private(set) var follows: [ProfileID] = []

    init(answers: [ProfileID: FollowRelation]) {
        self.answers = answers
    }

    func followRelation(to profileID: ProfileID) async throws -> FollowRelation {
        lookups.append(profileID)
        guard let answer = answers[profileID] else { throw URLError(.resourceUnavailable) }
        return answer
    }

    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws {}

    func follow(_ profileID: ProfileID) async throws -> FollowOutcome {
        follows.append(profileID)
        return .following
    }
}
