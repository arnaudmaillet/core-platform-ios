import Foundation

/// The text rules of composing with emotes, kept pure so they are tested
/// without a keyboard: what the picker shows, what a tap inserts and where,
/// what a backspace deletes, and what an inline `:query` is searching for.
public enum EmoteComposing {
    /// One section of the picker.
    public struct Section: Equatable, Sendable {
        /// `recent`, `results`, or an `EmoteSection` raw value.
        public let id: String
        public let title: String
        /// The SF Symbol on the picker's section bar.
        public let symbol: String
        public let emotes: [Emote]
    }

    /// The picker's sections: RECENT first (when there are any), then the
    /// house emotes, then Noto's sections in catalogue order. Empty sections
    /// are left out, so the section bar never jumps to nothing.
    public static func sections(catalog: EmoteCatalog, recents: [Emote]) -> [Section] {
        var sections: [Section] = []
        if !recents.isEmpty {
            sections.append(Section(id: "recent", title: "Recent", symbol: "clock", emotes: recents))
        }
        for section in EmoteSection.allCases {
            let emotes = catalog.emotes(in: section)
            guard !emotes.isEmpty else { continue }
            sections.append(Section(id: section.rawValue, title: section.title, symbol: symbol(for: section), emotes: emotes))
        }
        return sections
    }

    static func symbol(for section: EmoteSection) -> String {
        switch section {
        case .house: "sparkles"
        case .smileys: "face.smiling"
        case .people: "hand.wave"
        case .nature: "leaf"
        case .food: "fork.knife"
        case .activities: "party.popper"
        case .travel: "airplane"
        case .objects: "lightbulb"
        case .symbols: "heart"
        }
    }

    // MARK: - Insertion

    /// `text` with `insertion` replacing `range` (the selection, or the caret
    /// as an empty range), and where the caret lands: just after it.
    ///
    /// The ranges are UTF-16, like `UITextView.selectedRange`; an out-of-bounds
    /// range is clamped to the end rather than trapping.
    public static func inserting(
        _ insertion: String, into text: String, replacing range: NSRange
    ) -> (text: String, caret: Int) {
        let ns = text as NSString
        let location = min(max(0, range.location), ns.length)
        let length = min(max(0, range.length), ns.length - location)
        let result = ns.replacingCharacters(in: NSRange(location: location, length: length), with: insertion)
        return (result, location + (insertion as NSString).length)
    }

    /// What one backspace before `caret` removes: a whole known `:code:` when
    /// the caret sits right after one, otherwise one grapheme — an emoji with
    /// its selectors and modifiers goes as one, never as a stray half.
    public static func deletionRange(in text: String, caret: Int, catalog: EmoteCatalog = .shared) -> NSRange? {
        let ns = text as NSString
        let caret = min(max(0, caret), ns.length)
        guard caret > 0 else { return nil }
        let head = ns.substring(to: caret)
        if head.hasSuffix(":"),
           let match = EmoteParser.matches(in: head, catalog: catalog).last,
           match.isCode, match.range.upperBound == head.endIndex {
            return NSRange(match.range, in: head)
        }
        let last = ns.rangeOfComposedCharacterSequence(at: caret - 1)
        return last
    }

    // MARK: - Inline search

    /// The shortest inline query that searches: `:` and two characters.
    public static let minimumQueryLength = 2

    /// The `:query` being typed right before `caret`, if any — Discord's and
    /// Twitch's way to search emotes without leaving the keyboard.
    ///
    /// The colon must open a word — start of text, or after anything that is
    /// not a letter, a digit, a colon or a slash (a space, punctuation, an
    /// emoji) — so "10:30", "http://" and "word:" never search; the query is
    /// code characters only and at least `minimumQueryLength` long.
    /// `range` covers the colon and the query: what a suggestion replaces.
    public static func inlineQuery(in text: String, caret: Int) -> (query: String, range: NSRange)? {
        let ns = text as NSString
        let caret = min(max(0, caret), ns.length)
        var start = caret
        while start > 0 {
            let unit = ns.character(at: start - 1)
            guard let scalar = Unicode.Scalar(unit), isQueryScalar(scalar) else { break }
            start -= 1
            if caret - start > EmoteParser.maxCodeLength { return nil }
        }
        guard start > 0, ns.character(at: start - 1) == UInt16(UInt8(ascii: ":")) else { return nil }
        let colon = start - 1
        if colon > 0 {
            // The whole character before the colon: an emoji is two UTF-16
            // units, and its trailing half is no scalar at all.
            let before = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: colon - 1))
            guard opensWord(after: before) else { return nil }
        }
        let query = ns.substring(with: NSRange(location: start, length: caret - start))
        guard query.count >= minimumQueryLength, query.first?.isLetter == true else { return nil }
        return (query, NSRange(location: colon, length: caret - colon))
    }

    /// The emotes an inline query offers: house codes whose code starts with
    /// it first (what the person is most likely spelling), then every other
    /// match of the catalogue's word search.
    public static func suggestions(for query: String, catalog: EmoteCatalog, limit: Int = 24) -> [Emote] {
        let folded = query.lowercased()
        let codes = catalog.all.filter { $0.code?.hasPrefix(folded) == true }
        let others = catalog.search(query).filter { emote in !codes.contains { $0.id == emote.id } }
        return Array((codes + others).prefix(limit))
    }

    private static func isQueryScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
            || scalar == "_" || scalar == "+" || scalar == "-")
    }

    /// Whether a `:` right after `character` opens a word.
    static func opensWord(after character: String) -> Bool {
        guard let first = character.first else { return true }
        return !(first.isLetter || first.isNumber || first == ":" || first == "/")
    }
}
