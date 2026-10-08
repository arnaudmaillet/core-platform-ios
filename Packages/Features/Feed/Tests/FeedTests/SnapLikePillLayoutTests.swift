import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// `-snap-like-pill` (#669): the lower bubble drops to the composer's field
/// line and the like button stretches into a vertical pill above it — in both
/// layouts, on the same window frames.
///
/// Each test turns the flag on BEFORE it builds a view and off before it
/// returns; none awaits in between, so no other main-actor test sees it.
@MainActor
struct SnapLikePillLayoutTests {
    private typealias Layout = SnapActionColumnLayoutTests

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    private func withPill<T>(_ body: () throws -> T) rethrows -> T {
        SnapActionColumn.isLikePill = true
        defer { SnapActionColumn.isLikePill = false }
        return try body()
    }

    /// The repost bubble's bottom is `glassGap` above the toolbar's glass; the
    /// like button runs from the band's top (where the square's top was) down
    /// to `gap` above it, a capsule taller than wide.
    @Test func theRepostDropsAndTheLikeBecomesAPill() {
        let square = Layout.mediaColumn()
        let pill = withPill { Layout.mediaColumn() }

        #expect(abs(pill.repost.maxY - (Layout.toolbarGlassTop - SnapActionColumn.glassGap)) < 0.5,
                "repost ends at \(pill.repost.maxY), not glassGap above the glass at \(Layout.toolbarGlassTop)")
        #expect(pill.repost.size == square.repost.size)
        #expect(pill.like.minY == square.like.minY, "the pill's top left the band's")
        #expect(abs(pill.like.maxY - (pill.repost.minY - SnapActionColumn.gap)) < 0.5)
        #expect(pill.like.width == square.like.width)
        #expect(pill.like.height > pill.like.width)
        #expect(abs(pill.like.height - SnapActionColumn.likePillHeight) < 0.5)
    }

    /// The comments layout's stake pill and rail slot stand on the media
    /// layout's frames — the crossfade contract, with the flag on.
    @Test func theComposerStandsOnThePillExactly() throws {
        try withPill {
            let media = Layout.mediaColumn()
            let (controller, window) = Layout.engagedPanel()
            let composer = try Layout.composerColumn(in: controller.view, space: window)
            let stake = try #require(composer.stake)
            // Equal to the float: the pill's height is a sum of font-derived
            // terms the two sides add in a different order.
            #expect(Self.same(stake, media.like), "stake \(stake) vs pill \(media.like)")
            #expect(Self.same(composer.rail, media.repost), "rail \(composer.rail) vs repost \(media.repost)")
            // The rail slot is level with the input row.
            #expect(abs(composer.rail.maxY - composer.field.maxY) < 0.5)
        }
    }

    /// A text page has no repost bubble; the pill keeps its media-page frame.
    @Test func thePillIsTheSameSizeOnATextPage() {
        withPill {
            let media = Layout.chrome()
            let text = Layout.chrome(mediaURL: nil)
            #expect(text.debugBoostButton.frame == media.debugBoostButton.frame)
        }
    }

    /// The count is under the heart, inside the pill — no corner badge — and
    /// none at all when the author hides it (#397).
    @Test func theCountSitsUnderTheHeartInsideThePill() {
        withPill {
            let shown = SnapChromeView(frame: Layout.screen)
            shown.setFixedInsets(Layout.insets)
            shown.configure(with: FeedItemDisplayModel(
                id: PostID("post-1"), authorID: ProfileID("profile-1"), authorName: "Ana",
                metaText: "@ana", avatarURL: nil, caption: "A caption",
                mediaURL: URL(string: "mock://media/1"), mediaKind: .image,
                thumbnailURL: nil, audioText: nil, likeCount: 1_203
            ))
            shown.layoutIfNeeded()
            #expect(shown.debugLikeBadgeText == "1.2K")
            let pill = shown.debugBoostButton.frame
            let count = shown.debugLikeBadgeFrame
            #expect(pill.contains(count), "the count \(count) left the pill \(pill)")
            #expect(count.minY >= pill.minY + SnapActionColumn.bubbleSize / 2, "the count is not under the heart")

            let hidden = SnapChromeView(frame: Layout.screen)
            hidden.configure(with: FeedItemDisplayModel(
                id: PostID("post-2"), authorID: ProfileID("profile-1"), authorName: "Ana",
                metaText: "@ana", avatarURL: nil, caption: nil,
                mediaURL: URL(string: "mock://media/1"), mediaKind: .image,
                thumbnailURL: nil, audioText: nil, likeCount: 1_203, likeCountHidden: true
            ))
            #expect(hidden.debugLikeBadgeText == nil)
        }
    }

    /// The composer with no stake — the Messages thread — drops its rail slot
    /// (the pin) to the input row's line too.
    @Test func theThreadsPinDropsToTheInputRow() throws {
        try withPill {
            let bar = CommentsInputBar()
            bar.showsStake = false
            bar.railFace = .repost
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
            #expect(abs(bar.bounds.maxY - bar.debugRailButton.frame.maxY) < 0.5)
        }
    }

    /// Flag off, nothing moves: the square and the caption-floor repost.
    @Test func withoutTheFlagTheColumnIsUnchanged() {
        #expect(!SnapActionColumn.isLikePill)
        let square = Layout.mediaColumn()
        #expect(square.like.height == square.like.width)
        #expect(SnapActionColumn.upperBubbleHeight == SnapActionColumn.bubbleSize)
    }
}
