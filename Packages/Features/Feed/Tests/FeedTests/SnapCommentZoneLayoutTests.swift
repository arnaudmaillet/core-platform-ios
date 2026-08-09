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

    private static func part<T: UIView>(_ chrome: SnapChromeView, _ type: T.Type) throws -> T {
        try #require(chrome.subviews.compactMap { $0 as? T }.first)
    }

    private static func cues(_ count: Int) -> [SubtitleCue] {
        (0..<count).map { SubtitleCue(id: "s\($0)", text: "A whole sentence worth reading \($0).") }
    }

    private static func reactions(_ count: Int) -> [TickerCommentModel] {
        (0..<count).map { TickerCommentModel(id: "r\($0)", text: "fire \($0)") }
    }

    /// With no band, the zone drops into the band's own seat — one md above
    /// the caption floor, exactly where the band's bottom edge would be —
    /// so the corner shows no gap it isn't using.
    @Test func theZoneTakesTheBandsSeatWhenTheBandIsHidden() throws {
        let chrome = Self.chrome()
        let subtitle = try Self.part(chrome, SnapSubtitleView.self)
        let ticker = try Self.part(chrome, SnapCommentTickerView.self)

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: Self.cues(2), commentCount: 2
        ))
        chrome.layoutIfNeeded()

        #expect(ticker.isHidden == true)
        #expect(subtitle.isHidden == false)
        // Seated where the band's BOTTOM is — the hole is gone.
        #expect(abs(subtitle.frame.maxY - ticker.frame.maxY) < 0.5)
    }

    /// With a band, the zone stacks on top of it exactly as before — one md
    /// above its top edge. Reduce Motion hides the band too, and it is the
    /// band's RESOLVED state that decides, so the assertion brackets both.
    @Test func theZoneStacksOnTheBandWhenItRenders() throws {
        let chrome = Self.chrome()
        let subtitle = try Self.part(chrome, SnapSubtitleView.self)
        let ticker = try Self.part(chrome, SnapCommentTickerView.self)

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: Self.reactions(8), subtitles: Self.cues(2), commentCount: 10
        ))
        chrome.layoutIfNeeded()

        let seat = ticker.isHidden ? ticker.frame.maxY : ticker.frame.minY - Spacing.md
        #expect(abs(subtitle.frame.maxY - seat) < 0.5)
    }

    /// The seat is a LIVE switch, not a one-shot: a page whose band arrives
    /// (or leaves) with a later stream re-seats the zone, and a recycled
    /// scaffold never keeps the previous post's seat.
    @Test func theSeatFollowsTheBandBothWays() throws {
        let chrome = Self.chrome()
        let subtitle = try Self.part(chrome, SnapSubtitleView.self)
        let ticker = try Self.part(chrome, SnapCommentTickerView.self)

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: Self.cues(2), commentCount: 2
        ))
        chrome.layoutIfNeeded()
        let seated = subtitle.frame.maxY

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: Self.reactions(8), subtitles: Self.cues(2), commentCount: 10
        ))
        chrome.layoutIfNeeded()
        guard !ticker.isHidden else { return } // Reduce Motion: no band either way
        #expect(subtitle.frame.maxY < seated) // lifted onto the band

        chrome.updateCommentStreams(FeedViewModel.CommentStreams(
            reactions: [], subtitles: Self.cues(2), commentCount: 2
        ))
        chrome.layoutIfNeeded()
        #expect(abs(subtitle.frame.maxY - seated) < 0.5) // and back down
    }

    /// The band keeps its frame through all of it. It is the corner's height
    /// authority — the "+" pins to its top and bottom edges and the rail's
    /// width derives from it — so collapsing it to close the gap would have
    /// taken the whole trailing column with it.
    @Test func theBandKeepsItsFrameSoTheCornerHoldsStill() throws {
        let chrome = Self.chrome()
        let ticker = try Self.part(chrome, SnapCommentTickerView.self)
        let compose = try Self.part(chrome, SnapRailComposeButton.self)
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

    /// A one-line pill is a CAPSULE. The zone renders reaction-shaped
    /// comments now, and a fixed 12pt corner on a ~30pt pill reads as a
    /// clipped rectangle rather than the chip the rest of this corner
    /// speaks in (the band's own clip, the count badge).
    @Test func shortCuesRenderAsCapsules() {
        for text in ["W", "GG", "🔥🔥", "so clean"] {
            let label = Self.pill(text)
            #expect(
                abs(label.layer.cornerRadius - label.bounds.height / 2) < 0.01,
                "\(text) should be a capsule"
            )
        }
    }

    /// A wrapped block keeps the softer block corner — a capsule there would
    /// bow away from the glyphs and read as a speech balloon.
    @Test func wrappedCuesKeepTheBlockCorner() {
        let label = SubtitlePillLabel()
        label.numberOfLines = 2
        label.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.medium)
        label.text = "A sentence long enough that it certainly has to wrap onto a second line here."
        let fitted = label.sizeThatFits(CGSize(width: 200, height: CGFloat.greatestFiniteMagnitude))
        label.frame = CGRect(x: 0, y: 0, width: 200, height: fitted.height)
        label.layoutIfNeeded()

        #expect(label.bounds.height > 40) // genuinely two lines
        #expect(label.layer.cornerRadius == SubtitlePillLabel.blockCornerRadius)
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
