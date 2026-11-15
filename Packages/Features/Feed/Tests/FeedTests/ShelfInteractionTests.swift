import CoreModels
import DesignSystem
import EmoteKit
import Foundation
import MediaCore
import PostGrid
import Testing
import UIKit
@testable import Feed
@testable import ThreadKit

/// How a shelf leading a grid answers a finger (2026-09-29 follow-up): the
/// headers push through their OWN tap path, a long press lifts a preview whose
/// commit opens what a tap would, and a card's caption animates its emotes.
/// For You's Friends row and its "For you ›" heading went with the tab (#2453).
@MainActor
struct ShelfInteractionTests {
    private struct SilentFetcher: ImageFetching {
        func fetchImageData(for url: URL) async throws -> Data { Data() }
    }

    private func post(_ id: String, by author: String, kind: GalleryPost.Kind = .photo) -> GalleryPost {
        GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            thumbnailURL: kind == .text ? nil : URL(string: "https://example.com/\(id).jpg"),
            caption: "caption \(id)", publishedAtMS: 1,
            authorID: ProfileID(author), authorName: author.capitalized, authorHandle: author
        )
    }

    private func makeLead() -> ShelfLeadFixture {
        let lead = ShelfLeadFixture(pipeline: ImagePipeline(fetcher: SilentFetcher()), videoPlayback: nil)
        lead.stack.frame = CGRect(x: 0, y: 0, width: 393, height: 600)
        return lead
    }

    // MARK: - Headers

    /// The headers push through the bar's own recogniser — #312's chevron was
    /// dead on device while its test, calling the host's closure, passed.
    @Test func eachRowHeaderPushesItsList() {
        let lead = makeLead()
        var pushed: [String] = []
        lead.shelf.onViewAll = { pushed.append("following") }
        lead.stack.onListTitleTapped = { pushed.append("for you") }
        lead.render(following: [post("c", by: "bo")])
        lead.shelf.debugTapTitle()
        lead.stack.debugListTitleView.debugTap()
        #expect(pushed == ["following", "for you"])
    }

    /// "For you" under the rows — and nothing at all without rows.
    @Test func forYouTitlesTheListUnderTheRows() {
        let lead = makeLead()
        lead.render(following: [])
        lead.stack.layoutIfNeeded()
        #expect(lead.stack.debugListTitleView.isHidden)
        #expect(ShelfLeadFixture.height(forWidth: 393, following: 0) == 0)

        lead.render(following: [post("c", by: "bo")])
        lead.stack.layoutIfNeeded()
        #expect(!lead.stack.debugListTitleView.isHidden)
        let rowsOnly = SectionTitleView.Metrics.height + LeadRowMetrics.cardSize(forWidth: 393).height
        #expect(ShelfLeadFixture.height(forWidth: 393, following: 1)
                >= rowsOnly + SectionTitleView.Metrics.height, "room for the title")
    }

    /// The titles are the app's ONE section title (2026-09-30):
    /// `Following 2 ›` with the count as secondary text, `For you ›` a link
    /// with no count (2026-10-01) — every one standing `SectionTitleView.Metrics.surfaceInset`
    /// from the list's edge, the same line the pushed lists' and the sound
    /// sheet's titles stand on.
    @Test func theRowTitlesAreTheAppsSectionTitle() {
        let list = UIScrollView(frame: CGRect(x: 0, y: 0, width: 393, height: 800))
        let lead = makeLead()
        list.addSubview(lead.stack)
        lead.render(following: [post("p1", by: "bo"), post("p2", by: "cy")], newCount: 2)
        lead.stack.layoutIfNeeded()
        let headers = [lead.shelf.header, lead.stack.debugListTitleView]
        for header in headers { header.layoutIfNeeded() }
        #expect(headers.map(\.debugTitleText) == ["Following", "For you"])
        #expect(headers.map(\.debugCountText) == ["2", nil])
        #expect(headers.map(\.debugShowsChevron) == [true, true])
        for header in headers {
            let x = header.convert(header.debugFrames.title, to: list).minX
            #expect(abs(x - SectionTitleView.Metrics.surfaceInset) < 0.5, "\(header.debugTitleText ?? "") at \(x)")
        }
        let following = headers[0].debugFrames
        #expect(abs(following.count.minX - following.title.maxX - SectionTitleView.Metrics.titleToCount) < 0.5)
        #expect(abs(following.chevron.minX - following.count.maxX - SectionTitleView.Metrics.countToChevron) < 0.5)
        #expect(headers[0].accessibilityValue == "2 new")
        // "For you ›": the chevron a word space after the title, as on a row
        // header with nothing new.
        let forYou = headers[1].debugFrames
        #expect(abs(forYou.chevron.minX - forYou.title.maxX - SectionTitleView.Metrics.titleToChevron) < 0.5)
        #expect(headers[1].accessibilityTraits.contains(.button))
    }

    // MARK: - Long press

    /// The post menu (#1498 §3): the post's rows, then the host's about the
    /// author under "@handle", with no "Open"; the preview's commit opens
    /// exactly what a tap on the card opens.
    @Test func aCardsPreviewCommitsToTheCardsOpen() throws {
        let lead = makeLead()
        let cards = [post("c0", by: "bo"), post("c1", by: "cy")]
        lead.render(following: cards)
        lead.shelf.cardAuthorMenuActions = { _, _ in [.viewProfile {}] }
        let titles = lead.shelf.debugCardMenuTitles(at: 1)
        #expect(!titles.contains("Open"))
        #expect(titles.contains("Comment") && titles.contains("Share"))
        #expect(titles.last?.hasPrefix("@") == true, "the author's rows are not under their handle")

        var opened: [Int] = []
        lead.shelf.onCardTapped = { opened.append($0) }
        let configuration = try #require(lead.shelf.debugCardMenuConfiguration(at: 1))
        lead.shelf.debugCommitPreview(configuration)
        #expect(opened == [1])
    }

    @Test func aMenuTargetSurvivesItsIdentifier() {
        let story = RowMenuTarget.story(ProfileID("ana"))
        let card = RowMenuTarget.card(PostID("post:with:colons"))
        #expect(RowMenuTarget(story.identifier) == story)
        #expect(RowMenuTarget(card.identifier) == card)
        #expect(RowMenuTarget("elsewhere" as NSString) == nil)
    }

    /// The preview is sized by the post's shape, held between 2:3 and 16:9.
    @Test func aPreviewTakesThePostsShapeWithinBounds() {
        let portrait = GalleryPost(
            id: PostID("p"), kind: .video, isRepost: false, thumbnailURL: nil,
            aspectRatio: 9.0 / 16.0, caption: "", publishedAtMS: 1
        )
        let size = PostPreviewViewController.preferredSize(for: portrait, width: 300)
        #expect(size.width == 300)
        #expect(size.height == 450, "a 9:16 clip previews at 2:3")
    }

    // MARK: - Playback and emotes

    /// Every card on screen plays — at 2.3 per width, three at most — and the
    /// row plus the list never ask for more than the pool's six.
    @Test func theRowPlaysEveryVisibleCardWithinThePool() {
        #expect(PostShelfSection.concurrentPlayers == 3)
        #expect(LeadRowMetrics.cardsPerWidth < 3)
    }

    /// A card's caption is an `EmoteLabel`, so its emotes animate.
    @Test func aCardsCaptionAnimatesItsEmotes() {
        let overlay = PostShelfMediaCardCell.makeOverlay(
            for: post("c", by: "bo"), restingSize: CGSize(width: 150, height: 200)
        )
        #expect(overlay.subviews.contains { $0 is EmoteLabel })
    }
}

