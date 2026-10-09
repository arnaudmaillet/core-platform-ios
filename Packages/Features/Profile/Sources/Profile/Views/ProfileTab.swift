import DesignSystem
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
    /// Someone else's reposts, alone (#696): their authored corpus split on
    /// `isRepost`. Pushed profile only.
    case reposts
    /// Posts by others that mention them (#696): the tagged corpus. Pushed
    /// profile only.
    case tagged

    /// What the selector calls it.
    ///
    /// Short on purpose: the strip shares a slot with the bar's glass, and
    /// "Reactions" alone costs more than "Saved" and "Posts" together.
    ///
    /// Only Posts is a page since #631 — the profile's every post, laid out
    /// like For You. Media is the gallery its "View all" pushes; Short is no
    /// page at all any more (it was text posts, which are cards now).
    public var title: String {
        switch self {
        case .format(.activity): "Posts"
        case .format(.media): "Gallery"
        case .format(.short): "Short"
        case .saved: "Saved"
        case .reactions: "Liked"
        case .reposts: "Reposts"
        case .tagged: "Tagged"
        }
    }

    /// Whether the page loads more as it scrolls: the published-content
    /// pages. Saved and Liked arrive whole.
    var pages: Bool {
        switch self {
        case .format, .reposts, .tagged: true
        case .saved, .reactions: false
        }
    }

    /// The format this page filters by, or nil when it is not that kind of page.
    /// The source tray and the stored format preference both key off this —
    /// neither has anything to say about a corpus.
    public var format: GalleryFilter.Format? {
        if case .format(let format) = self { return format }
        return nil
    }

    /// What anyone else's profile shows: Posts | Reposts | Tagged, three
    /// pages with the selector at the foot (#696, the owner's call
    /// 2026-10-08). Each is its own list, laid out like For You: Posts is
    /// their own posts WITHOUT reposts, Reposts only those, Tagged others'
    /// posts that mention them. It was one list narrowed by a top source
    /// filter (#631) — "it is no longer a sort".
    public static let publicTabs: [ProfileTab] = [.format(.activity), .reposts, .tagged]

    /// What the viewer sees on their own: Posts | Saved | Liked. Saved and
    /// Liked are other corpora, so a selector stays (the owner's call,
    /// 2026-10-07). The own Posts keeps the top source filter (#696).
    public static let ownTabs: [ProfileTab] = [.format(.activity), .saved, .reactions]
}

// MARK: - What a tab says when it is empty

extension ProfileTab {
    /// The glyph, headline and explanation a page shows when it has nothing.
    ///
    /// Per TAB rather than per page, because the answer is about what the tab
    /// IS: an empty Gallery and an empty Saved pile are both blank grids and
    /// mean entirely different things, and the difference is the only thing
    /// worth saying at that moment.
    ///
    /// ⚠️ The subtitle here is a DEFAULT, not the last word. A format page can
    /// be empty because of the source filter rather than because the profile
    /// has nothing — "no media in reposts" — and that is more useful than a
    /// generic sentence. The page prefers the model's message when it has one
    /// and falls back to this; see `ProfileGalleryGridView.render`.
    var emptyState: (symbol: String, title: String, subtitle: String) {
        switch self {
        case .format(.activity):
            ("rectangle.stack", "No Posts Yet", "Posts and reposts will appear here.")
        case .format(.media):
            ("photo.on.rectangle", "No Photos or Videos", "Photos and videos will appear here.")
        case .format(.short):
            // No page shows it since #631. Worded for what it filtered —
            // text posts — not for the video clips it once claimed.
            ("text.alignleft", "No Text Posts", "Text posts will appear here.")
        case .saved:
            ("bookmark", "No Saved Posts", "Posts you bookmark will appear here.")
        case .reactions:
            ("heart", "No Reactions Yet", "Posts you react to or like will show up here.")
        case .reposts:
            (PostActionSymbol.repost, "No Reposts Yet", "Reposts will appear here.")
        case .tagged:
            ("at", "No Tagged Posts", "Posts that mention them will appear here.")
        }
    }
}
