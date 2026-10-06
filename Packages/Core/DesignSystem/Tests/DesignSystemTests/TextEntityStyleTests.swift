import Testing
import UIKit
@testable import DesignSystem

/// `@handle` and `#tag` styling over attributed text built elsewhere (#524).
@MainActor
@Suite("Text entity style")
struct TextEntityStyleTests {
    private func weight(of font: UIFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? CGFloat) ?? 0
    }

    private func styled(_ text: String, font: UIFont, style: TextEntityStyle) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.white])
        string.applyTextEntityStyle(style)
        return string
    }

    @Test func tokensAreMarkedWithWhatTheyName() {
        let string = styled("with @Alex at #Paris", font: .appFont(forTextStyle: .body), style: .link)
        #expect(string.attribute(.textEntity, at: 5, effectiveRange: nil) as? String == "@alex")
        #expect(string.attribute(.textEntity, at: 14, effectiveRange: nil) as? String == "#paris")
        #expect(string.attribute(.textEntity, at: 0, effectiveRange: nil) == nil)
    }

    @Test func aLinkIsColouredAndSemiboldTheRestUntouched() {
        let body = UIFont.appFont(forTextStyle: .body)
        let string = styled("hi @alex", font: body, style: .link)
        #expect(string.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? UIColor == .link)
        #expect(string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .white)
        let tokenFont = try? #require(string.attribute(.font, at: 4, effectiveRange: nil) as? UIFont)
        #expect(tokenFont.map(weight(of:)) == UIFont.Weight.semibold.rawValue)
        #expect(tokenFont?.pointSize == body.pointSize, "the size is the text's own")
    }

    @Test func overMediaOnlyTheWeightChanges() {
        let string = styled("hi @alex", font: .appFont(forTextStyle: .footnote), style: .emphasis)
        #expect(string.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? UIColor == .white)
        let tokenFont = string.attribute(.font, at: 4, effectiveRange: nil) as? UIFont
        #expect(tokenFont.map(weight(of:)) == UIFont.Weight.semibold.rawValue)
    }
}
