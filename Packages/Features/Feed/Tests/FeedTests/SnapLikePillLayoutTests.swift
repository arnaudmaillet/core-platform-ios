import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The like pill (#669, the layout since #680): the lower bubble sits on the
/// composer's field line and the like button is a vertical pill above it —
/// in both layouts, on the same window frames.
@MainActor
struct SnapLikePillLayoutTests {
    private typealias Layout = SnapActionColumnLayoutTests

    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    private static func model(likes: Int64 = 1_203, hidden: Bool = false, media: Bool = true) -> FeedItemDisplayModel {
        FeedItemDisplayModel(
            id: PostID("post-1"), authorID: ProfileID("profile-1"), authorName: "Ana",
            metaText: "@ana", avatarURL: nil, caption: "A caption",
            mediaURL: media ? URL(string: "mock://media/1") : nil, mediaKind: .image,
            thumbnailURL: nil, audioText: nil, likeCount: likes, likeCountHidden: hidden
        )
    }

    private static func chrome(_ model: FeedItemDisplayModel) -> SnapChromeView {
        let chrome = SnapChromeView(frame: Layout.screen)
        chrome.setFixedInsets(Layout.insets)
        chrome.configure(with: model)
        chrome.layoutIfNeeded()
        return chrome
    }

    /// The sound bubble's bottom is `glassGap` above the toolbar's glass; the
    /// like pill runs from the band's top down to `gap` above it, taller than
    /// wide.
    @Test func theSoundSitsOnTheFieldLineAndTheLikeIsAPill() {
        let column = Layout.mediaColumn()
        #expect(abs(column.sound.maxY - (Layout.toolbarGlassTop - SnapActionColumn.glassGap)) < 0.5,
                "the sound ends at \(column.sound.maxY), not glassGap above the glass at \(Layout.toolbarGlassTop)")
        #expect(abs(column.like.maxY - (column.sound.minY - SnapActionColumn.gap)) < 0.5)
        #expect(column.like.width == column.sound.width)
        #expect(column.like.height > column.like.width)
        #expect(abs(column.like.height - SnapActionColumn.likePillHeight) < 0.5)
    }

    /// The comments layout's stake pill and rail slot stand on the media
    /// layout's frames — the crossfade contract.
    @Test func theComposerStandsOnThePillExactly() throws {
        let media = Layout.mediaColumn()
        let (controller, window) = Layout.engagedPanel()
        let composer = try Layout.composerColumn(in: controller.view, space: window)
        let stake = try #require(composer.stake)
        // Equal to the float: the pill's height is a sum of font-derived terms
        // the two sides add in a different order.
        #expect(Self.same(stake, media.like), "stake \(stake) vs pill \(media.like)")
        #expect(Self.same(composer.rail, media.sound), "rail \(composer.rail) vs sound \(media.sound)")
        // The rail slot is level with the input row.
        #expect(abs(composer.rail.maxY - composer.field.maxY) < 0.5)
    }

    /// A text page has no sound bubble on the page; the pill keeps its
    /// media-page frame.
    @Test func thePillIsTheSameSizeOnATextPage() {
        let media = Self.chrome(Self.model())
        let text = Self.chrome(Self.model(media: false))
        #expect(text.debugBoostButton.frame == media.debugBoostButton.frame)
    }

    /// ⚠️ EVEN GAPS (#680): top → heart, heart → count, count → bottom —
    /// measured on what the pill DRAWS, its image and its title (#692).
    @Test func theGapsInsideThePillAreEven() {
        let chrome = Self.chrome(Self.model())
        let pill = chrome.debugBoostButton.frame
        let count = chrome.debugLikeBadgeFrame
        let heart = chrome.debugLikeHeartFrame
        #expect(SnapActionColumn.pillGap > 4, "the pill has no room for its gaps")
        let top = heart.minY - pill.minY
        let middle = count.minY - heart.maxY
        let bottom = pill.maxY - count.maxY
        let gaps = [top, middle, bottom]
        #expect((gaps.max() ?? 0) - (gaps.min() ?? 0) < 1, "uneven gaps top \(top), middle \(middle), bottom \(bottom)")
        #expect(pill.contains(count), "the count \(count) left the pill \(pill)")
    }

    /// No likes is "0", not an empty pill (#680).
    @Test func noLikesReadsZero() {
        #expect(Self.chrome(Self.model(likes: 0)).debugLikeBadgeText == "0")
        #expect(Self.chrome(Self.model(likes: 1_203)).debugLikeBadgeText == "1.2K")
    }

    /// ⚠️ A POST THAT HIDES ITS LIKES HAS NO LIKE PILL (#680): no heart, no
    /// count, and the band runs to the screen's edge, square-ended, in its
    /// place.
    @Test func hiddenLikesTakeThePillAwayAndWidenTheBand() {
        let shown = Self.chrome(Self.model())
        let hidden = Self.chrome(Self.model(hidden: true))

        #expect(!shown.debugBoostButton.isHidden)
        #expect(hidden.debugBoostButton.isHidden, "a post that hides its likes kept its like button")
        #expect(hidden.debugLikeBadgeText == nil)

        #expect(abs(hidden.debugTickerFrame.maxX - Layout.screen.maxX) < 0.5,
                "the band stops at \(hidden.debugTickerFrame.maxX), not the screen's edge")
        #expect(shown.debugTickerFrame.maxX < Layout.screen.maxX - SnapActionColumn.trailingInset)
        #expect(hidden.debugTickerRunsToEdge)
        #expect(!shown.debugTickerRunsToEdge)
    }

    /// The composer with no stake — the Messages thread — rests its rail
    /// slot (the pin) on the input row's line.
    @Test func theThreadsPinRestsOnTheInputRow() {
        let bar = CommentsInputBar()
        bar.showsStake = false
        bar.railFace = .pin(isPinned: false)
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

    /// ⚠️ ONE ROW (#680): at rest the field, its avatar and the rail slot are
    /// all `bubbleSize` tall — the post's comments and the Messages thread
    /// alike (one composer).
    @Test func theFieldAndItsAvatarAreTheBubblesHeight() throws {
        let bar = CommentsInputBar()
        bar.railFace = .pin(isPinned: false)
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
        let side = SnapActionColumn.bubbleSize
        #expect(abs(bar.debugField.frame.height - side) < 0.5, "field \(bar.debugField.frame.height) vs \(side)")
        #expect(abs(bar.debugAvatarFrame.height - side) < 0.5, "avatar \(bar.debugAvatarFrame.height) vs \(side)")
        #expect(abs(bar.debugRailButton.frame.height - side) < 0.5)
    }
}
