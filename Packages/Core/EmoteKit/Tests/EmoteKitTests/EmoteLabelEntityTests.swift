import DesignSystem
import Testing
import UIKit
@testable import EmoteKit

/// `@handle`s and `#tag`s in a label fed plain `text` (#524).
@MainActor
@Suite(.serialized, .sharesMainThread)
struct EmoteLabelEntityTests {
    private func weight(at index: Int, in label: UILabel) -> CGFloat {
        let font = label.attributedText?.attribute(.font, at: index, effectiveRange: nil) as? UIFont
        let traits = font?.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat) ?? 0
    }

    private func entity(at index: Int, in label: UILabel) -> String? {
        label.attributedText?.attribute(.textEntity, at: index, effectiveRange: nil) as? String
    }

    @Test func withoutAStyleTokensStayPlain() {
        let label = EmoteLabel()
        label.text = "with @alex"
        #expect(entity(at: 5, in: label) == nil)
    }

    @Test func withAStyleTokensAreMarkedAndSemibold() {
        let label = EmoteLabel()
        label.font = .systemFont(ofSize: 17)
        label.textEntityStyle = .emphasis
        label.text = "with @alex at #paris"
        #expect(label.text == "with @alex at #paris")
        #expect(entity(at: 5, in: label) == "@alex")
        #expect(entity(at: 14, in: label) == "#paris")
        #expect(weight(at: 6, in: label) == UIFont.Weight.semibold.rawValue)
        #expect(weight(at: 0, in: label) != UIFont.Weight.semibold.rawValue)
    }

    /// `UILabel` applies a new font over the whole string: the label rebuilds
    /// so the tokens keep their weight, at the new size.
    @Test func aNewFontKeepsTheTokensStyled() {
        let label = EmoteLabel()
        label.font = .systemFont(ofSize: 17)
        label.textEntityStyle = .emphasis
        label.text = "hi @alex"
        label.font = .systemFont(ofSize: 24)
        let font = label.attributedText?.attribute(.font, at: 4, effectiveRange: nil) as? UIFont
        #expect(font?.pointSize == 24)
        #expect(weight(at: 4, in: label) == UIFont.Weight.semibold.rawValue)
    }

    @Test func aNewColourKeepsTheTokensMarked() {
        let label = EmoteLabel()
        label.textEntityStyle = .emphasis
        label.text = "hi @alex"
        label.textColor = .systemRed
        #expect(entity(at: 4, in: label) == "@alex")
        #expect(label.attributedText?.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? UIColor == .systemRed)
    }

    @Test func plainTextAfterwardsDropsTheMarks() {
        let label = EmoteLabel()
        label.textEntityStyle = .emphasis
        label.text = "hi @alex"
        label.text = "nothing here"
        #expect(entity(at: 0, in: label) == nil)
        label.font = .systemFont(ofSize: 30)
        #expect(label.text == "nothing here", "a font change does not bring the old text back")
    }
}
