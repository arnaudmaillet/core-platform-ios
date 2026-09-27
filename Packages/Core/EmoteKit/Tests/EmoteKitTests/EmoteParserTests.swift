import Foundation
import Testing
import UIKit
@testable import EmoteKit

/// Parsing: which characters are emotes, and what stays exactly as typed.
struct EmoteParserTests {
    private let catalog = EmoteCatalog.shared

    private func ids(_ text: String) -> [String] {
        EmoteParser.matches(in: text, catalog: catalog).map(\.emote.id)
    }

    @Test func plainTextHasNoEmotesAndSkipsTheScan() {
        #expect(!EmoteParser.mayContainEmotes("Golden hour over the harbour."))
        #expect(ids("Golden hour over the harbour.").isEmpty)
    }

    @Test func anEmojiIsFoundWhereItIsWritten() throws {
        let text = "fire 🔥 now"
        let match = try #require(EmoteParser.matches(in: text, catalog: catalog).first)
        #expect(match.emote.id == "noto:1f525")
        #expect(!match.isCode)
        #expect(String(text[match.range]) == "🔥")
    }

    /// Adjacent emoji are two emotes, not one run.
    @Test func adjacentEmojiAreSeparate() {
        #expect(ids("🔥🔥😂") == ["noto:1f525", "noto:1f525", "noto:1f602"])
    }

    /// U+FE0F asks for the picture; U+FE0E asks for text, and a bare
    /// text-default scalar draws as text too.
    @Test func variationSelectorsDecidePresentation() {
        #expect(ids("❤️") == ["noto:2764_fe0f"])
        #expect(ids("❤").isEmpty)
        #expect(ids("❤\u{FE0E}").isEmpty)
        #expect(ids("☺️") == ["noto:263a_fe0f"])
    }

    /// A modified emoji is another emoji: it stays static rather than
    /// animating its base beside a stray modifier.
    @Test func skinTonesAndSequencesStayStatic() {
        #expect(ids("👍") == ["noto:1f44d"])
        #expect(ids("👍🏽").isEmpty)
        #expect(ids("👨‍👩‍👧").isEmpty)
        #expect(ids("❤️‍🔥").isEmpty)
        #expect(ids("🇫🇷").isEmpty)
        #expect(ids("1️⃣").isEmpty)
        // …and does not swallow a neighbour.
        #expect(ids("👍🏽🔥") == ["noto:1f525"])
    }

    @Test func houseCodesAreFoundIgnoringCase() throws {
        let text = "ha :lol: and :LMAO:"
        let matches = EmoteParser.matches(in: text, catalog: catalog)
        #expect(matches.map(\.emote.id) == ["lol", "lmao"])
        #expect(matches.allSatisfy { $0.isCode })
        let first = try #require(matches.first)
        #expect(String(text[first.range]) == ":lol:")
    }

    /// Unknown codes, times and URLs are left exactly as typed.
    @Test func thingsThatLookLikeCodesStayText() {
        #expect(ids(":nope: 10:30:45 https://example.com :lol").isEmpty)
        #expect(ids(":1lol:").isEmpty)
        #expect(ids(": lol :").isEmpty)
        // A stray colon before a real code does not hide it.
        #expect(ids("::lol:") == ["lol"])
        #expect(ids("see :nope:lol:") == ["lol"])
    }

    @Test func everyHouseEmoteParsesFromItsInsertionText() {
        for emote in EmoteCatalog.house {
            #expect(ids(emote.insertionText) == [emote.id], "\(emote.insertionText)")
        }
    }

    /// Every Noto entry parses from its own glyph — the catalogue and the
    /// parser agree on every key, selector or not.
    @Test func everyNotoEmojiParsesFromItsGlyph() {
        let noto = catalog.all.filter(\.isUnicodeEmoji)
        #expect(noto.count >= 200)
        for emote in noto {
            #expect(ids(emote.glyph) == [emote.id], "\(emote.glyph) \(emote.id)")
        }
    }

    @Test func displayStringReplacesKnownCodesOnly() {
        #expect(EmoteText.displayString(":lol: hi :nope:", catalog: catalog) == "😆 hi :nope:")
        #expect(EmoteText.displayString("plain", catalog: catalog) == "plain")
    }
}

