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

    /// On a plain surface the token runs the icon's gradient (#1172): the
    /// sigil is the first stop, the last letter the last, the letters between
    /// in between — semibold, never the system blue, the rest untouched.
    @Test func aLinkRunsTheGradientAcrossItsLettersAndIsSemibold() {
        let body = UIFont.appFont(forTextStyle: .body)
        let string = styled("hi @alex", font: body, style: .link)
        func colour(at index: Int) -> UIColor? {
            string.attribute(.foregroundColor, at: index, effectiveRange: nil) as? UIColor
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            func resolved(_ colour: UIColor?) -> UIColor? { colour?.resolvedColor(with: traits) }
            #expect(resolved(colour(at: 3)) == resolved(Palette.entityGradient[0]), "the sigil starts it")
            #expect(resolved(colour(at: 7)) == resolved(Palette.entityGradient[1]), "the last letter ends it")
            #expect(resolved(colour(at: 5)) != resolved(colour(at: 3)) && resolved(colour(at: 5)) != resolved(colour(at: 7)),
                    "a middle letter sits between")
            #expect(resolved(colour(at: 4)) != UIColor.systemBlue.resolvedColor(with: traits))
        }
        #expect(colour(at: 0) == .white, "the text around keeps its own colour")
        let tokenFont = try? #require(string.attribute(.font, at: 4, effectiveRange: nil) as? UIFont)
        #expect(tokenFont.map(weight(of:)) == UIFont.Weight.semibold.rawValue)
        #expect(tokenFont?.pointSize == body.pointSize, "the size is the text's own")
    }

    /// A letter is a composed sequence: an accented letter is one step.
    @Test func aComposedLetterTakesOneColour() {
        let string = styled("#cafe\u{301}", font: .appFont(forTextStyle: .body), style: .link)
        let last = string.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? UIColor
        let mark = string.attribute(.foregroundColor, at: 5, effectiveRange: nil) as? UIColor
        let traits = UITraitCollection(userInterfaceStyle: .light)
        #expect(last?.resolvedColor(with: traits) == mark?.resolvedColor(with: traits))
        #expect(last?.resolvedColor(with: traits) == Palette.entityGradient[1].resolvedColor(with: traits))
    }

    /// Over a photograph or a video: the washed gradient (#1172).
    @Test func onMediaRunsTheWashedGradient() {
        let string = styled("hi @alex", font: .appFont(forTextStyle: .footnote), style: .onMedia)
        let traits = UITraitCollection(userInterfaceStyle: .dark)
        let first = (string.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? UIColor)?.resolvedColor(with: traits)
        #expect(first == Palette.entityGradientOnMedia[0].resolvedColor(with: traits))
        #expect(string.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .white)
    }

    /// Over a hero banner, whose ink the text chose: only the weight.
    @Test func overABannerOnlyTheWeightChanges() {
        let string = styled("hi @alex", font: .appFont(forTextStyle: .footnote), style: .emphasis)
        #expect(string.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? UIColor == .white)
        let tokenFont = string.attribute(.font, at: 4, effectiveRange: nil) as? UIFont
        #expect(tokenFont.map(weight(of:)) == UIFont.Weight.semibold.rawValue)
    }
}
