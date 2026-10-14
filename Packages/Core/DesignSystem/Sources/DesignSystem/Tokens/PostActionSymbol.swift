import Foundation

/// The glyphs for what a viewer does TO a post — comment, repost — named once
/// so every surface that draws one draws the same one.
///
/// ⚠️ **ONE ICON PER VERB, APP-WIDE** (product decision, 30 September 2026).
/// Repost was `arrow.2.squarepath` spelled out at four call sites — the card's
/// closing line, the post screen's toolbar, the Snap footer, the profile's
/// "Reposts" filter — and changing it on the card alone would have left the
/// same verb with two faces. Same for comments, which were `bubble.right`,
/// `bubble.left` and `bubble.fill` depending on who drew them.
///
/// ⚠️ Both are the app's CUSTOM symbols now (#1128, `AppSymbol`): load them
/// with `UIImage.symbol(named:)`, never `UIImage(systemName:)` — a name that
/// does not resolve draws an empty control and nothing errors, which is why
/// a test asks the runtime.
///
/// NOT the DIRECT-MESSAGE glyphs (the Messages tab, "Message" actions, a DM
/// thread's empty page): a message to a person is not a comment on a post,
/// and they keep the `message` / `bubble.left.and.bubble.right` family.
public enum PostActionSymbol {
    /// Comments on a post: the card's count, the comment system's own mark.
    public static let comments = AppSymbol.comment.rawValue
    /// The filled variant, for a glyph drawn on a coloured disc.
    public static let commentsFilled = AppSymbol.commentFilled.rawValue
    /// Reposting a post, and the reposts it has.
    public static let repost = AppSymbol.repost.rawValue
}
