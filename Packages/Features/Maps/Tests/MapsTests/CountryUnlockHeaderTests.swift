import Testing
import UIKit
@testable import Maps

/// The offer's header, laid out as the profile's identity row: the large
/// round flag with the rank in a bubble over it, beside two halves — the name
/// (the continent after it, or under it when the two do not fit) over the
/// counters, each a figure over its word.
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

    private func title(in header: UIView) throws -> CountryTitleLabel {
        try #require(Self.descendants(of: header).compactMap { $0 as? CountryTitleLabel }.first)
    }

    private func stat(_ caption: String, in header: UIView) throws -> CountryStatView {
        try #require(Self.descendants(of: header).compactMap { $0 as? CountryStatView }.first {
            $0.captionLabel.text == caption
        }, "no \(caption) column")
    }

    @Test func theFlagIsTheLargeRoundPictureAtTheAvatarsSize() throws {
        let header = try layOut("ES")
        let flagView = try #require(try view("country.unlock.flag", in: header) as? UIImageView)
        let large = try #require(FlagPalette.largeRoundFlag(for: "ES"))
        #expect(flagView.image === large, "not the 96pt round flag")
        let flag = frame(of: flagView, in: header)
        #expect(flag.size == CGSize(width: 96, height: 96))
        #expect(flag.minX == 0 && flag.minY == 0)
    }

    /// The profile's halves: the name level with the flag's top, the counters
    /// level with its foot.
    @Test func theNameTopsTheFlagAndTheCountersFootIt() throws {
        let header = try layOut("ES")
        let flag = frame(of: try view("country.unlock.flag", in: header), in: header)
        let title = frame(of: try title(in: header), in: header)
        let likes = frame(of: try stat("Likes", in: header), in: header)
        let posts = frame(of: try stat("Posts", in: header), in: header)
        #expect(abs(title.minY - flag.minY) < 0.5, "the name is not level with the flag's top")
        #expect(abs(likes.maxY - flag.maxY) < 0.5, "the counters are not level with the flag's foot")
        #expect(abs(likes.minX - title.minX) < 0.5, "the counters are not leading under the name")
        #expect(likes.maxX < posts.minX)
        #expect(posts.maxX < Self.width - 100, "the counters drifted to the trailing edge")
    }

    /// The profile's columns: the figure over its word — "Likes", not a heart.
    @Test func eachCounterIsAFigureOverItsWord() throws {
        let header = try layOut("ES")
        for (caption, value) in [("Likes", "8.7K"), ("Posts", "86")] {
            let column = try stat(caption, in: header)
            #expect(column.valueLabel.text == value)
            let figure = frame(of: column.valueLabel, in: header)
            let word = frame(of: column.captionLabel, in: header)
            #expect(word.minY >= figure.maxY - 0.5, "\(caption): the word is not under the figure")
            #expect(abs(figure.midX - word.midX) < 0.5, "\(caption): not centred on each other")
            #expect(column.captionLabel.font.pointSize < column.valueLabel.font.pointSize)
            #expect(column.accessibilityLabel == caption && column.accessibilityValue == value)
        }
        #expect(!Self.descendants(of: header).contains {
            ($0 as? UIImageView)?.image?.description.contains("heart") == true
        }, "a heart is back")
    }

    @Test func aShortNameKeepsTheContinentOnItsLine() throws {
        let header = try layOut("ES")
        let label = try title(in: header)
        #expect(label.continentFollowsName)
        #expect(label.attributedText?.string == "Spain  Europe")
        // One line: as tall as the name's own line.
        #expect(label.bounds.height < label.font.lineHeight * 2)
    }

    @Test func aNameTooWideForTheContinentPutsItOnTheNextLine() throws {
        let header = try layOut("CF")
        let label = try title(in: header)
        #expect(!label.fitsOneLine(label.bounds.width), "the case does not hold at this width")
        #expect(!label.continentFollowsName)
        #expect(label.attributedText?.string == "Central African Republic\nAfrica")
        #expect(frame(of: label, in: header).maxX <= Self.width + 0.5)
    }

    /// The rank is not a counter: it rides the flag's bottom-trailing edge.
    @Test func theRankIsABubbleOverTheFlagsBottomTrailingEdge() throws {
        let header = try layOut("ES")
        let flag = frame(of: try view("country.unlock.flag", in: header), in: header)
        let bubbleView = try view("country.unlock.rank", in: header)
        let bubble = frame(of: bubbleView, in: header)
        let name = frame(of: try title(in: header), in: header)
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
        let name = frame(of: try title(in: header), in: header)
        #expect(frame(of: rank, in: header).maxX < name.minX, "the bubble runs into the lines")
    }

    /// The name is ONE line, cut with "…" when even alone it is too wide;
    /// the continent stands under it, and the header is no taller than for
    /// any other two-line title.
    @Test func theLongestNameIsCutToOneLine() throws {
        let header = try layOut("GS")
        let label = try title(in: header)
        #expect(!label.continentFollowsName)
        let lines = try #require(label.attributedText?.string).components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("South Georgia") && lines[0].hasSuffix("…"), "\(lines[0])")
        #expect(lines[1] == "Seven seas (open ocean)")
        let nameFont = try #require(label.attributedText?.attribute(.font, at: 0, effectiveRange: nil) as? UIFont)
        #expect((lines[0] as NSString).size(withAttributes: [.font: nameFont]).width <= label.bounds.width + 0.5,
                "the cut name is still wider than its line")
        #expect(frame(of: label, in: header).maxX <= Self.width + 0.5)
        // As tall as a name that merely pushed its continent down.
        let wrapped = try layOut("CF")
        #expect(header.bounds.height == wrapped.bounds.height, "the long name took more than one line")
        let flag = frame(of: try view("country.unlock.flag", in: header), in: header)
        #expect(flag.size == CGSize(width: 96, height: 96), "the column outgrew the flag")
    }

    @Test func cutKeepsWhatFitsAndOnlyThat() {
        let font = UIFont.systemFont(ofSize: 17)
        #expect(CountryTitleLabel.cut("Spain", font: font, to: 200) == "Spain")
        let cut = CountryTitleLabel.cut("South Georgia and the South Sandwich Islands", font: font, to: 120)
        #expect(cut.hasSuffix("…") && cut.count > 3)
        #expect((cut as NSString).size(withAttributes: [.font: font]).width <= 120)
    }

    @Test func aSinglePostIsOnePost() throws {
        let header = try layOut("ES", standing: CountryStanding(code: "ES", rank: 9, likes: 3, posts: 1, price: 15))
        #expect(try stat("Post", in: header).valueLabel.text == "1")
    }
}
