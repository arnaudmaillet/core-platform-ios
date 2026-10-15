import UIKit

/// THE APP'S SIGNATURE GLYPHS (#1128): the verbs and currencies a viewer
/// meets on every card — like, comment, repost, save, more, share, gems —
/// drawn as the app's own custom SF Symbols, by name, never spelled at a
/// call site.
///
/// The owner's decisions (2026-10-14, #1128):
/// - **The art is Phosphor (MIT), retouched**, imported as custom SF Symbols
///   (`Resources/Symbols.xcassets`), so a glyph keeps what a system symbol
///   has: text-baseline alignment, rendering modes, Dynamic Type through a
///   text style, the symbol effects (bounce, replace).
/// - **Save is the STAR** (outline / filled gold, `Palette.saveGold`), the
///   收藏 convention; the like is the heart.
/// - **The gem is our own drawing** (side view, rounded), not a Phosphor or
///   Sketch glyph.
/// - **One family per cluster**: the card's whole action row — ⋯ and share
///   included — is this set. Everything else stays SF Symbols.
///
/// ⚠️ The three weight masters of each template are the SAME outline today:
/// Phosphor's thin / regular / bold paths do not share a structure, so they
/// cannot be interpolated. A glyph therefore draws at one weight whatever
/// the configuration asks; a designer can redraw the masters behind the same
/// names without touching code.
///
/// ⚠️ A custom symbol is NOT found by `UIImage(systemName:)` — always go
/// through `image(_:)`, which reads this package's catalog. A name that does
/// not resolve draws an empty control and nothing errors, so a test renders
/// every case.
public enum AppSymbol: String, CaseIterable, Sendable {
    /// Like, and Points: the heart, outline.
    case like = "core.heart"
    /// Liked, and the Points glyph: the heart, filled.
    case liked = "core.heart.fill"
    /// Comments on a post: a teardrop bubble with text.
    case comment = "core.comment"
    /// Comments, filled — a glyph on a coloured disc.
    case commentFilled = "core.comment.fill"
    /// Reposting, and the reposts a post has.
    case repost = "core.repost"
    /// Save: the star, outline.
    case save = "core.star"
    /// Saved: the star, filled (drawn gold, `Palette.saveGold`).
    case saved = "core.star.fill"
    /// The card's ⋯ menu.
    case more = "core.more"
    /// Share.
    case share = "core.share"
    /// Gems, outline.
    case gem = "core.gem"
    /// Gems, filled — the glyph beside an amount.
    case gemFilled = "core.gem.fill"

    // The full-screen post's other glyphs (#1184), from the same Phosphor set.
    /// Sorting a list (the comments' order).
    case sort = "core.sort"
    /// "Not interested": a thumb down.
    case notInterested = "core.not.interested"
    /// Report: a flag.
    case flag = "core.flag"
    /// Add, follow: a plus.
    case plus = "core.plus"
    /// Done, followed: a check mark.
    case check = "core.check"
    /// Accept, approved: a check in a circle.
    case checkCircle = "core.check.circle"
    /// Decline: a cross in a circle.
    case xCircle = "core.x.circle"
    /// People, mutuals.
    case people = "core.people"
    /// People, mutuals, filled.
    case peopleFilled = "core.people.fill"
    /// Pending, requested: a clock.
    case clock = "core.clock"
    /// A song.
    case musicNote = "core.music.note"
    /// No sound.
    case speakerSlash = "core.speaker.slash"
    /// Muted, filled.
    case speakerSlashFilled = "core.speaker.slash.fill"
    /// Restrict: a raised hand.
    case hand = "core.hand"
    /// A warning: a triangle.
    case warning = "core.warning"
    /// Failed: a warning in a circle, filled.
    case warningCircleFilled = "core.warning.circle.fill"
    /// Collapse / expand downward.
    case caretDown = "core.caret.down"
    /// Collapse / expand upward.
    case caretUp = "core.caret.up"
    /// Send: an arrow up in a disc.
    case sendFilled = "core.send.fill"
    /// Voice: a waveform.
    case waveform = "core.waveform"
    /// Public, everyone: a globe.
    case globe = "core.globe"
    /// Pin.
    case pin = "core.pin"
    /// Pinned.
    case pinFilled = "core.pin.fill"
    /// Emotes: a smiley.
    case smiley = "core.smiley"
    /// Back to the keyboard.
    case keyboard = "core.keyboard"

    /// The glyph as a template image, sized by `configuration` (a text style
    /// for a glyph beside text, a point size for fixed chrome — see
    /// `textStyle(_:)` and `fixed(_:)`).
    public func image(_ configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        let image = UIImage(named: rawValue, in: .module, with: configuration)
        image?.accessibilityLabel = accessibilityLabel
        return image
    }

    /// What VoiceOver reads for the glyph alone (a control says its own
    /// label; this is for a glyph that stands by itself).
    public var accessibilityLabel: String {
        switch self {
        case .like: "Like"
        case .liked: "Liked"
        case .comment, .commentFilled: "Comments"
        case .repost: "Repost"
        case .save: "Save"
        case .saved: "Saved"
        case .more: "More"
        case .share: "Share"
        case .gem, .gemFilled: "Gems"
        case .sort: "Sort"
        case .notInterested: "Not interested"
        case .flag: "Report"
        case .plus: "Add"
        case .check, .checkCircle: "Done"
        case .xCircle: "Decline"
        case .people, .peopleFilled: "People"
        case .clock: "Pending"
        case .musicNote: "Sound"
        case .speakerSlash, .speakerSlashFilled: "No sound"
        case .hand: "Block"
        case .warning, .warningCircleFilled: "Warning"
        case .caretDown: "Expand"
        case .caretUp: "Collapse"
        case .sendFilled: "Send"
        case .waveform: "Voice"
        case .globe: "Everyone"
        case .pin: "Pin"
        case .pinFilled: "Pinned"
        case .smiley: "Emotes"
        case .keyboard: "Keyboard"
        }
    }

    // MARK: - Sizing, in one place

    /// A glyph BESIDE TEXT takes that text's style: it grows with Dynamic
    /// Type and stops at the app's ceiling (XXXL, `TextSizeCeiling`), as the
    /// text it sits by does through `.appFont`.
    public static func textStyle(
        _ style: UIFont.TextStyle, scale: UIImage.SymbolScale = .default
    ) -> UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(font: .appFont(forTextStyle: style), scale: scale)
    }

    /// A glyph in FIXED CHROME (the card's pill, the toolbar bubbles) keeps
    /// its measured size, as the fonts there do.
    public static func fixed(_ pointSize: CGFloat, weight: UIImage.SymbolWeight = .regular) -> UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    }
}

public extension UIImage {
    /// A symbol by NAME — the app's own (`core.*`, `AppSymbol`) or the
    /// system's. Every component that takes a symbol name loads it through
    /// here, so a token that names a custom glyph (`PointsSymbol.glyph`,
    /// `PostActionSymbol.repost`…) draws it; `UIImage(systemName:)` would
    /// find nothing and draw an empty control.
    static func symbol(named name: String, configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        if let custom = AppSymbol(rawValue: name) { return custom.image(configuration) }
        return configuration.map { UIImage(systemName: name, withConfiguration: $0) } ?? UIImage(systemName: name)
    }
}
