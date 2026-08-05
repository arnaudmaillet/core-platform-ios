import PostGrid

/// A page in the profile's pager.
///
/// ⚠️ **Not a `GalleryFilter.Format`, and the distinction is the reason this
/// type exists.** That axis is the KIND of post — activity, media, short — and
/// it is crossed with a source (all / posts / reposts / tagged) to pick out
/// part of what this profile has published. Saved and Reactions are neither
/// half of that: they are different CORPORA, made mostly of other people's
/// posts, and every question the source filter asks is meaningless about them.
/// Adding them as formats would have made "Reposts × Saved" a state the model
/// could hold and nothing could answer.
public enum ProfileTab: Equatable, Sendable {
    /// One of the profile's own published-content pages.
    case format(GalleryFilter.Format)
    /// Posts the viewer saved. Own profile only — a saved pile is private by
    /// construction; there is no contract that would let it be otherwise.
    case saved
    /// Posts the viewer reacted to. Own profile only, same reason.
    case reactions

    /// What the selector calls it.
    ///
    /// Short on purpose. These five have to share a navigation bar's title slot,
    /// and every character is measured against a hard 258pt — "Reactions" alone
    /// costs more than "Saved" and "Short" together.
    public var title: String {
        switch self {
        case .format(.activity): "Activity"
        case .format(.media): "Gallery"
        case .format(.short): "Short"
        case .saved: "Saved"
        case .reactions: "Liked"
        }
    }

    /// The format this page filters by, or nil when it is not that kind of page.
    /// The source tray and the stored format preference both key off this —
    /// neither has anything to say about a corpus.
    public var format: GalleryFilter.Format? {
        if case .format(let format) = self { return format }
        return nil
    }

    /// The three every profile shows.
    public static let publicTabs: [ProfileTab] = [.format(.activity), .format(.media), .format(.short)]

    /// The five the viewer sees on their own.
    public static let ownTabs: [ProfileTab] = publicTabs + [.saved, .reactions]
}
