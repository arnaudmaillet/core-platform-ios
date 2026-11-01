import CoreModels
import DesignSystem
import Testing
import UIKit
@testable import Feed

/// The comment zone's VERTICAL SEATING, and the pill shape that follows from
/// the zone now carrying reaction-shaped comments as well as sentences.
///
/// A hidden `UIView` still occupies its frame, so stacking the zone on the
/// band's top edge left a band-height hole under the cue on every page the
/// band declines — which is most of them. The band cannot collapse (it is
/// the engagement corner's height authority), so the zone moves instead.
@MainActor
struct SnapCommentZoneLayoutTests {
    private static func chrome(mediaURL: URL? = URL(string: "mock://media/1")) -> SnapChromeView {
        let chrome = SnapChromeView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        chrome.setFixedInsets(UIEdgeInsets(top: 103, left: 0, bottom: 34, right: 0))
        chrome.configure(with: FeedItemDisplayModel(
            id: PostID("post-1"),
            authorID: ProfileID("profile-1"),
            authorName: "Ana",
            metaText: "@ana · 3m",
            avatarURL: nil,
            caption: "A caption long enough to fill both of its lines beside the reserved floor.",
            mediaURL: mediaURL,
            mediaKind: .image,
            thumbnailURL: nil,
            audioText: nil
        ))
        chrome.layoutIfNeeded()
        return chrome
    }

    /// A part of the chrome, its own or its action column's (#695).
    private static func part<T: UIView>(_ chrome: SnapChromeView, _ type: T.Type) throws -> T {
        // The column's items stand deep in its glass (#1872).
        func find(_ view: UIView, deep: Bool) -> T? {
            for sub in view.subviews {
                if let match = sub as? T { return match }
                if deep || sub is SnapActionColumnLayer, let match = find(sub, deep: true) { return match }
            }
            return nil
        }
        return try #require(find(chrome, deep: false))
    }

    private static func cues(_ count: Int) -> [SubtitleCue] {
        (0..<count).map { SubtitleCue(id: "s\($0)", text: "A whole sentence worth reading \($0).") }
    }

    private static func reactions(_ count: Int) -> [TickerCommentModel] {
        (0..<count).map { TickerCommentModel(id: "r\($0)", text: "fire \($0)") }
    }

    /// The zone holds the band's seat, one md above the caption floor,
    /// band or no band (2026-10-16: the stream under the band) — so the
    /// corner never shows a gap it isn't using, and a band arriving with a
    /// later stream moves nothing below it.
    @Test func theZoneHoldsTheSeatBandOrNoBand() throws {
        let chrome = Self.chrome()
        let subtitle = try Self.part(chrome, SnapSubtitleView.self)

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: Self.cues(2), commentCount: 2
        ))
        chrome.layoutIfNeeded()
        let seated = subtitle.frame.maxY
        #expect(seated < chrome.debugCaptionFrame.minY, "the zone sits on the caption")

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: Self.reactions(8), subtitles: Self.cues(2), commentCount: 10
        ))
        chrome.layoutIfNeeded()
        #expect(abs(subtitle.frame.maxY - seated) < 0.5)
    }

    /// The band keeps its frame through all of it. It is the corner's height
    /// authority — the "+" pins to its top and bottom edges and the rail's
    /// width derives from it — so collapsing it to close the gap would have
    /// taken the whole trailing column with it.
    @Test func theBandKeepsItsFrameSoTheCornerHoldsStill() throws {
        let chrome = Self.chrome()
        let ticker = try Self.part(chrome, SnapCommentTickerView.self)
        let compose = try Self.part(chrome, SnapRailBoostButton.self)
        let rail = try Self.part(chrome, SnapShortcutRailView.self)

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: Self.reactions(8), subtitles: Self.cues(2), commentCount: 10
        ))
        chrome.layoutIfNeeded()
        let withBand = (ticker.frame, compose.frame, rail.frame)

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: Self.cues(2), commentCount: 2
        ))
        chrome.layoutIfNeeded()

        #expect(ticker.frame == withBand.0)
        #expect(compose.frame == withBand.1)
        #expect(rail.frame == withBand.2)
        #expect(compose.frame.height > 0)
    }

    // MARK: - Short reaction cues

    private static func pill(_ text: String, width: CGFloat = 300) -> SubtitlePillLabel {
        let label = SubtitlePillLabel()
        label.numberOfLines = 2
        label.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.medium)
        label.text = text
        label.frame = CGRect(origin: .zero, size: label.intrinsicContentSize)
        label.layoutIfNeeded()
        return label
    }

    /// A pill is never narrower than it is tall: a one-grapheme cue would
    /// otherwise be a sliver beside the 28pt avatar. Same min-width-equals-
    /// height rule the count badge uses to keep a single digit circular.
    @Test func aOneGraphemeCueIsNeverNarrowerThanItIsTall() {
        let size = Self.pill("W").intrinsicContentSize
        #expect(size.width >= size.height)

        // The floor never inflates a pill that is already wide enough.
        let sentence = Self.pill("Where was this taken?")
        #expect(sentence.intrinsicContentSize.width > sentence.intrinsicContentSize.height)
    }
}
