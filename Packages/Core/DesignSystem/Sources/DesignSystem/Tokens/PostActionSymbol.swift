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
/// Both names are older than the app's iOS 26 floor
/// (`arrow.trianglehead.2.clockwise.rotate.90` since iOS 18,
/// `ellipsis.message` since iOS 16, per the system's `name_availability.plist`),
/// so neither carries a fallback — but a name that does not resolve draws an
/// empty control and nothing errors, which is why a test asks the runtime.
///
/// NOT the DIRECT-MESSAGE glyphs (the Messages tab, "Message" actions, a DM
/// thread's empty page): a message to a person is not a comment on a post,
/// and they keep the `message` / `bubble.left.and.bubble.right` family.
public enum PostActionSymbol {
    /// Comments on a post: the card's count, the comment system's own mark.
    public static let comments = "ellipsis.message"
    /// The filled variant, for a glyph drawn on a coloured disc.
    public static let commentsFilled = "ellipsis.message.fill"
    /// Reposting a post, and the reposts it has.
    public static let repost = "arrow.trianglehead.2.clockwise.rotate.90"
}
