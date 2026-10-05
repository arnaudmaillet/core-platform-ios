import Testing
import UIKit
@testable import Maps

/// The offer's header, laid out as the sound sheet's: the large round flag
/// with the rank in a bubble over it, beside three lines — the name, the
/// continent, and the likes and posts as a small meta line.
@MainActor
struct CountryUnlockHeaderTests {
    private static let width: CGFloat = 370

    private func layOut(_ code: String, standing: CountryStanding? = nil) throws -> UIView {
        let country = try #require(CountryAtlas.shared.country(code: code))
        let header = CountryUnlockSheetViewController.header(
            country: country,
            standing: standing ?? CountryStanding(code: code, rank: 4, likes: 8_700, posts: 86, price: 50)
        )
        let size = header.systemLayoutSizeFitting(
            CGSize(width: Self.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        header.frame = CGRect(origin: .zero, size: size)
        header.layoutIfNeeded()
        return header
    }

    private func label(_ text: String, in view: UIView) throws -> UILabel {
        try #require(Self.descendants(of: view).compactMap { $0 as? UILabel }.first {
            ($0.attributedText?.string ?? $0.text) == text
        }, "no label reads \"\(text)\"")
    }

    private func view(_ identifier: String, in header: UIView) throws -> UIView {
        try #require(Self.descendants(of: header).first { $0.accessibilityIdentifier == identifier })
    }

    private func frame(of view: UIView, in header: UIView) -> CGRect {
        view.convert(view.bounds, to: header)
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    @Test func theFlagIsTheLargeRoundPictureAtTheSoundArtworksSize() throws {
        let header = try layOut("ES")
        let flagView = try #require(try view("country.unlock.flag", in: header) as? UIImageView)
        let large = try #require(FlagPalette.largeRoundFlag(for: "ES"))
        #expect(flagView.image === large, "not the 96pt round flag")
        let flag = frame(of: flagView, in: header)
        #expect(flag.size == CGSize(width: 96, height: 96))
        #expect(flag.minX == 0)
        // Centred on the lines beside it, as the sound's artwork is.
        let name = frame(of: try label("Spain", in: header), in: header)
        let meta = frame(of: try label("8.7K · 86 posts", in: header), in: header)
        #expect(abs(flag.midY - (name.minY + meta.maxY) / 2) < 1, "the flag is not centred on its lines")
    }

    @Test func nameContinentAndCountersAreThreeLinesFromOneLeadingEdge() throws {
        let header = try layOut("ES")
        let name = frame(of: try label("Spain", in: header), in: header)
        let continent = frame(of: try label("Europe", in: header), in: header)
        let meta = frame(of: try label("8.7K · 86 posts", in: header), in: header)
        let heart = try #require(Self.descendants(of: header).first {
            $0 is UIImageView && $0.accessibilityIdentifier == nil
        })
        #expect(continent.minY >= name.maxY - 0.5 && meta.minY >= continent.maxY - 0.5, "the lines are out of order")
        #expect(abs(continent.minX - name.minX) < 0.5)
        #expect(abs(frame(of: heart, in: header).minX - name.minX) < 0.5, "the counters are not leading")
        #expect(meta.minX > frame(of: heart, in: header).maxX, "the heart is not before the figures")
        // Smaller than the name: a meta line, not a band of metrics.
        let metaLabel = try label("8.7K · 86 posts", in: header)
        let nameLabel = try label("Spain", in: header)
        let metaFont = try #require(metaLabel.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect(metaFont.pointSize < nameLabel.font.pointSize)
        #expect(metaLabel.accessibilityLabel == "8.7K likes, 86 posts")
    }

    /// The rank is not a counter: it rides the flag's bottom-trailing edge.
    @Test func theRankIsABubbleOverTheFlagsBottomTrailingEdge() throws {
        let header = try layOut("ES")
        let flag = frame(of: try view("country.unlock.flag", in: header), in: header)
        let bubbleView = try view("country.unlock.rank", in: header)
        let bubble = frame(of: bubbleView, in: header)
        let name = frame(of: try label("Spain", in: header), in: header)
        _ = try label("#4", in: bubbleView)
        #expect(bubble.intersects(flag), "the bubble is off the flag")
        #expect(bubble.midX > flag.midX && bubble.midY > flag.midY, "the bubble is not on the bottom-trailing quarter")
        #expect(bubble.maxX > flag.maxX - 0.5, "the bubble does not reach the rim")
        #expect(bubble.maxX < name.minX, "the bubble runs into the lines")
        #expect(bubbleView.accessibilityLabel == "Rank 4")
        let others = Self.descendants(of: header).compactMap { $0 as? UILabel }.filter { !$0.isDescendant(of: bubbleView) }
        #expect(!others.contains { ($0.attributedText?.string ?? "").contains("#") }, "the rank is still a counter")
    }

    /// A three-digit rank is spelled out in full, never "#…".
    @Test func aWideRankIsNeverTruncated() throws {
        let header = try layOut("CF", standing: CountryStanding(code: "CF", rank: 126, likes: 8_700, posts: 5, price: 15))
        let rank = try label("#126", in: header)
        #expect(rank.bounds.width >= rank.intrinsicContentSize.width - 0.5, "the rank is truncated")
        let name = frame(of: try label("Central African Republic", in: header), in: header)
        #expect(frame(of: rank, in: header).maxX < name.minX, "the bubble runs into the lines")
    }

    /// One line each: a long name truncates, and the header keeps its height.
    @Test func aLongNameTruncatesOnOneLine() throws {
        let short = try layOut("ES")
        let long = try layOut("GS")
        let name = try label("South Georgia and the South Sandwich Islands", in: long)
        #expect(name.numberOfLines == 1)
        #expect(frame(of: name, in: long).maxX <= Self.width + 0.5)
        #expect(long.bounds.height == short.bounds.height, "a long name changed the header's height")
    }

    @Test func aSinglePostIsOnePost() throws {
        let header = try layOut("ES", standing: CountryStanding(code: "ES", rank: 9, likes: 3, posts: 1, price: 15))
        _ = try label("3 · 1 post", in: header)
    }
}