/// The long press's preview of a picture (#1498, the owner 2026-10-20): the
/// card's author band at card size over the media's foot, the likes at its
/// trailing end, the caption's lines above it.
@MainActor
struct PreviewAuthorBandTests {
    private static func photo(likes: Int64? = 123, caption: String = "Quiet morning, notes and a long walk before work") -> GalleryPost {
        GalleryPost(
            id: PostID("p"), kind: .photo, isRepost: false,
            thumbnailURL: URL(string: "https://example.com/p.jpg"),
            aspectRatio: 3.0 / 4.0, caption: caption, publishedAtMS: 1,
            authorID: ProfileID("marcus"), authorName: "Marcus Holt", authorHandle: "marcus.holt",
            reactionCount: likes
        )
    }

    private func laidOut(_ post: GalleryPost) -> PostPreviewViewController {
        let preview = PostPreviewViewController(
            post: post, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), width: 360
        )
        preview.loadViewIfNeeded()
        preview.view.frame = CGRect(origin: .zero, size: preview.preferredContentSize)
        preview.view.layoutIfNeeded()
        return preview
    }

    @Test func thePicturesAuthorIsTheCardsBandWithItsLikes() {
        let preview = laidOut(Self.photo())
        let band = preview.debugBand
        let size = preview.view.bounds.size
        #expect(band.superview === preview.view)
        #expect(band.frame.height == PostAuthorBandView.avatarDiameter, "not the card's band size: \(band.frame)")
        #expect(abs(band.frame.maxY - (size.height - PostPreviewViewController.footInset)) < 0.5, "not on the media's foot")
        #expect(band.overrideUserInterfaceStyle == .dark, "the band's ink is not light over the picture")

        let likes = preview.debugLikes
        #expect(!likes.isHidden && likes.postLikeCount == 123)
        #expect(likes.frame.maxX <= size.width - PostPreviewViewController.footInset + 0.5, "the likes are not trailing")
        #expect(band.frame.maxX <= likes.frame.minX, "the band runs under the likes")
        #expect(abs(likes.frame.midY - band.frame.midY) < 0.5, "the likes do not close the band's line")

        let caption = preview.debugCaption
        #expect(!caption.isHidden && caption.frame.maxY <= band.frame.minY, "the caption is not above the author")
        #expect(caption.numberOfLines == PostCardCaptionOverlay.mediaCaptionLines)
        #expect(!preview.view.subviews.contains { $0 is PostCardCaptionOverlay }, "the small author line came back")
    }

    /// No caption: the band alone; no count: no likes.
    @Test func withoutCaptionOrCountTheBandStandsAlone() {
        let preview = laidOut(Self.photo(likes: nil, caption: ""))
        #expect(preview.debugCaption.isHidden)
        #expect(preview.debugLikes.isHidden)
        #expect(abs(preview.debugBand.frame.maxX - (preview.view.bounds.width - PostPreviewViewController.footInset)) < 0.5)
    }

    /// A text post's preview is its own (`TextCardPreviewTests`): no media
    /// foot, no card overlay.
    @Test func aTextPostHasItsOwnPreview() {
        let text = GalleryPost(id: PostID("t"), kind: .text, isRepost: false, thumbnailURL: nil, caption: "Words", publishedAtMS: 1)
        let preview = laidOut(text)
        #expect(preview.debugTextCard != nil)
        #expect(!preview.view.subviews.contains { $0 is PostCardCaptionOverlay })
        #expect(preview.debugBand.superview == nil)
    }
}

