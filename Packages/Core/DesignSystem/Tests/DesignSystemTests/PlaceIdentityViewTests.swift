import Testing
import UIKit
@testable import DesignSystem

/// The place identity row, as the unlock sheet and the place page draw it:
/// the round flag with the rank in a bubble over it, and beside it, centred
/// on it, the name (its subtitle after it, or under it when the two do not
/// fit) over the counters — each a figure over its word, in the first of four
/// equal parts.
@MainActor
struct PlaceIdentityViewTests {
    private static let width: CGFloat = 370

    private static let flag = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
        UIColor.red.setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 96, height: 96))
    }

    private func layOut(
        name: String = "Spain", subtitle: String? = "Europe",
        counters: [PlaceIdentityView.Counter] = [.init(value: "8.7K", caption: "Likes"), .init(value: "86", caption: "Posts")],
        rank: String? = "#4", flag: UIImage? = PlaceIdentityViewTests.flag
    ) -> PlaceIdentityView {
        let view = PlaceIdentityView(flag: flag, name: name, subtitle: subtitle, counters: counters, rank: rank)
        let size = view.systemLayoutSizeFitting(
            CGSize(width: Self.width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        return view
    }

    private func frame(of view: UIView, in identity: UIView) -> CGRect {
        view.convert(view.bounds, to: identity)
    }

    private func stat(_ caption: String, in identity: PlaceIdentityView) throws -> PlaceStatView {
        try #require(identity.statViews.first { $0.captionLabel.text == caption }, "no \(caption) column")
    }

    @Test func theFlagStandsWhereTheAvatarDoes() {
        let identity = layOut()
        let flag = frame(of: identity.flagView, in: identity)
        #expect(flag.size == CGSize(width: 96, height: 96))
        #expect(flag.minX == 0)
        #expect(identity.flagView.layer.cornerRadius == 48, "the disc is not round")
    }

    @Test func aPlaceWithNoFlagWearsANeutralDisc() {
        let identity = layOut(flag: nil)
        #expect(identity.flagView.image == nil)
        #expect(identity.flagView.backgroundColor == .tertiarySystemFill)
    }

    /// On two lines the block is the flag's height: the name level with the
    /// disc's top, the counters with its foot, as on the profile.
    @Test func aTwoLineTitleAndItsCountersSpanTheFlag() throws {
        let identity = layOut(name: "Central African Republic", subtitle: "Africa")
        #expect(!identity.titleLabel.subtitleFollowsName)
        let flag = frame(of: identity.flagView, in: identity)
        let title = frame(of: identity.titleLabel, in: identity)
        let likes = frame(of: try stat("Likes", in: identity), in: identity)
        #expect(abs((title.minY + likes.maxY) / 2 - flag.midY) < 0.5, "the block is not centred on the flag")
        #expect(abs(title.minY - flag.minY) < 4, "the name is not level with the flag's top")
        #expect(abs(likes.maxY - flag.maxY) < 4, "the counters are not level with the flag's foot")
    }

    /// A title on one line stands where the middle of a two-line one does,
    /// and its counters come up by half the line it does not take.
    @Test func aOneLineTitleKeepsItsMiddleAndRaisesTheCounters() throws {
        let oneLine = layOut()
        let twoLines = layOut(name: "Central African Republic", subtitle: "Africa")
        #expect(oneLine.titleLabel.subtitleFollowsName)
        let short = frame(of: oneLine.titleLabel, in: oneLine)
        let wrapped = frame(of: twoLines.titleLabel, in: twoLines)
        #expect(abs(short.midY - wrapped.midY) < 0.5, "the title's middle moved with its length")
        let lineSaved = wrapped.height - short.height
        #expect(lineSaved > 10, "the one-line title is not shorter")
        let shortCounters = frame(of: try stat("Likes", in: oneLine), in: oneLine)
        let wrappedCounters = frame(of: try stat("Likes", in: twoLines), in: twoLines)
        #expect(abs((wrappedCounters.minY - shortCounters.minY) - lineSaved / 2) < 0.5,
                "the counters did not come up by half a line")
    }

    @Test func aShortNameKeepsItsSubtitleOnItsLine() {
        let identity = layOut()
        #expect(identity.titleLabel.attributedText?.string == "Spain  Europe")
        #expect(identity.titleLabel.accessibilityLabel == "Spain, Europe")
        #expect(identity.titleLabel.accessibilityTraits.contains(.header))
    }

    @Test func aNameTooWideForItsSubtitlePutsItOnTheNextLine() {
        let identity = layOut(name: "Central African Republic", subtitle: "Africa")
        #expect(identity.titleLabel.attributedText?.string == "Central African Republic\nAfrica")
    }

    @Test func noSubtitleIsTheNameAlone() {
        let identity = layOut(name: "Paris", subtitle: nil)
        #expect(identity.titleLabel.attributedText?.string == "Paris")
        #expect(identity.titleLabel.accessibilityLabel == "Paris")
    }

    /// The name is ONE line, cut with "…" when even alone it is too wide;
    /// the subtitle stands under it, the header no taller than any two-line
    /// title's.
    @Test func theLongestNameIsCutToOneLine() throws {
        let identity = layOut(name: "South Georgia and the South Sandwich Islands", subtitle: "Seven seas (open ocean)")
        let label = identity.titleLabel
        let lines = try #require(label.attributedText?.string).components(separatedBy: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("South Georgia") && lines[0].hasSuffix("…"), "\(lines[0])")
        #expect(lines[1] == "Seven seas (open ocean)")
        #expect(frame(of: label, in: identity).maxX <= Self.width + 0.5)
        let wrapped = layOut(name: "Central African Republic", subtitle: "Africa")
        #expect(identity.bounds.height == wrapped.bounds.height, "the long name took more than one line")
    }

    @Test func cutKeepsWhatFitsAndOnlyThat() {
        let font = UIFont.systemFont(ofSize: 17)
        #expect(PlaceTitleLabel.cut("Spain", font: font, to: 200) == "Spain")
        let cut = PlaceTitleLabel.cut("South Georgia and the South Sandwich Islands", font: font, to: 120)
        #expect(cut.hasSuffix("…") && cut.count > 3)
        #expect((cut as NSString).size(withAttributes: [.font: font]).width <= 120)
    }

    /// The profile's columns: the figure over its word.
    @Test func eachCounterIsAFigureOverItsWord() throws {
        let identity = layOut()
        for (caption, value) in [("Likes", "8.7K"), ("Posts", "86")] {
            let column = try stat(caption, in: identity)
            #expect(column.valueLabel.text == value)
            let figure = frame(of: column.valueLabel, in: identity)
            let word = frame(of: column.captionLabel, in: identity)
            #expect(word.minY >= figure.maxY - 0.5, "\(caption): the word is not under the figure")
            #expect(abs(figure.midX - word.midX) < 0.5, "\(caption): not centred on each other")
            #expect(column.captionLabel.font.pointSize < column.valueLabel.font.pointSize)
            #expect(column.accessibilityLabel == caption && column.accessibilityValue == value)
        }
    }

    /// Four equal parts across the column: the counters centred in the first
    /// ones, in order, the rest free.
    @Test func theCountersStandInTheFirstOfFourEqualParts() throws {
        let identity = layOut()
        let title = frame(of: identity.titleLabel, in: identity)
        let parts = identity.countersRow.arrangedSubviews.map { frame(of: $0, in: identity) }
        try #require(parts.count == 4)
        let quarter = (Self.width - title.minX) / 4
        for (index, part) in parts.enumerated() {
            #expect(abs(part.width - quarter) < 0.5, "part \(index) is not a quarter")
            #expect(abs(part.minX - (title.minX + CGFloat(index) * quarter)) < 0.5, "part \(index) is out of place")
        }
        #expect(abs(frame(of: try stat("Likes", in: identity), in: identity).midX - parts[0].midX) < 0.5)
        #expect(abs(frame(of: try stat("Posts", in: identity), in: identity).midX - parts[1].midX) < 0.5)
    }

    @Test func newFiguresKeepTheirWords() throws {
        let identity = layOut()
        identity.setCounterValues(["57", "3"])
        #expect(try stat("Likes", in: identity).valueLabel.text == "57")
        #expect(try stat("Posts", in: identity).accessibilityValue == "3")
    }

    /// The rank is not a counter: it rides the flag's bottom-trailing edge.
    @Test func theRankIsABubbleOverTheFlagsBottomTrailingEdge() {
        let identity = layOut()
        let flag = frame(of: identity.flagView, in: identity)
        let bubble = frame(of: identity.rankBubble, in: identity)
        let title = frame(of: identity.titleLabel, in: identity)
        #expect(identity.rankBubble.label.text == "#4")
        #expect(bubble.intersects(flag), "the bubble is off the flag")
        #expect(bubble.midX > flag.midX && bubble.midY > flag.midY, "the bubble is not on the bottom-trailing quarter")
        #expect(bubble.maxX > flag.maxX - 0.5, "the bubble does not reach the rim")
        #expect(bubble.maxX < title.minX, "the bubble runs into the lines")
        #expect(identity.rankBubble.accessibilityLabel == "Rank 4")
    }

    @Test func aWideRankIsNeverTruncated() {
        let identity = layOut(name: "Central African Republic", subtitle: "Africa", rank: "#126")
        let label = identity.rankBubble.label
        #expect(label.bounds.width >= label.intrinsicContentSize.width - 0.5, "the rank is truncated")
        #expect(frame(of: label, in: identity).maxX < frame(of: identity.titleLabel, in: identity).minX)
    }

    @Test func noRankHidesTheBubble() {
        #expect(layOut(rank: nil).rankBubble.isHidden)
    }

    /// On a picture each half wears the picture's ink; back on the page, the
    /// page's.
    @Test func eachHalfWearsTheInkItIsGiven() throws {
        let identity = layOut()
        identity.setTitleInk(.light)
        identity.setCountersInk(.dark)
        let title = try #require(identity.titleLabel.attributedText)
        #expect(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .white)
        #expect(try stat("Likes", in: identity).valueLabel.textColor == .black)
        #expect(identity.titleLabel.layer.shadowOpacity > 0)
        identity.setTitleInk(nil)
        let page = try #require(identity.titleLabel.attributedText)
        #expect(page.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .label)
        #expect(identity.titleLabel.layer.shadowOpacity == 0)
    }
}
