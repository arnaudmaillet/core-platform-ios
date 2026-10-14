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
