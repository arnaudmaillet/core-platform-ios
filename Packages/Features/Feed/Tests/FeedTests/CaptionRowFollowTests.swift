import CoreModels
import CoreStorage
import DesignSystem
import EntityStore
import Foundation
import MediaCore
import MediaCoreFixtures
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import PostSurfaces
@testable import ThreadKit

/// A TEXT PAGE'S CAPTION ROW CARRIES THE AUTHOR'S FOLLOW (#2419, the owner's
/// option A of 2026-11-28): left of the ♥ count, at a size that fits the
/// footnote line, so the line keeps its height while the button shows,
/// turns to "✓ Following" and folds away — the caption's body never moves.
/// The band's rules: only an author the viewer doesn't follow, Follow back,
/// Requested, the shared follow, every row by that author updating.
@MainActor
struct CaptionRowFollowTests {
    private static let width: CGFloat = 360
    private let ava = ProfileID("ava")
    private let viewer = ProfileID("me")

    /// Lets the store's lookups land — bounded, and never on the clock.
    private static func settle(until condition: () -> Bool) async {
        for _ in 0..<10_000 where !condition() {
            await Task.yield()
        }
    }

    private static func captionCell(authorName: String = "Ava Moreau") -> CaptionBubbleCell {
        let cell = CaptionBubbleCell(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        cell.configureSeed(
            caption: "Shipping the new build tonight, then a long walk to think about the next one.",
            timestamp: "2h", authorName: authorName, monogram: "AM", avatarURL: nil, likeCount: 271,
            imagePipeline: nil
        )
        layOut(cell)
        return cell
    }

    /// Lays `cell` out at the row's width and its fitted height.
    private static func layOut(_ cell: CaptionBubbleCell) {
        let fitted = cell.contentView.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        cell.frame.size = CGSize(width: width, height: ceil(fitted.height))
        cell.layoutIfNeeded()
    }

    /// What must never move: the cell's fitted height, the name line's
    /// height, and where the caption's body starts.
    private struct Geometry: Equatable, CustomStringConvertible {
        let cellHeight: CGFloat
        let lineHeight: CGFloat
        let bodyTop: CGFloat
        var description: String { "cell \(cellHeight), line \(lineHeight), body at \(bodyTop)" }
    }

    private static func geometry(of cell: CaptionBubbleCell) -> Geometry {
        layOut(cell)
        let line = cell.debugHeaderLabel.convert(cell.debugHeaderLabel.bounds, to: cell)
        let body = cell.debugBodyLabel.convert(cell.debugBodyLabel.bounds, to: cell)
        return Geometry(cellHeight: cell.bounds.height, lineHeight: line.height, bodyTop: body.minY)
    }

    private static func listCell(author: ProfileID) -> PostGridListRowCell {
        let cell = PostGridListRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 220))
        cell.configure(with: post(author: author), imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()))
        cell.layoutIfNeeded()
        return cell
    }

    private static func post(author: ProfileID) -> GalleryPost {
        GalleryPost(
            id: PostID("text-1"), kind: .text, isRepost: false, thumbnailURL: nil,
            caption: "Refactor landed and the office survived it.", publishedAtMS: 1_780_000_000_000,
            authorID: author, authorName: "Ava Moreau", authorHandle: "ava", reactionCount: 4
        )
    }

    private func marks(_ graph: CaptionGraph, entities: EntityStore = EntityStore()) -> PostAuthorMarks {
        PostAuthorMarks(writer: graph, reader: graph, entities: entities, viewer: { [viewer] in viewer })
    }

    // MARK: - Which rows show it

    /// Follow, Follow back and Requested for an author the viewer doesn't
    /// follow (or asked); the tinted row action, quiet once requested.
    @Test(arguments: [
        (FollowRelation.notFollowing, AuthorFollowOffer.follow, "Follow", false),
        (.followedBy, .followBack, "Follow back", false),
        (.requested, .requested, "Requested", true),
    ])
    func theCaptionRowOffersFollowByRelation(
        _ relation: FollowRelation, _ offer: AuthorFollowOffer, _ title: String, _ quiet: Bool
    ) async throws {
        let marks = marks(CaptionGraph(answers: [ava: relation]))
        let cell = Self.captionCell()
        marks.bind(cell, to: ava, offersFollow: true)
        await Self.settle { cell.authorFollowOffer == offer }
        #expect(cell.authorFollowOffer == offer)
        let button = try #require(cell.debugAuthorFollowButton)
        #expect(!button.isHidden)
        #expect(button.content.title == title)
        #expect(button.isSelected == quiet)
        #expect(button.aspect == .rowAction, "not the row action's tinted ground")
        #expect(button.size == .compact, "not the line's compact size")
    }

    /// No button for an author the viewer follows (a friend included), the
    /// viewer's own post, someone blocked.
    @Test(arguments: [FollowRelation.following, .mutual, .blocked])
    func noFollowForAFollowedOrBlockedAuthor(_ relation: FollowRelation) async throws {
        let marks = marks(CaptionGraph(answers: [ava: relation]))
        let cell = Self.captionCell()
        marks.bind(cell, to: ava, offersFollow: true)
        await Self.settle { marks.store.relation(for: ava) != nil }
        #expect(marks.store.relation(for: ava) == relation)
        #expect(!cell.authorFollowOffer.showsButton)
        #expect(try #require(cell.debugAuthorFollowButton).isHidden)
    }

    @Test func noFollowOnTheViewersOwnPost() throws {
        let marks = marks(CaptionGraph(answers: [:]))
        let cell = Self.captionCell()
        marks.bind(cell, to: viewer, offersFollow: true)
        #expect(cell.authorFollowOffer == .none)
        #expect(try #require(cell.debugAuthorFollowButton).isHidden)
    }

    /// NOT WHILE THE RELATION IS UNKNOWN: nothing, then the button comes in
    /// once the answer lands — and the line keeps its height through it.
    @Test func anUnknownRelationShowsNothingThenTheButtonComesIn() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        window.isHidden = false
        defer {
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
        }
        let graph = CaptionGraph(answers: [:])
        let marks = marks(graph)
        let cell = Self.captionCell()
        window.addSubview(cell)
        let before = Self.geometry(of: cell)
        marks.bind(cell, to: ava, offersFollow: true)
        #expect(cell.authorFollowOffer == .none, "a guess drawn before the answer")
        #expect(try #require(cell.debugAuthorFollowButton).isHidden)
        await Self.settle { graph.lookups.contains(ava) }
        for _ in 0..<10 { await Task.yield() }
        graph.answers[ava] = .notFollowing
        marks.store.resolve(for: ava, refresh: true)
        await Self.settle { cell.authorFollowOffer == .follow }
        #expect(cell.authorFollowOffer == .follow)
        #expect(try #require(cell.debugAuthorFollowButton).isHidden == false)
        #expect(Self.geometry(of: cell) == before, "the line moved as Follow came in")
    }

    /// The ordinary comment rows carry no Follow: only the caption row does.
    @Test func aCommentsRowHasNoFollow() {
        let row = CommentRowView()
        row.setAuthorFollowOffer(.follow, animated: false)
        #expect(row.debugAuthorFollowButton == nil)
        #expect(row.authorFollowOffer == .none)
    }

    /// An unbound caption row — a media page's, whose bar wears the author —
    /// shows no Follow.
    @Test func anUnboundCaptionRowShowsNoFollow() throws {
        let cell = Self.captionCell()
        #expect(cell.authorFollowOffer == .none)
        #expect(try #require(cell.debugAuthorFollowButton).isHidden)
    }

    // MARK: - Where, and at what height

    /// LEFT OF THE ♥ COUNT, on the name line: name, Follow, ♥.
    @Test func followStandsLeftOfTheLikeCount() throws {
        let cell = Self.captionCell()
        cell.setAuthorFollowOffer(.follow, animated: false)
        Self.layOut(cell)
        let button = try #require(cell.debugAuthorFollowButton)
        let line = try #require(button.superview as? UIStackView)
        #expect(line.arrangedSubviews.count == 3)
        #expect(line.arrangedSubviews.first === cell.debugHeaderLabel)
        #expect(line.arrangedSubviews[1] === button)
        let like = try #require(line.arrangedSubviews.last)
        let follow = button.convert(button.bounds, to: cell)
        let name = cell.debugHeaderLabel.convert(cell.debugHeaderLabel.bounds, to: cell)
        let heart = like.convert(like.bounds, to: cell)
        #expect(name.maxX <= follow.minX + 0.5, "the name runs under Follow")
        #expect(follow.maxX <= heart.minX + 0.5, "Follow \(follow) is not left of the ♥ \(heart)")
        #expect(abs(follow.midY - name.midY) < 0.5, "Follow is off the name's line")
    }

    /// ⚠️ THE LINE KEEPS ITS HEIGHT: no button, Follow, Follow back,
    /// Requested — the same cell height, line height and body top; the
    /// button as tall as the name, never taller.
    @Test func theLineKeepsItsHeightWithOrWithoutTheButton() throws {
        let cell = Self.captionCell()
        let bare = Self.geometry(of: cell)
        for offer in [AuthorFollowOffer.follow, .followBack, .requested, .none] {
            cell.setAuthorFollowOffer(offer, animated: false)
            let shown = Self.geometry(of: cell)
            #expect(shown == bare, "\(offer): \(shown) ≠ \(bare)")
            let button = try #require(cell.debugAuthorFollowButton)
            if offer.showsButton {
                #expect(abs(button.bounds.height - bare.lineHeight) < 0.5, "\(offer): \(button.bounds.height) ≠ the line's \(bare.lineHeight)")
                let words = button.fittingSize(for: button.content).height
                #expect(words <= bare.lineHeight + 0.5, "\(offer): the words (\(words)) are taller than the line")
            }
        }
    }

    /// THE NAME TRUNCATES FIRST: Follow back keeps its size.
    @Test func aLongNameTruncatesFirst() throws {
        let long = String(repeating: "Maximilian Alexander ", count: 3) + "von Hohenzollern"
        let cell = Self.captionCell(authorName: long)
        let bare = Self.geometry(of: cell)
        cell.setAuthorFollowOffer(.followBack, animated: false)
        let shown = Self.geometry(of: cell)
        #expect(shown == bare, "a long name made the line grow: \(shown) ≠ \(bare)")
        let button = try #require(cell.debugAuthorFollowButton)
        let natural = button.fittingSize(for: button.content).width
        #expect(button.bounds.width >= natural - 0.5, "Follow back was squeezed: \(button.bounds.width) < \(natural)")
        let name = cell.debugHeaderLabel
        #expect(name.intrinsicContentSize.width > name.bounds.width + 0.5, "the name was not the one to give way")
    }

    // MARK: - The tap, the confirmation, the fold

    /// FOLLOWED ON SCREEN: "✓ Following" for a moment, then the fold — and
    /// the line never changes height, the body never moves, at any step.
    @Test func followedOnScreenConfirmsThenFoldsWithoutMovingTheBody() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        window.isHidden = false
        defer {
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
        }
        let cell = Self.captionCell()
        window.addSubview(cell)
        let button = try #require(cell.debugAuthorFollowButton)
        let clock = ManualLoadingClock()
        button.loadClock = clock.clock
        cell.setAuthorFollowOffer(.follow, animated: false)
        let resting = Self.geometry(of: cell)

        cell.setAuthorFollowOffer(.following, animated: true)
        #expect(button.isConfirming)
        #expect(button.content.title == "Following")
        #expect(button.content.symbol == "checkmark")
        #expect(Self.geometry(of: cell) == resting, "\"✓ Following\" moved the line")
        clock.advance(AuthorFollowButton.confirmationDuration - 0.1)
        #expect(!button.isHidden, "folded before its moment")
        clock.advance(0.2)
        #expect(button.isHidden, "\"✓ Following\" never folded")
        #expect(!button.isConfirming)
        #expect(Self.geometry(of: cell) == resting, "the fold moved the line")
    }

    /// A tap is the shared follow: the optimistic flip lands on every face
    /// bound to the author — the caption's own Follow and badge, and a list
    /// row by the same author on the same store.
    @Test func aTapFollowsThroughTheSharedFollow() async throws {
        let graph = CaptionGraph(answers: [ava: .notFollowing])
        let marks = marks(graph)
        let cell = Self.captionCell()
        let row = Self.listCell(author: ava)
        marks.bind(cell, to: ava, offersFollow: true)
        marks.bind(row, to: ava, offersFollow: true)
        await Self.settle { cell.authorFollowOffer == .follow }
        #expect(row.authorFollowOffer == .follow)
        cell.onAuthorFollowTapped = { [ava] in
            marks.follow(ava, handle: "ava", name: "Ava Moreau", from: cell)
        }
        try #require(cell.debugAuthorFollowButton).debugTap()
        #expect(cell.authorFollowOffer == .following)
        #expect(cell.authorMark == .following, "the optimistic flip missed the caption's face")
        #expect(row.authorFollowOffer == .following, "the same author's list row did not update")
        await Self.settle { graph.follows == [ava] }
        #expect(graph.follows == [ava])
    }

    /// Requested's tap is its menu, which cancels the request.
    @Test func requestedOffersToCancel() throws {
        let cell = Self.captionCell()
        var follows = 0
        cell.onAuthorFollowTapped = { follows += 1 }
        cell.setAuthorFollowOffer(.requested, animated: false)
        let button = try #require(cell.debugAuthorFollowButton)
        button.debugTap()
        #expect(follows == 0, "Requested followed again")
        #expect(button.showsMenuAsPrimaryAction)
        let cancel = try #require(button.menu?.children.first as? UIAction)
        #expect(cancel.title == "Cancel Request")
    }

    /// A recycled row forgets the previous post's Follow and its handlers;
    /// VoiceOver names the person.
    @Test func aRecycledRowForgetsTheFollow() throws {
        let cell = Self.captionCell()
        cell.onAuthorFollowTapped = {}
        cell.setAuthorFollowOffer(.follow, animated: false)
        #expect(cell.debugAuthorFollowButton?.accessibilityLabel == "Follow Ava Moreau")
        cell.prepareForReuse()
        #expect(cell.authorFollowOffer == .none)
        #expect(cell.onAuthorFollowTapped == nil)
        #expect(try #require(cell.debugAuthorFollowButton).isHidden)
    }

    // MARK: - A host that carries its own Follow (a profile)

    /// ⚠️ NO FOLLOW ON A PROFILE'S POST LISTS (#2419, the owner 2026-11-28):
    /// a page whose host turns `offersAuthorFollow` off binds its rows'
    /// bands with no Follow, whatever the relation, and its dismissal's
    /// stand-in draws none either. On, the same page offers it.
    @Test(arguments: [false, true])
    func aPageOffersTheBandsFollowOnlyWhenItsHostDoes(_ offers: Bool) async {
        let graph = CaptionGraph(answers: [ava: .notFollowing])
        let marks = marks(graph)
        let page = PostGridPageView(
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), style: .list,
            bookmarks: PostBookmarkStore(scope: StorageScope()),
            withheldPosts: UnavailablePosts(viewerEvents: ViewerEvents())
        )
        page.authorMarks = marks
        page.offersAuthorFollow = offers
        let post = Self.post(author: ava)
        let row = Self.listCell(author: ava)
        page.wireAuthorBand(of: row, for: post)
        await Self.settle { marks.store.relation(for: ava) != nil }
        #expect(marks.store.relation(for: ava) == .notFollowing)
        let expected: AuthorFollowOffer = offers ? .follow : .none
        #expect(row.authorFollowOffer == expected)
        #expect(row.debugAuthorFollowButton.isHidden == !offers)
        // The row isn't in the page's list: the stand-in's fallback path.
        #expect(page.standInAuthorFollow(for: post) == expected, "the stand-in disagrees with the row")
    }
}

/// A follow graph that answers from `answers` (unknown: a failed read),
/// recording each ask and each follow.
@MainActor
private final class CaptionGraph: SocialGraphReading, SocialGraphWriting {
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
