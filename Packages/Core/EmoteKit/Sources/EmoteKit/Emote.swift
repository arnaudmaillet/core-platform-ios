import Foundation

/// Where a picker files an emote. House emotes first; the rest follow Noto's
/// own categories.
public enum EmoteSection: String, CaseIterable, Sendable {
    /// The app's own `:name:` emotes.
    case house
    case smileys
    case people
    case nature
    case food
    case activities
    case travel
    case objects
    case symbols

    public var title: String {
        switch self {
        case .house: "Emotes"
        case .smileys: "Smileys and emotions"
        case .people: "People"
        case .nature: "Animals and nature"
        case .food: "Food and drink"
        case .activities: "Activities"
        case .travel: "Travel and places"
        case .objects: "Objects"
        case .symbols: "Symbols"
        }
    }
}

/// One animated emote: a Unicode emoji that animates where it is written, or a
/// house emote written `:name:`.
///
/// ⚠️ **TEXT STAYS PLAIN TEXT.** Nothing about an emote travels the wire but
/// the characters a person typed: an emoji is itself, a house emote is its
/// `:name:` code. The backend stores and returns exactly that, and a client
/// that knows no emotes shows the same string.
public struct Emote: Hashable, Sendable, Identifiable {
    /// Where the animation comes from.
    public enum Source: Hashable, Sendable {
        /// A Noto Emoji Animation Lottie, bundled compressed as
        /// `Resources/Noto/<codepoint>.json.xz`.
        case noto(codepoint: String)
        /// One of StickerKit's dotLottie stickers, by `Sticker.id`.
        case sticker(id: String)
        /// An icon of the app's baked map catalogue (`AnimatedIconCatalog`),
        /// handed to `EmoteEngine.iconCatalog` at launch.
        case icon(id: String)
    }

    /// Stable, and what `EmoteText.emoteAttribute` stores: `noto:1f525`, or the
    /// house emote's code.
    public let id: String
    /// The `:name:` a house emote is written as, without the colons. Nil for a
    /// Unicode emoji, which is written as itself.
    public let code: String?
    /// The emoji a label DRAWS for this emote — the emoji itself, or a house
    /// emote's stand-in. It is what shows while the animation bakes, when the
    /// playback budget is spent, under Reduce Motion, and anywhere EmoteKit is
    /// not hosting the text, so an emote is never blank.
    public let glyph: String
    /// Lower-case display name ("joy", "rolling on the floor laughing").
    public let name: String
    /// Lower-case, folded search words, the name's included.
    public let keywords: [String]
    public let section: EmoteSection
    public let source: Source

    public init(
        id: String, code: String?, glyph: String, name: String,
        keywords: [String], section: EmoteSection, source: Source
    ) {
        self.id = id
        self.code = code
        self.glyph = glyph
        self.name = name
        self.keywords = keywords
        self.section = section
        self.source = source
    }

    /// What a composer inserts to write this emote: `:name:` for a house emote,
    /// the emoji for the rest.
    public var insertionText: String {
        code.map { ":\($0):" } ?? glyph
    }

    /// Whether this emote is a Unicode emoji that the system can draw as a
    /// still on its own. Under Reduce Motion such an emote is left entirely to
    /// the text system — nothing is baked or placed.
    public var isUnicodeEmoji: Bool {
        if case .noto = source { return true }
        return false
    }
}
