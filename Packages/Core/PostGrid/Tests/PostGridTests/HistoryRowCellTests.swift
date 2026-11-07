import CoreModels
import DesignSystem
import Foundation
import Testing
import UIKit
@testable import PostGrid

/// History's row (#2170, the owner 2026-11-07): the square from the two
/// lines with its 56 pt floor, the title truncating while the trailing values
/// never do, the square's marks, and VoiceOver's one element.
@MainActor
struct HistoryRowCellTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func post(
        _ id: String = "p1", kind: GalleryPost.Kind = .photo, caption: String = "Golden hour at the pier",
        author: String? = "Sofía Reyes", likes: Int64? = 1_200, pages: Int = 1
    ) -> GalleryPost {
        let page = GalleryPost.MediaPage(thumbnailURL: nil, videoURL: kind == .video ? URL(string: "https://example.com/v.m3u8") : nil)
        return GalleryPost(
            id: PostID(id), kind: kind, isRepost: false,
            pages: kind == .text ? [] : Array(repeating: page, count: pages),
            caption: caption, publishedAtMS: 0,
            authorID: author == nil ? nil : ProfileID("a1"), authorName: author, authorHandle: author == nil ? nil : "sofia",
            reactionCount: likes
        )
    }

    private func traits(_ size: UIContentSizeCategory) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: size)
    }

    private func side(_ size: UIContentSizeCategory, wraps: Bool = false) -> CGFloat {
        PostHistoryRowCell.squareSide(
            titleFont: PostHistoryRowCell.titleFont(compatibleWith: traits(size)),
            detailFont: PostHistoryRowCell.detailFont(compatibleWith: traits(size)), wraps: wraps
        )
    }

    // MARK: The square

    /// As tall as the two lines and their padding, never under 56 pt — so it
    /// grows with the text size.
    @Test func theSquareIsTheTwoLinesTallWithAFloor() {
        #expect(side(.extraSmall) == PostHistoryRowCell.minimumSquareSide)
        #expect(side(.large) >= PostHistoryRowCell.minimumSquareSide)
        let title = PostHistoryRowCell.titleFont(compatibleWith: traits(.extraExtraExtraLarge))
        let detail = PostHistoryRowCell.detailFont(compatibleWith: traits(.extraExtraExtraLarge))
        let lines = title.lineHeight.rounded(.up) + PostHistoryRowCell.avatarDiameter(detailFont: detail)
            + PostHistoryRowCell.lineGap + PostHistoryRowCell.verticalPadding * 2
        #expect(side(.extraExtraExtraLarge) == max(PostHistoryRowCell.minimumSquareSide, lines.rounded(.up)))
        #expect(side(.extraExtraExtraLarge) > side(.large), "the square did not grow with the text")
        #expect(side(.extraExtraExtraLarge, wraps: true) > side(.extraExtraExtraLarge), "wrapped lines are taller")
    }

    /// The trailing values go under the leading ones once they would take
    /// more than their share of the line.
    @Test func trailingValuesWrapOnlyWhenTheyWouldCrushTheTitle() {
        #expect(!PostHistoryRowCell.wrapsTrailing(textWidth: 300, trailingWidth: 40))
        #expect(PostHistoryRowCell.wrapsTrailing(textWidth: 120, trailingWidth: 60))
        #expect(!PostHistoryRowCell.wrapsTrailing(textWidth: 0, trailingWidth: 60))
    }

    // MARK: The lines

    @Test func theTitleIsTheCaptionsFirstLine() {
        #expect(PostHistoryRowCell.title(for: post(caption: "First line\nsecond line")) == "First line")
        #expect(PostHistoryRowCell.title(for: post(caption: "  padded  ")) == "padded")
        #expect(PostHistoryRowCell.title(for: post(caption: "")) == "")
        #expect(PostHistoryRowCell.viewedText(Self.now.addingTimeInterval(-7_200), now: Self.now) == "2h")
        #expect(PostHistoryRowCell.viewedText(nil, now: Self.now) == nil)
    }

    private func laidOut(_ post: GalleryPost, viewedAt: Date?, width: CGFloat = 370) -> PostHistoryRowCell {
        let cell = PostHistoryRowCell(frame: CGRect(x: 0, y: 0, width: width, height: 64))
        cell.configure(with: post, viewedAt: viewedAt, now: Self.now, imagePipeline: nil)
        let size = cell.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        cell.frame = CGRect(origin: .zero, size: size)
        cell.layoutIfNeeded()
        return cell
    }

    /// A long title truncates at the end; the view time and the likes are
    /// never truncated, and close their lines at the row's trailing edge.
    @Test func theTitleTruncatesAndTheTrailingValuesNever() {
        let long = String(repeating: "A very long title that goes on ", count: 4)
        let cell = laidOut(
            post(caption: long, author: "Maximiliana Alexandrovna Konstantinopoulou-Smythe", likes: 12_345_678),
            viewedAt: Self.now.addingTimeInterval(-3 * 86_400)
        )
        let frames = cell.debugFrames
        #expect(cell.debugTitleTruncates)
        #expect(!cell.debugTimeTruncates)
        #expect(!cell.debugLikesTruncates)
        #expect(cell.debugViewedText == "3d")
        #expect(abs(frames.time.maxX - cell.bounds.width) < 1)
        #expect(abs(frames.likes.maxX - cell.bounds.width) < 1)
        #expect(frames.title.maxX <= frames.time.minX)
        #expect(frames.author.maxX <= frames.likes.minX)
        // The square is the row's height, square, at the leading edge.
        #expect(frames.square.minX == 0 && frames.square.width == frames.square.height)
        #expect(frames.square.height >= PostHistoryRowCell.minimumSquareSide)
        #expect(abs(cell.bounds.height - frames.square.height) < 1)
    }

    /// ⚠️ A recycled row whose last title was an emote caption (attributed
    /// text, whose paragraph style resets the label's line break) still
    /// truncates the next, plain title at its end.
    @Test func aRecycledRowStillTruncatesItsTitle() {
        let cell = laidOut(post(caption: "Coffee count: unreasonable ☕😂 and then some more words"), viewedAt: nil)
        cell.prepareForReuse()
        cell.configure(with: post(caption: "Shipped a thing today. Small, but mine and longer still"), viewedAt: nil, imagePipeline: nil)
        #expect(cell.debugTitleLineBreakMode == .byTruncatingTail)
    }

    /// A post without a caption keeps the title line's height.
    @Test func noCaptionKeepsTheLine() {
        let cell = laidOut(post(caption: ""), viewedAt: Self.now)
        #expect(cell.debugTitle == "")
        let title = PostHistoryRowCell.titleFont(compatibleWith: cell.traitCollection)
        #expect(cell.debugFrames.title.height >= title.lineHeight.rounded(.up) - 0.5)
    }

    /// A clip wears the play mark, a carousel the stack, a text post its
    /// own text tile.
    @Test func theSquaresMarks() {
        #expect(laidOut(post(kind: .video), viewedAt: nil).debugMarks == (true, false, false))
        #expect(laidOut(post(kind: .photo, pages: 3), viewedAt: nil).debugMarks == (false, true, false))
        #expect(laidOut(post(kind: .photo), viewedAt: nil).debugMarks == (false, false, false))
        #expect(laidOut(post(kind: .text), viewedAt: nil).debugMarks == (false, false, true))
    }

    /// The square is concealed alone: the words stay for a flight.
    @Test func concealmentTakesTheSquareAlone() {
        let cell = laidOut(post(), viewedAt: nil)
        cell.setHeroConcealed(true)
        #expect(cell.isHeroMediaConcealed && !cell.isHidden && cell.alpha == 1)
        cell.prepareForReuse()
        #expect(!cell.isHeroMediaConcealed, "a recycled row kept its hide")
    }

    // MARK: The author and VoiceOver

    /// A person beside content (#2145): tap → the card, hold → the profile.
    @Test func theAuthorsTapAndHold() {
        let cell = laidOut(post(), viewedAt: nil)
        var events: [String] = []
        cell.onAuthorTapped = { events.append("card") }
        cell.onAuthorHeld = { events.append("profile") }
        cell.debugTapAuthor()
        cell.debugHoldAuthor()
        #expect(events == ["card", "profile"])
        // No person, no action.
        let anonymous = laidOut(post(author: nil), viewedAt: nil)
        anonymous.onAuthorTapped = { events.append("ghost") }
        anonymous.debugTapAuthor()
        #expect(events == ["card", "profile"])
    }

    /// One element: "title, by author, viewed 2 hours ago, 1,200 likes".
    @Test func voiceOverReadsOneSentence() {
        let label = PostHistoryRowCell.accessibilityLabel(
            for: post(), viewedAt: Self.now.addingTimeInterval(-7_200), now: Self.now
        )
        let likes = NumberFormatter.localizedString(from: 1_200, number: .decimal)
        #expect(label == "Golden hour at the pier, by Sofía Reyes, viewed 2 hours ago, \(likes) likes")
        #expect(PostHistoryRowCell.accessibilityLabel(
            for: post(kind: .video, caption: "", likes: 1), viewedAt: Self.now, now: Self.now
        ) == "Video, by Sofía Reyes, viewed just now, 1 like")
        let cell = laidOut(post(), viewedAt: Self.now.addingTimeInterval(-7_200))
        #expect(cell.isAccessibilityElement)
        #expect(cell.accessibilityLabel == label)
    }

    /// Its custom actions: "Open profile" (the hold) and the row's action
    /// (the menu's "Remove from History").
    @Test func voiceOverActionsStandForTheHoldAndTheMenu() throws {
        let cell = laidOut(post(), viewedAt: nil)
        var events: [String] = []
        cell.onAuthorHeld = { events.append("profile") }
        cell.rowAction = ("Remove from History", { events.append("removed") })
        let actions = try #require(cell.accessibilityCustomActions)
        #expect(actions.map(\.name) == ["Open profile", "Remove from History"])
        for action in actions { _ = action.actionHandler?(action) }
        #expect(events == ["profile", "removed"])
    }

    /// The count, then the heart: "1.2K ♥" (the owner, 2026-11-07).
    @Test func theHeartFollowsTheCount() {
        let cell = laidOut(post(), viewedAt: Self.now)
        #expect(cell.debugLikesGlyphTrails)
    }

    /// A clip's play mark, bigger than it was (the owner, 2026-11-07): 0.34
    /// of the square, not 0.24.
    @Test func thePlayMarkIsALittleBigger() {
        let cell = laidOut(post(kind: .video), viewedAt: Self.now)
        let side = cell.debugFrames.square.width
        #expect(cell.debugMarks.play)
        #expect(abs(cell.debugPlaySide - max(14, (side * 0.34).rounded())) < 0.5)
        #expect(cell.debugPlaySide > (side * 0.24).rounded())
    }

    /// The bones are the row's height.
    @Test func theSkeletonIsTheRowsHeight() {
        let bones = PostHistoryRowSkeletonCell(frame: CGRect(x: 0, y: 0, width: 370, height: 10))
        let size = bones.systemLayoutSizeFitting(
            CGSize(width: 370, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        let row = laidOut(post(), viewedAt: nil)
        #expect(abs(size.height - row.bounds.height) < 1)
    }
}