/// The attributed rendering: marks, replacement, and attributes kept.
struct EmoteTextTests {
    private let catalog = EmoteCatalog.shared
    private let font = UIFont.systemFont(ofSize: 17)

    @Test func codesAreReplacedAndEveryEmoteIsMarked() {
        let text = EmoteText.attributedString("a :lol: b 🔥", attributes: [.font: font], catalog: catalog)
        #expect(text.string == "a 😆 b 🔥")
        let marks = EmoteText.marks(in: text)
        #expect(marks.map(\.id) == ["lol", "noto:1f525"])
        #expect((text.string as NSString).substring(with: marks[0].range) == "😆")
        #expect((text.string as NSString).substring(with: marks[1].range) == "🔥")
        #expect(text.attribute(.font, at: marks[0].range.location, effectiveRange: nil) as? UIFont == font)
    }

    /// Two identical emoji side by side merge into ONE attribute run; the
    /// marks split it back.
    @Test func adjacentIdenticalEmotesAreTwoMarks() {
        let text = EmoteText.attributedString("🔥🔥", attributes: [.font: font], catalog: catalog)
        let marks = EmoteText.marks(in: text)
        #expect(marks.count == 2)
        #expect(marks.map(\.range) == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    }

    @Test func markingKeepsSurroundingAttributes() {
        let source = NSMutableAttributedString(string: "hey :lol: ", attributes: [.font: font])
        source.addAttribute(.foregroundColor, value: UIColor.red, range: NSRange(location: 0, length: 3))
        let marked = EmoteText.marked(source, catalog: catalog)
        #expect(marked.string == "hey 😆 ")
        #expect(marked.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor == .red)
        #expect(EmoteText.marks(in: marked).map(\.id) == ["lol"])
    }

    /// THE placeholder contract: rendering an emote never changes the line.
    /// A `:code:` becomes one emoji glyph, so it measures exactly as the same
    /// emoji typed by hand — and the text is identical before and after the
    /// animation bakes, because baking changes nothing in the string.
    @Test func anEmoteLineMeasuresLikeTheSameEmojiTypedByHand() {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let rendered = EmoteText.attributedString("a :lol: b", attributes: attributes, catalog: catalog)
        let typed = NSAttributedString(string: "a 😆 b", attributes: attributes)
        let size = CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude)
        let renderedBox = rendered.boundingRect(with: size, options: [.usesLineFragmentOrigin], context: nil)
        let typedBox = typed.boundingRect(with: size, options: [.usesLineFragmentOrigin], context: nil)
        #expect(renderedBox == typedBox)
    }
}

/// The catalogue a picker reads.
struct EmoteCatalogTests {
    private let catalog = EmoteCatalog.shared

    @Test func everyEntryHasItsBundledFile() {
        for emote in catalog.all {
            guard case .noto(let codepoint) = emote.source else { continue }
            #expect(NotoLottieSource.jsonData(codepoint: codepoint, bundle: EmoteCatalog.resources)?.isEmpty == false, "\(codepoint)")
        }
    }

    @Test func houseEmotesComeFirstAndAreSectioned() throws {
        let first = try #require(catalog.all.first)
        #expect(first.section == .house)
        #expect(catalog.emotes(in: .house).count == EmoteCatalog.house.count)
        #expect(!catalog.emotes(in: .smileys).isEmpty)
        #expect(Set(catalog.all.map(\.id)).count == catalog.all.count)
    }

    @Test func searchFindsByNameKeywordAndGlyph() {
        #expect(catalog.search("tears of joy").map(\.glyph).contains("😂"))
        #expect(catalog.search("lol").contains { $0.id == "lol" })
        #expect(catalog.search(":lol:").contains { $0.id == "lol" })
        #expect(catalog.search("🔥").map(\.id) == ["noto:1f525"])
        #expect(catalog.search("").count == catalog.all.count)
        #expect(catalog.search("zzzqqq").isEmpty)
    }

    @Test func insertionTextIsPlainText() throws {
        #expect(try #require(catalog.emote(id: "lol")).insertionText == ":lol:")
        #expect(try #require(catalog.emote(id: "noto:1f525")).insertionText == "🔥")
    }
}