/// A text card's long press (#1498, the owner 2026-10-20): the author band,
/// the caption, then the top comments that fit, in the post screen's rows.
@MainActor
struct TextCardPreviewTests {
    private static let text = GalleryPost(
        id: PostID("t"), kind: .text, isRepost: false, thumbnailURL: nil,
        caption: "Third coffee. Still deciding whether the rewrite was a good idea.",
        publishedAtMS: Int64(Date().timeIntervalSince1970 * 1000),
        authorID: ProfileID("yuki"), authorName: "Yuki Shirakawa", authorHandle: "yuki.snow", reactionCount: 234
    )

    private static func comment(_ index: Int, reply: Bool = false) -> CommentEntry {
        CommentEntry(
            id: "c\(index)", authorID: ProfileID("a\(index)"), authorName: "Kenji \(index)", authorHandle: "k\(index)",
            body: "The second one \(index)", createdAt: Date().addingTimeInterval(-600),
            parentID: reply ? "c0" : nil
        )
    }

    private func preview(comments: [CommentEntry]) -> PostPreviewViewController {
        let preview = PostPreviewViewController(
            post: Self.text, imagePipeline: ImagePipeline(fetcher: PlaceholderImageFetcher()), width: 360, comments: comments
        )
        preview.loadViewIfNeeded()
        preview.view.frame = CGRect(origin: .zero, size: preview.preferredContentSize)
        return preview
    }

    /// No comments: the band and the caption alone, the lift sized to them.
    @Test func withoutCommentsTheCaptionAlone() throws {
        let preview = preview(comments: [])
        let card = try #require(preview.debugTextCard)
        #expect(card.rows.isEmpty)
        #expect(card.band.superview === preview.view && card.caption.superview === preview.view)
        #expect(card.rule.superview == nil)
        #expect(card.caption.frame.minY >= card.band.frame.maxY, "the caption is not under the band")
        #expect(preview.preferredContentSize.height < 360 * TextCardPreview.maxHeightShare, "the lift did not fit its words")
        #expect(card.likes.postLikeCount == 234 && card.likes.frame.maxX <= 360 - TextCardPreview.inset + 0.5)
    }

    /// With comments: top-level ones, in order, as many as fit — never one
    /// cut in half — under the caption; replies are not shown.
    @Test func theTopCommentsThatFitAndNeverHalfOfOne() throws {
        let many = (0..<30).map { Self.comment($0) } + [Self.comment(99, reply: true)]
        let preview = preview(comments: many)
        let card = try #require(preview.debugTextCard)
        #expect(!card.rows.isEmpty && card.rows.count < 30, "\(card.rows.count) rows: not as many as fit")
        let maxHeight = (360 * TextCardPreview.maxHeightShare).rounded()
        #expect(preview.preferredContentSize.height <= maxHeight)
        for row in card.rows {
            #expect(row.frame.maxY <= preview.preferredContentSize.height, "a comment cut in half: \(row.frame)")
            #expect(row.frame.minY >= card.caption.frame.maxY, "a comment over the caption")
        }
        #expect(zip(card.rows, card.rows.dropFirst()).allSatisfy { $0.frame.maxY <= $1.frame.minY + 0.5 }, "rows overlap")
        #expect(card.rule.superview === preview.view)
    }

    /// Two comments that fit: both shown, the lift sized to them.
    @Test func aFewCommentsAllShown() throws {
        let preview = preview(comments: [Self.comment(1), Self.comment(2)])
        let card = try #require(preview.debugTextCard)
        #expect(card.rows.count == 2)
    }
}
