import Foundation
import StickerKit

/// Every emote this build animates: the bundled Noto subset and the house
/// `:name:` emotes, with the lookups the parser needs and the listing and
/// search a picker needs.
///
/// ⚠️ **BUNDLED, NEVER FETCHED.** The Noto subset ships in this package
/// (`Tools/fetch_noto_subset.py` writes it), the stickers ship in StickerKit
/// and the map icons in the app. Nothing here touches the network.
///
/// Immutable once built, so it is `Sendable` and a parse can run on any
/// thread.
public final class EmoteCatalog: Sendable {
    /// The catalogue the app uses, read from this package's bundle on first
    /// touch (one small manifest; the animations load only when baked).
    public static let shared = EmoteCatalog(bundle: .module)

    /// Every emote: house emotes first, then the Noto subset in its manifest's
    /// order, which is roughly Unicode's frequency ranking — "popular first".
    public let all: [Emote]
    private let byID: [String: Emote]
    private let byEmojiKey: [String: Emote]
    private let byCode: [String: Emote]

    /// The folder `.copy` put in the bundle.
    static let notoSubdirectory = "Noto"
    /// This package's resource bundle — named here because `Bundle.module` in
    /// any other module (a test target included) is THAT module's bundle.
    static let resources: Bundle = .module

    public init(emotes: [Emote]) {
        self.all = emotes
        self.byID = Dictionary(emotes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.byCode = Dictionary(
            emotes.compactMap { emote in emote.code.map { ($0.lowercased(), emote) } },
            uniquingKeysWith: { first, _ in first }
        )
        self.byEmojiKey = Dictionary(
            emotes.compactMap { emote in
                guard case .noto = emote.source else { return nil }
                return (Self.emojiKey(emote.glyph), emote)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// The house emotes plus the Noto subset listed in `bundle`'s manifest. A
    /// missing or unreadable manifest leaves the house emotes alone — a bundling
    /// mistake shows up as emoji that do not animate, never as a crash.
    public convenience init(bundle: Bundle) {
        self.init(emotes: Self.house + Self.notoEmotes(in: bundle))
    }

    // MARK: - Lookups

    public func emote(id: String) -> Emote? {
        byID[id]
    }

    /// The house emote written `:code:` (pass the code without its colons),
    /// ignoring case. Nil for a code this build does not know — the text then
    /// stays exactly as typed.
    public func emote(code: some StringProtocol) -> Emote? {
        byCode[code.lowercased()]
    }

    /// The animated emoji for one grapheme, or nil when this build does not
    /// animate it.
    ///
    /// ⚠️ **PRESENTATION DECIDES, NOT THE BASE CHARACTER.** A grapheme animates
    /// only if it is drawn as an emoji picture: either it carries the emoji
    /// variation selector (U+FE0F), or its only scalar defaults to emoji
    /// presentation. "❤" alone and "❤︎" (U+FE0E) draw as text in most fonts, and
    /// an animated heart over a text heart would be two different claims.
    ///
    /// ⚠️ **A MODIFIED EMOJI IS ANOTHER EMOJI.** A skin tone (👍🏽), a ZWJ
    /// sequence (👨‍👩‍👧, ❤️‍🔥) or a keycap is looked up WHOLE, and the subset
    /// animates none of them, so they stay static — never 👍 animated beside a
    /// stray swatch.
    public func emote(emoji grapheme: Character) -> Emote? {
        let scalars = grapheme.unicodeScalars
        guard let first = scalars.first, first.value >= 0xA9 else { return nil }
        guard !scalars.contains("\u{FE0E}") else { return nil }
        let hasEmojiSelector = scalars.contains("\u{FE0F}")
        if !hasEmojiSelector {
            // Without a selector, only an emoji-presentation scalar draws as a
            // picture, and only when it stands alone.
            let meaningful = scalars.filter { $0 != "\u{FE0F}" }
            guard meaningful.count == 1, first.properties.isEmojiPresentation else { return nil }
        }
        return byEmojiKey[Self.emojiKey(String(grapheme))]
    }

    // MARK: - Picker

    /// The emotes of one section, in catalogue order.
    public func emotes(in section: EmoteSection) -> [Emote] {
        all.filter { $0.section == section }
    }

    /// Emotes with a keyword starting with each word of `query`, ignoring case
    /// and accents: "lau" finds `:lol:` and 😆, "red he" finds ❤️. An empty
    /// query finds everything. A query that IS an emoji finds that emoji.
    public func search(_ query: String) -> [Emote] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 1, let grapheme = trimmed.first, let emote = emote(emoji: grapheme) {
            return [emote]
        }
        let terms = Self.words(of: trimmed.replacingOccurrences(of: ":", with: " "))
        guard !terms.isEmpty else { return all }
        return all.filter { emote in
            terms.allSatisfy { term in emote.keywords.contains { $0.hasPrefix(term) } }
        }
    }

    // MARK: - Keys

    /// The lower-case hex code points of `glyph` joined by `_`, with every
    /// U+FE0F dropped — Noto's file names, normalised so "❤️" and a stray
    /// selector-less spelling meet on one key.
    static func emojiKey(_ glyph: String) -> String {
        glyph.unicodeScalars
            .filter { $0 != "\u{FE0F}" }
            .map { String($0.value, radix: 16) }
            .joined(separator: "_")
    }

    static func words(of text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    // MARK: - Sources

    /// One entry of `Noto/manifest.json`, as `fetch_noto_subset.py` writes it.
    struct NotoEntry: Decodable {
        let glyph: String
        let codepoint: String
        let name: String
        let keywords: [String]
        let section: String
        let seconds: Double
    }

    static func notoEmotes(in bundle: Bundle) -> [Emote] {
        guard let url = bundle.url(forResource: "manifest", withExtension: "json", subdirectory: notoSubdirectory),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([NotoEntry].self, from: data)
        else { return [] }
        return entries.map(notoEmote)
    }

    static func notoEmote(_ entry: NotoEntry) -> Emote {
        // Noto's tags are short handles ("joy"); Unicode's name is what a
        // person searches for ("face with tears of joy"). Keep both.
        let unicodeName = entry.glyph.unicodeScalars.first?.properties.name?.lowercased()
        let name = unicodeName ?? entry.name
        let keywords = Set(words(of: name) + entry.keywords.flatMap { words(of: $0) } + words(of: entry.name))
        return Emote(
            id: "noto:\(entry.codepoint)", code: nil, glyph: entry.glyph, name: name,
            keywords: keywords.sorted(), section: EmoteSection(rawValue: entry.section) ?? .symbols,
            source: .noto(codepoint: entry.codepoint)
        )
    }

    /// The house emotes: StickerKit's stickers, then the map icons that are
    /// faces. Each draws its `glyph` until its animation is ready.
    ///
    /// ⚠️ **ONLY THE MAP ICONS THAT READ AS EMOTES.** The map catalogue's
    /// sixteen decomposed stills are geometric placeholders named for a motion
    /// ("flame-spin" is a spinning star), and a `:flame:` that draws a star
    /// would lie; the Conan sheet is a 56-second slideshow of text screens; the
    /// ISO 7000 pictogram is black line art that vanishes once its white paper
    /// is matted off (`EmoteIconMatte`) over a dark caption. Those stay on the
    /// map.
    public static let house: [Emote] = stickerEmotes + iconEmotes

    /// Codes for StickerKit's stickers, in its favourites order.
    static let stickerCodes: [String: String] = [
        "LMAO": "lmao", "Idea": "idea", "Money": "money", "Book": "books",
        "Laptop": "laptop", "iPhone": "phone", "Cars": "car", "Taxi": "taxi",
        "Snake": "snake", "Weather": "weather", "Temperature": "temperature",
        "NoEntry": "noentry"
    ]

    static var stickerEmotes: [Emote] {
        StickerCatalog.stickers.compactMap { sticker in
            guard let code = stickerCodes[sticker.id] else { return nil }
            let name = sticker.label.lowercased()
            return Emote(
                id: code, code: code, glyph: sticker.emoji, name: name,
                keywords: Array(Set(words(of: name) + [code])).sorted(),
                section: .house, source: .sticker(id: sticker.id)
            )
        }
    }

    /// Icon ids are `mapicons.json`'s; the app hands that catalogue to
    /// `EmoteEngine.iconCatalog`.
    static let iconEmotes: [Emote] = [
        Emote(id: "lol", code: "lol", glyph: "😆", name: "lol",
              keywords: ["laugh", "laughing", "lol"], section: .house,
              source: .icon(id: "animated_asd_laugh_icon")),
        Emote(id: "blush", code: "blush", glyph: "😳", name: "blush",
              keywords: ["blush", "embarrassed", "flushed", "shy"], section: .house,
              source: .icon(id: "animated_emoticon_blush"))
    ]
}
