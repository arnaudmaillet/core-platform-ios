import Foundation

/// One emote found in a string.
public struct EmoteMatch: Equatable, Sendable {
    /// The characters it replaces: the emoji's grapheme, or the whole `:code:`
    /// with both colons.
    public let range: Range<String.Index>
    public let emote: Emote
    /// Whether it was written as a `:code:` (and so is REPLACED by the emote's
    /// glyph when rendered), rather than as the emoji itself.
    public let isCode: Bool
}

/// Finds the emotes in plain text.
///
/// Two spellings, both plain text so the backend never learns about emotes:
/// - **a Unicode emoji** the catalogue animates, found grapheme by grapheme
///   (`EmoteCatalog.emote(emoji:)` decides, including what stays static);
/// - **a `:code:`** naming a house emote: a letter, then up to 31 letters,
///   digits, `_`, `+` or `-`, between colons. An UNKNOWN code is left exactly
///   as typed, and so is anything that merely looks like one ("10:30:45",
///   "http://").
public enum EmoteParser {
    /// The longest `name` between the colons.
    static let maxCodeLength = 32

    /// Whether `text` could hold an emote at all — a byte outside ASCII or a
    /// colon. The common caption fails this test and costs one pass over its
    /// UTF-8.
    public static func mayContainEmotes(_ text: String) -> Bool {
        text.utf8.contains { $0 >= 0x80 || $0 == UInt8(ascii: ":") }
    }

    /// Every emote in `text`, in order, never overlapping.
    public static func matches(in text: String, catalog: EmoteCatalog = .shared) -> [EmoteMatch] {
        guard mayContainEmotes(text) else { return [] }
        var found: [EmoteMatch] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if character == ":", let (end, emote) = code(in: text, openingAt: index, catalog: catalog) {
                found.append(EmoteMatch(range: index..<end, emote: emote, isCode: true))
                index = end
                continue
            }
            if let emote = catalog.emote(emoji: character) {
                found.append(EmoteMatch(range: index..<next, emote: emote, isCode: false))
            }
            index = next
        }
        return found
    }

    /// The known code opening at `colon`, and the index just past its closing
    /// colon.
    private static func code(
        in text: String, openingAt colon: String.Index, catalog: EmoteCatalog
    ) -> (String.Index, Emote)? {
        var cursor = text.index(after: colon)
        var name = ""
        while cursor < text.endIndex, name.count < maxCodeLength {
            let character = text[cursor]
            if character == ":" {
                guard let first = name.first, first.isASCII, first.isLetter,
                      let emote = catalog.emote(code: name) else { return nil }
                return (text.index(after: cursor), emote)
            }
            guard isCodeCharacter(character) else { return nil }
            name.append(character)
            cursor = text.index(after: cursor)
        }
        return nil
    }

    private static func isCodeCharacter(_ character: Character) -> Bool {
        guard character.isASCII else { return false }
        return character.isLetter || character.isNumber || character == "_" || character == "+" || character == "-"
    }
}
