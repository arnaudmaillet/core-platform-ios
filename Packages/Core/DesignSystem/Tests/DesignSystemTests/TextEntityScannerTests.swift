import Foundation
import Testing
@testable import DesignSystem

/// `@handle` and `#tag` in user text, by the server's rules (#524).
@Suite("Text entity scanner")
struct TextEntityScannerTests {
    private func tokens(_ text: String) -> [String] {
        TextEntityScanner.entities(in: text).map { (text as NSString).substring(with: $0.range) }
    }

    private func values(_ text: String) -> [String] {
        TextEntityScanner.entities(in: text).map(\.value)
    }

    @Test func aCaptionsMentionAndTag() {
        let entities = TextEntityScanner.entities(in: "with @alex at #paris")
        #expect(entities.map(\.kind) == [.mention, .hashtag])
        #expect(entities.map(\.value) == ["alex", "paris"])
        #expect(entities.map(\.range) == [NSRange(location: 5, length: 5), NSRange(location: 14, length: 6)])
    }

    @Test func tokensAtTheStartAndTheEnd() {
        #expect(tokens("@alex") == ["@alex"])
        #expect(tokens("#paris") == ["#paris"])
        #expect(tokens("@alex #paris") == ["@alex", "#paris"])
    }

    @Test func trailingPunctuationIsNotPartOfTheToken() {
        #expect(tokens("thanks @alex.") == ["@alex"])
        #expect(tokens("thanks @alex_") == ["@alex"])
        #expect(tokens("#paris!") == ["#paris"])
        #expect(tokens("(@alex, #paris)") == ["@alex", "#paris"])
    }

    @Test func handlesKeepTheirInnerDotsAndUnderscores() {
        #expect(values("@kenji.dev and @mia_k") == ["kenji.dev", "mia_k"])
        #expect(values("@Kenji.Dev") == ["kenji.dev"], "handles are stored lowercased")
    }

    @Test func aHandleStopsWhereTheServerWouldRefuseIt() {
        #expect(values("@alex..b") == ["alex"])
        #expect(values("@alex._b") == ["alex"])
        #expect(tokens("@_alex").isEmpty)
        #expect(tokens("@a").isEmpty, "a handle is at least 2 characters")
        #expect(tokens("@" + String(repeating: "a", count: 31)).isEmpty, "and at most 30")
    }

    @Test func aSigilGluedToAWordIsNotOne() {
        #expect(tokens("mail me at a@b.com").isEmpty)
        #expect(tokens("x#1 y#tag").isEmpty)
        #expect(tokens("@@alex ##tag").isEmpty)
    }

    @Test func aLinkOwnsItsSigils() {
        #expect(tokens("https://example.com/@alex and https://example.com/page#top").isEmpty)
        #expect(values("follow @kenji.dev") == ["kenji.dev"], "a handle that reads as a domain is still a handle")
    }

    @Test func aTagNeedsALetter() {
        #expect(tokens("we're #1").isEmpty)
        #expect(values("#2026paris") == ["2026paris"])
    }

    @Test func tagsInAnyScript() {
        #expect(values("#東京 #café #Привет") == ["東京", "café", "привет"])
        #expect(values("#नमस्ते") == ["नमस्ते"], "combining marks stay in the tag")
    }

    @Test func emojiNextToATokenKeepTheRangesRight() {
        let text = "🎉@alex🔥 #paris✨"
        #expect(tokens(text) == ["@alex", "#paris"])
    }

    @Test func rightToLeftText() {
        #expect(values("مرحبا @alex #سلام") == ["alex", "سلام"])
    }

    @Test func plainTextHasNone() {
        #expect(TextEntityScanner.entities(in: "just a caption").isEmpty)
        #expect(TextEntityScanner.entities(in: "").isEmpty)
        #expect(tokens("@ alone and # alone").isEmpty)
    }
}
