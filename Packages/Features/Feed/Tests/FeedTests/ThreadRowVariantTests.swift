import CoreModels
import DesignSystem
import MediaCore
import Testing
import UIKit
@testable import Feed

/// **One row for a message and a comment (#920).** `CommentRowView` draws the
/// avatar, the name, the time or the loader in its place, and the content for
/// both; its `variant` decides the rest — the comment's trailing ♥, and how the
/// row arrives and leaves (`ThreadRowEffect`): a message fades up, a comment
/// bounces in.
@MainActor
struct ThreadRowVariantTests {
    private static func likeButton(in row: CommentRowView) -> UIButton? {
        firstView(UIButton.self, in: row) { $0.accessibilityLabel == "Like comment" }
    }

    private static func firstView<T: UIView>(_ type: T.Type, in view: UIView, where match: (T) -> Bool) -> T? {
        if let typed = view as? T, match(typed) { return typed }
        for subview in view.subviews {
            if let found = firstView(type, in: subview, where: match) { return found }
        }
        return nil
    }

    private static let model = CommentDisplayModel(
        id: "r1", authorID: ProfileID("p1"), authorName: "Ava Moreau", metaText: "9:41 PM",
        body: "Hello", avatarURL: nil
    )

    // MARK: - The variants

    /// A comment wears the ♥ and bounces in; a message has no ♥ and fades up.
    @Test func eachVariantChoosesItsLikeControlAndItsEffect() throws {
        let row = CommentRowView(model: Self.model)
        #expect(row.variant == .comment, "a row is a comment until told otherwise")
        #expect(row.effect == .bounceIn)
        let like = try #require(Self.likeButton(in: row))
        #expect(!like.isHidden)

        row.variant = .message
        #expect(row.effect == .fadeUp)
        #expect(like.isHidden, "a message wears a ♥")

        row.variant = .comment
        #expect(row.effect == .bounceIn)
        #expect(!like.isHidden)
    }

    /// The effect is a PARAMETER: the variant gives its own, and a host may
    /// set another after it.
    @Test func theEffectIsAParameterOfTheRow() {
        let row = CommentRowView(model: Self.model)
        row.variant = .message
        row.effect = .bounceIn
        #expect(row.variant == .message)
        #expect(row.effect == .bounceIn)
        // A new variant restates its own.
        row.variant = .message
        #expect(row.effect == .fadeUp)
    }

    /// A recycled row is a comment again, whatever it was: a text page's
    /// liftable comments share the conversation's cell type.
    @Test func aRecycledRowIsACommentAgain() throws {
        let cell = ThreadRowCell(frame: CGRect(x: 0, y: 0, width: 358, height: 80))
        cell.row.variant = .message
        cell.prepareForReuse()
        #expect(cell.row.variant == .comment)
        #expect(cell.row.effect == .bounceIn)
        #expect(try #require(Self.likeButton(in: cell.row)).isHidden == false)
    }

    // MARK: - The effects

    /// The message's fade-up is what the rise was before #920, to the point:
    /// 24pt below, invisible; the comment's bounce starts small and invisible.
    @Test func eachEffectStartsFromItsOwnPlace() {
        let rise = ThreadRowEffect.fadeUp.appearStart
        #expect(rise.transform == CGAffineTransform(translationX: 0, y: 24))
        #expect(rise.alpha == 0)
        #expect(ThreadRowEffect.fadeUp.appearDuration == 0.45)

        let bounce = ThreadRowEffect.bounceIn.appearStart
        #expect(bounce.alpha == 0)
        if !MotionPreference.reducesMotion {
            #expect(bounce.transform == CGAffineTransform(scaleX: 0.6, y: 0.6))
        }
        #expect(ThreadRowEffect.fadeUp.disappearEnd.transform == CGAffineTransform(translationX: 0, y: 24))
        #expect(ThreadRowEffect.bounceIn.disappearEnd.alpha == 0)
    }

