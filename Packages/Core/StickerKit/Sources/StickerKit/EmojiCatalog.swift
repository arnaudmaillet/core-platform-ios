import CoreText
import UIKit

/// One emoji a picker can offer.
public struct Emoji: Hashable, Sendable, Identifiable {
    /// The string that draws it — also what `FrameOverlay.Content.emoji` stores.
    public let glyph: String
    /// Lower-case: the Unicode name ("grinning face"), or "flag: " and the
    /// region's English name for a flag. A screen capitalises it to speak it.
    public let name: String
    public let section: EmojiCatalog.Section
    /// `name`'s words, folded for matching.
    let words: [String]

    public var id: String { glyph }
}

/// Every emoji this device draws as ONE picture, grouped, with a name search.
///
/// ⚠️ **BUILT FROM THE SYSTEM, NOT FROM A LIST.** Single-scalar emoji come from
/// `Unicode.Scalar.Properties`, flags from `Locale.Region.isoRegions`, and each
/// candidate is KEPT ONLY IF Apple Color Emoji draws it as a single glyph — a
/// scalar newer than the font, or a region without a flag, falls back to other
/// fonts or to two letter boxes and is left out. Nothing is downloaded.
///
/// ⚠️ **NO ZWJ SEQUENCES YET** (families, professions, skin tones): those are
/// listed only in Unicode's `emoji-test.txt`, which would have to be bundled or
/// fetched. Skin-tone modifiers and lone regional indicators, which draw as
/// swatches and letter boxes, are left out on purpose.
///
/// ⚠️ **BUILT ON FIRST USE, ABOUT A FIFTH OF A SECOND** (measured on a busy
/// simulator: 1,395 scalars and 259 flags, each laid out once). Touch `all` off
/// the main actor before a picker needs it.
public enum EmojiCatalog {
    /// Groups, by where Unicode put each emoji. Unicode's own groups live only
    /// in `emoji-test.txt`, so these follow its blocks instead.
    public enum Section: String, CaseIterable, Sendable {
        /// The Emoticons block.
        case faces
        /// The Supplemental Symbols and Pictographs blocks: newer faces,
        /// people, animals, food and things.
        case more
        /// The Miscellaneous Symbols and Pictographs block: weather, nature,
        /// food, places and objects.
        case things
        /// The Transport and Map Symbols block.
        case travel
        /// Everything else: symbols, dingbats, arrows, shapes and signs.
        case symbols
        case flags

        public var title: String {
            switch self {
            case .faces: "Faces"
            case .more: "People and more"
            case .things: "Nature and objects"
            case .travel: "Travel"
            case .symbols: "Symbols"
            case .flags: "Flags"
            }
        }

        static func of(_ value: UInt32) -> Section {
            switch value {
            case 0x1F600...0x1F64F: .faces
            case 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF: .more
            case 0x1F300...0x1F5FF: .things
            case 0x1F680...0x1F6FF: .travel
            default: .symbols
            }
        }
    }

    /// Every entry: sections in `Section` order, each in code-point order (flags
    /// by region code).
    public static let all: [Emoji] = {
        let pictures = candidateScalars().filter { drawsAsOneEmojiGlyph($0.glyph) }
        let sorted = Section.allCases.flatMap { section in pictures.filter { $0.section == section } }
        return sorted + flags().filter { drawsAsOneEmojiGlyph($0.glyph) }
    }()

    /// The entries of one section, in catalogue order.
    public static func emoji(in section: Section) -> [Emoji] {
        all.filter { $0.section == section }
    }

    /// Entries whose name has a word starting with each word of `query`,
    /// ignoring case and accents: "grin fa" finds "grinning face". An empty
    /// query finds everything.
    public static func search(_ query: String) -> [Emoji] {
        let terms = words(of: query)
        guard !terms.isEmpty else { return all }
        return all.filter { emoji in
            terms.allSatisfy { term in emoji.words.contains { $0.hasPrefix(term) } }
        }
    }

    /// Whether Apple Color Emoji draws `glyph` as exactly one picture.
    ///
    /// ⚠️ **THE FONT OF THE RUN IS CHECKED, NOT ONLY THE COUNT.** Core Text
    /// falls back to another font for a character Apple Color Emoji lacks, and
    /// that fallback draws one glyph too — a plain symbol, or the Last Resort
    /// box.
    static func drawsAsOneEmojiGlyph(_ glyph: String) -> Bool {
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 40, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: [.font: font]))
        guard CTLineGetGlyphCount(line) == 1,
              let runs = CTLineGetGlyphRuns(line) as? [CTRun], runs.count == 1,
              // CTFont and UIFont are one type; the bridge reads the run's font.
              let used = (CTRunGetAttributes(runs[0]) as NSDictionary)[NSAttributedString.Key.font] as? UIFont
        else { return false }
        var glyphID = CGGlyph()
        CTRunGetGlyphs(runs[0], CFRange(location: 0, length: 1), &glyphID)
        return glyphID != 0 && used.fontName == "AppleColorEmoji"
    }

    /// Single scalars Unicode calls emoji, with the presentation selector added
    /// to those that default to text (☀ → ☀️).
    private static func candidateScalars() -> [Emoji] {
        let ranges: [ClosedRange<UInt32>] = [0x00A9...0x3299, 0x1F000...0x1FAFF]
        return ranges.joined().compactMap { value in
            guard value >= 0x80, let scalar = Unicode.Scalar(value) else { return nil }
            let properties = scalar.properties
            guard properties.isEmoji,
                  // Skin-tone swatches, which exist to modify another emoji.
                  !properties.isEmojiModifier,
                  // Lone regional indicators, which exist to pair into flags.
                  !(0x1F1E6...0x1F1FF).contains(value),
                  let name = properties.name else { return nil }
            var glyph = String(scalar)
            if !properties.isEmojiPresentation { glyph.unicodeScalars.append("\u{FE0F}") }
            return entry(glyph: glyph, name: name.lowercased(), section: Section.of(value))
        }
    }

    /// A pair of regional indicators for every two-letter ISO region.
    private static func flags() -> [Emoji] {
        let english = Locale(identifier: "en")
        let letters = UInt32(("A" as Unicode.Scalar).value)...UInt32(("Z" as Unicode.Scalar).value)
        return Locale.Region.isoRegions
            .map(\.identifier)
            .filter { code in
                code.unicodeScalars.count == 2 && code.unicodeScalars.allSatisfy { letters.contains($0.value) }
            }
            .sorted()
            .compactMap { code in
                let scalars = code.unicodeScalars.compactMap {
                    Unicode.Scalar(0x1F1E6 + $0.value - letters.lowerBound)
                }
                guard let region = english.localizedString(forRegionCode: code) else { return nil }
                var glyph = ""
                glyph.unicodeScalars.append(contentsOf: scalars)
                return entry(glyph: glyph, name: "flag: \(region)", section: .flags)
            }
    }

    private static func entry(glyph: String, name: String, section: Section) -> Emoji {
        Emoji(glyph: glyph, name: name, section: section, words: words(of: name))
    }

    private static func words(of text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }
}
