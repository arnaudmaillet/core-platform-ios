import Testing
import UIKit
@testable import DesignSystem

/// Which token a tap lands on, laid out as the label lays it out (#524).
@MainActor
@Suite("Text entity links")
struct TextEntityLinksTests {
    private func label(_ text: String, width: CGFloat = 300) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        let string = NSMutableAttributedString(string: text, attributes: [.font: UIFont.systemFont(ofSize: 17)])
        string.applyTextEntityStyle(.link)
        label.attributedText = string
        label.frame = CGRect(origin: .zero, size: label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)))
        return label
    }

    /// The centre of the glyphs at `range`, as TextKit places them.
    private func point(of range: NSRange, in label: UILabel) -> CGPoint {
        let storage = NSTextStorage(attributedString: label.attributedText!)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: label.bounds.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    @Test func aTapOnATokenNamesIt() {
        let label = label("ride with @priya.raman to #trailrunning")
        #expect(TextEntityLinks.token(at: point(of: NSRange(location: 11, length: 5), in: label), in: label) == "@priya.raman")
        #expect(TextEntityLinks.token(at: point(of: NSRange(location: 27, length: 4), in: label), in: label) == "#trailrunning")
    }

    @Test func aTapOffEveryTokenIsAMiss() {
        let label = label("ride with @priya.raman")
        #expect(TextEntityLinks.token(at: point(of: NSRange(location: 0, length: 4), in: label), in: label) == nil)
        #expect(TextEntityLinks.token(at: CGPoint(x: label.bounds.maxX + 50, y: label.bounds.midY), in: label) == nil)
    }

    @Test func aTokenOnASecondLineIsFoundThere() {
        let label = label("a fairly long first line of text, then @alex", width: 160)
        #expect(label.bounds.height > 30, "the text wraps")
        let range = NSRange(location: 40, length: 4)
        #expect(TextEntityLinks.token(at: point(of: range, in: label), in: label) == "@alex")
    }

    @Test func theSigilSaysTheKind() {
        #expect(TextEntityLinks.kind(of: "@alex") == .mention)
        #expect(TextEntityLinks.kind(of: "#paris") == .hashtag)
    }
}