    /// Played on the view that carries the row, an arrival animates it FROM
    /// the effect's start to rest — each variant from its own start.
    @Test func anArrivalAnimatesFromTheVariantsStart() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        defer { window.isHidden = true }
        for variant in [CommentRowView.Variant.message, .comment] {
            let cell = ThreadRowCell(frame: CGRect(x: 0, y: 0, width: 358, height: 80))
            window.addSubview(cell)
            cell.row.configure(with: Self.model)
            cell.row.variant = variant
            cell.playArrival()
            // At rest in the model; the start is the animation's from-value.
            #expect(cell.contentView.transform == .identity)
            #expect(cell.contentView.alpha == 1)
            let keys = cell.contentView.layer.animationKeys() ?? []
            let transform = keys.compactMap { cell.contentView.layer.animation(forKey: $0) as? CABasicAnimation }
                .first { $0.keyPath == "transform" }
            let from = try #require(transform?.fromValue as? NSValue, "\(variant): no transform animation in \(keys)")
            let start = CATransform3DMakeAffineTransform(variant.effect.appearStart.transform)
            #expect(CATransform3DEqualToTransform(from.caTransform3DValue, start), "\(variant) did not start from its effect's start")
            cell.removeFromSuperview()
        }
    }

    /// A departure ends at the effect's end and only then calls back.
    @Test func aDepartureEndsAtTheEffectsEndThenCallsBack() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.isHidden = false
        defer { window.isHidden = true }
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        window.addSubview(view)
        var done = false
        ThreadRowEffect.bounceIn.playDisappear(on: view) { done = true }
        #expect(!done)
        #expect(view.alpha == 0)
        for _ in 0..<400 where !done { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(done, "the departure never called back")
    }

    // MARK: - The time, or the loader in its place

    /// The loader standing in for the time is the ROW's, so a comment row can
    /// show it as a message row does — at full ink (#919) — and give the time
    /// back once delivered.
    @Test func theTimeSlotIsTheRowsOnEitherVariant() throws {
        for variant in [CommentRowView.Variant.comment, .message] {
            let cell = CommentCell(frame: CGRect(x: 0, y: 0, width: 358, height: 80))
            cell.row.variant = variant
            cell.row.configure(with: CommentDisplayModel(
                id: "r1", authorID: ProfileID("p1"), authorName: "You", metaText: "",
                body: "On its way", avatarURL: nil
            ))
            cell.row.setDelivery(.sending, time: "9:41 PM")
            cell.layoutIfNeeded()
            #expect(cell.row.delivery == .sending)
            #expect(cell.row.sendingSpinnerView.isAnimating, "\(variant): no loader")
            #expect(cell.row.alpha == 1, "\(variant): the pending row is faded")
            #expect(cell.row.debugHeaderWidthFloor > 0, "\(variant): the line does not hold the time's place")

            cell.row.setDelivery(nil)
            #expect(cell.row.delivery == nil)
            #expect(!cell.row.sendingSpinnerView.isAnimating)
        }
    }

    /// A row that never awaited anything builds none of the loader's views —
    /// every comment, every message from someone else.
    @Test func aRowWithNothingPendingBuildsNoLoader() {
        let row = CommentRowView(model: Self.model)
        row.setDelivery(nil)
        row.prepareForReuse()
        #expect(row.sendingSpinnerView.superview == nil)
        #expect(row.debugHeaderWidthFloor == 0)
    }

    // MARK: - On the post (#920)

    private final class NoPostFeed: FeedProviding, @unchecked Sendable {
        func cachedFirstPage() async -> [FeedEntry]? { nil }
        func loadFirstPage() async throws -> FeedPage { FeedPage(entries: [], nextPageToken: nil, isCold: false) }
        func loadPage(afterToken token: String) async throws -> FeedPage {
            FeedPage(entries: [], nextPageToken: nil, isCold: false)
        }
        func loadPost(_ id: PostID) async throws -> FeedEntry {
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }

    private final class Accepting: CommentsProviding, @unchecked Sendable {
        let entries: [CommentEntry]
        init(_ entries: [CommentEntry]) { self.entries = entries }
        nonisolated func cachedTopComments(for postID: PostID) -> [CommentEntry]? { entries }
        func loadComments(for postID: PostID) async throws -> [CommentEntry] { entries }
        func addComment(
            _ body: String, to postID: PostID, parentID: String?, commentID: String
        ) async throws -> CommentEntry {
            CommentEntry(
                id: commentID, authorID: ProfileID("me"), authorName: "Me", authorHandle: "me",
                body: body, createdAt: Date(), parentID: parentID
            )
        }
    }

    /// The viewer's new comment arrives with the comment's bounce-in — on a
    /// text page's liftable rows and on a media post's plain ones alike —
    /// and the rows already there do not replay anything.
    @Test(arguments: [true, false])
    func aPostedCommentBouncesIn(threadChrome: Bool) async throws {
        let existing = (0..<3).map {
            CommentEntry(
                id: "c\($0)", authorID: ProfileID("p1"), authorName: "Ava Moreau", authorHandle: "ava",
                body: "Comment \($0)", createdAt: Date(timeIntervalSinceNow: -Double($0 + 1) * 60)
            )
        }
        let viewModel = PostDetailViewModel(
            postID: PostID("p"), repository: NoPostFeed(), commentsProvider: Accepting(existing)
        )
        let controller = PostDetailViewController(
            viewModel: viewModel,
            imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()),
            mode: .commentsOnly,
            threadChrome: threadChrome
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let stream = try #require(Self.firstView(UICollectionView.self, in: controller.view) { _ in true })
        for _ in 0..<500 where stream.visibleCells.compactMap(PostDetailViewController.commentRow(in:)).count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(stream.visibleCells.compactMap(PostDetailViewController.commentRow(in:)).count >= 3)
        #expect(controller.debugPlayedArrivals.isEmpty, "a loaded comment played the posted comment's arrival")

        viewModel.submitComment("Mine")
        for _ in 0..<500 where controller.debugPlayedArrivals.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.debugPlayedArrivals.count == 1, "the posted comment did not arrive with its effect")
        let posted = try #require(stream.visibleCells.first {
            PostDetailViewController.commentRow(in: $0)?.bodyTextLabel.text == "Mine"
        })
        let row = try #require(PostDetailViewController.commentRow(in: posted))
        #expect(row.variant == .comment)
        #expect(row.effect == .bounceIn)
    }
}
