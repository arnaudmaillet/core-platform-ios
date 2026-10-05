import Testing
import UIKit
@testable import Maps

/// The offer's header: the round flag on two lines with the rank in a bubble
/// over it, the name and its continent on the first line, the likes and
/// posts on the second, from the leading edge.
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

    private func frame(of view: UIView, in header: UIView) -> CGRect {
        view.convert(view.bounds, to: header)
    }

    private static func descendants(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    @Test func theFlagIsTheRoundPictureAsTallAsBothLines() throws {
        let header = try layOut("ES")
        let flag = try #require(Self.descendants(of: header).first {
            $0.accessibilityIdentifier == "country.unlock.flag"
        } as? UIImageView)
        #expect(flag.image === FlagPalette.image(for: "ES"))
        #expect(FlagPalette.entry(for: "ES").isRound, "an atlas country fell back to its emoji")

        let flagFrame = frame(of: flag, in: header)
        let name = frame(of: try label("Spain", in: header), in: header)
        let posts = frame(of: try label("86 posts", in: header), in: header)
        #expect(flagFrame.minX == 0)
        #expect(flagFrame.width == flagFrame.height, "the disc is not round")
        // Two lines: the disc spans from the name's top to the counters' foot.
        #expect(abs(flagFrame.height - header.bounds.height) < 0.5)
        #expect(flagFrame.minY <= name.minY + 0.5)
        #expect(flagFrame.maxY >= posts.maxY - 0.5)
    }

    @Test func theNameAndContinentShareTheFirstLineAndTheCountersStartUnderTheName() throws {
        let header = try layOut("ES")
        let name = frame(of: try label("Spain", in: header), in: header)
        let continent = frame(of: try label("Europe", in: header), in: header)
        let likes = frame(of: try label("8.7K", in: header), in: header)
        let posts = frame(of: try label("86 posts", in: header), in: header)

        #expect(continent.minX > name.maxX, "the continent is not beside the name")
        #expect(continent.minY < name.maxY, "the continent dropped under the name")
        for counter in [likes, posts] {
            #expect(counter.minY >= name.maxY - 0.5, "a counter sits on the name's line")
        }
        #expect(likes.maxX < posts.minX, "the counters are out of order")
        // Leading: the heart lines up with the name's first letter.
        let heart = try #require(Self.descendants(of: header).first { $0 is UIImageView && $0.accessibilityIdentifier == nil })
        #expect(abs(frame(of: heart, in: header).minX - name.minX) < 0.5, "the counters are not leading")
        #expect(posts.maxX < Self.width - 50, "the counters drifted to the trailing edge")
    }

    /// The rank is not a counter: it rides the flag's bottom-trailing edge.
    @Test func theRankIsABubbleOverTheFlagsBottomTrailingEdge() throws {
        let header = try layOut("ES")
        let all = Self.descendants(of: header)
        let flag = frame(of: try #require(all.first { $0.accessibilityIdentifier == "country.unlock.flag" }), in: header)
        let bubbleView = try #require(all.first { $0.accessibilityIdentifier == "country.unlock.rank" })
        let bubble = frame(of: bubbleView, in: header)
        let name = frame(of: try label("Spain", in: header), in: header)
        _ = try label("#4", in: bubbleView)
        #expect(bubble.intersects(flag), "the bubble is off the flag")
        #expect(bubble.midX > flag.midX && bubble.midY > flag.midY, "the bubble is not on the bottom-trailing quarter")
        #expect(bubble.maxX > flag.maxX - 0.5, "the bubble does not reach the rim")
        #expect(bubble.maxX < name.minX, "the bubble runs into the name")
        #expect(bubbleView.accessibilityLabel == "Rank 4")
        let counters = all.compactMap { $0 as? UILabel }.filter { !$0.isDescendant(of: bubbleView) }
        #expect(!counters.contains { ($0.attributedText?.string ?? "").hasPrefix("#") }, "the rank is still a counter")
    }

    @Test func aLongNameKeepsItsRoomAndTheContinentGivesWay() throws {
        let header = try layOut("GS")
        let name = frame(of: try label("South Georgia and the South Sandwich Islands", in: header), in: header)
        let continent = frame(of: try label("Seven seas (open ocean)", in: header), in: header)
        #expect(name.width > continent.width * 3, "the continent kept its width at the name's expense")
        #expect(name.maxX <= Self.width + 0.5)
    }

    /// A three-digit rank is spelled out in full, never "#…".
    @Test func aWideRankIsNeverTruncated() throws {
        let header = try layOut("CF", standing: CountryStanding(code: "CF", rank: 126, likes: 8_700, posts: 5, price: 15))
        let rank = try label("#126", in: header)
        #expect(rank.bounds.width >= rank.intrinsicContentSize.width - 0.5, "the rank is truncated")
        let name = frame(of: try label("Central African Republic", in: header), in: header)
        #expect(frame(of: rank, in: header).maxX < name.minX, "the bubble runs into the name")
    }

    @Test func aSinglePostIsOnePost() throws {
        let header = try layOut("ES", standing: CountryStanding(code: "ES", rank: 9, likes: 3, posts: 1, price: 15))
        _ = try label("1 post", in: header)
    }
}
