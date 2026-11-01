import DesignSystem
import UIKit

/// The post footer — the snap feed's, the text post's — and the conversation
/// screen's, which builds it with its own leading item:
///
/// ```
///  [leading] ———————————————— [🔖 ⇄] [⋯]     the post: a pill, then space
///  [leading] ———————————————— [📷 🖼] [⋯]     a conversation: its media
/// ```
///
/// THE BAR CONTRACT (#1679, `dev/BAR_CONTRACT.md`): every action is a STOCK
/// bar item (`BarItems.icon`) — the bar draws its glass, its press, its menu —
/// and every item has an identifier, so a footer rebuilt or carried across a
/// push is matched item by item. Adjacent actions share one platter by
/// themselves (iOS 26 groups neighbouring items); the separator keeps ⋯ in a
/// bubble of its own. The leading item is the one container (a person or
/// media pill, `BarItems.container`).
///
/// It used to be custom-view `UIButton`s in a `UIStackView` — each a circle
/// with a shadow, re-implementing what the bar draws (R1).
@MainActor
enum SnapFooterToolbar {
    /// Identifiers by function, the same on every screen that wears the
    /// footer, so a push from the feed to a text post keeps them in place.
    enum ID {
        static let save = "feed.snap.save"
        static let repost = "feed.snap.repost"
        static let more = "feed.snap.more"
        static let share = "feed.snap.share"
        static let like = "feed.snap.like"
    }

    /// The bar's items, left to right: the leading container under
    /// `leadingID`, the actions sharing one platter, and ⋯ in its own bubble.
    /// No actions, no platter (nothing there to save or repost); no `more`,
    /// no ⋯.
    static func items(
        leading: UIView, leadingID: String, actions: [UIBarButtonItem], more: UIBarButtonItem?
    ) -> [UIBarButtonItem] {
        [BarItems.container(id: leadingID, view: leading)] + trailingItems(actions: actions, more: more)
    }

    /// The footer's trailing run alone, right-aligned: `actions`, then `more`
    /// behind a separator. For a footer with nothing to lead with (#1999).
    static func trailingItems(actions: [UIBarButtonItem], more: UIBarButtonItem?) -> [UIBarButtonItem] {
        var items: [UIBarButtonItem] = [.flexibleSpace()]
        items += actions
        if let more {
            if !actions.isEmpty { items.append(BarItems.separator()) }
            items.append(more)
        }
        return items
    }

    /// The save star, outline at rest (`SaveStar`); `saveImage(saved:)` turns
    /// it gold once saved — on the ITEM, never through its action, whose
    /// image a `UIAction` would re-apply when it fires.
    static func makeSaveItem(action: @escaping () -> Void) -> UIBarButtonItem {
        BarItems.icon(id: ID.save, image: saveImage(saved: false), label: "Save", action: action)
    }

    static func saveImage(saved: Bool) -> UIImage? {
        SaveStar.image(saved: saved)
    }

    /// ⚠️ Drawn without an action — `PostComposer` takes no parent, so there
    /// is no client path to publish a repost yet (see the feed's note). A
    /// stock item with no target does nothing when tapped.
    static func makeRepostItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage.symbol(named: PostActionSymbol.repost), style: .plain, target: nil, action: nil
        )
        item.identifier = ID.repost
        item.accessibilityLabel = "Repost"
        return item
    }

    /// ⋯ — the thread's and the text composer's menu.
    static func makeMoreItem(menu: UIMenu) -> UIBarButtonItem {
        BarItems.icon(id: ID.more, image: UIImage(systemName: "ellipsis"), label: "More actions", menu: menu)
    }

    /// A text post's like (#1924, the owner): the heart and the post's count
    /// in one bubble the bar draws (`BarItems.labeled`), between the author
    /// and save — a tap likes, as the page's pill does; the burst's toast is
    /// its undo. Outline at rest, the points' pink once staked
    /// (`LikesSymbol`). The heart alone when the count is hidden (#397).
    ///
    /// ⚠️ ITS WORD AND GLYPH ARE FIXED (R3): a new count or a new face is a
    /// new item under `ID.like`, which the bar animates.
    static func makeLikeItem(count: Int64?, spent: Int, action: @escaping () -> Void) -> UIBarButtonItem {
        let heart = LikesSymbol.likeImage(staked: spent > 0, likeGlyph)
        let item: UIBarButtonItem
        if let count {
            let (labeled, label) = BarItems.labeled(id: ID.like, title: count.formattedCompact(), image: heart, action: action)
            label.accessibilityLabel = "Like"
            label.accessibilityValue = SnapRailBoostButton.accessibilityValue(likeCount: count, staked: spent)
            item = labeled
        } else {
            item = BarItems.icon(id: ID.like, image: heart, label: "Like", action: action)
        }
        return item
    }

    /// The footer heart's size: the stock glyphs' beside it.
    private static let likeGlyph = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)

    /// The like's bubble on a text post's footer at a wide count ("999K"),
    /// the glass around it included — measured at `traits`' text size.
    static func likeBubbleWidth(for traits: UITraitCollection) -> CGFloat {
        let probe = StretchedBarLabel(
            title: Int64(999_000).formattedCompact(), image: LikesSymbol.likeImage(staked: false, likeGlyph),
            ink: .label, weight: .regular, action: {}
        )
        // Measured at the default size and scaled as the bar's text is: an
        // off-window label does not follow a trait override.
        let width = UIFontMetrics(forTextStyle: .body).scaledValue(
            for: probe.intrinsicContentSize.width, compatibleWith: traits
        )
        return ceil(width) + 10
    }

    /// Share (#1728, the owner): on the post screen, ⋯ and its menu gave way
    /// to the share sheet — where Not interested and Report now live.
    static func makeShareItem(action: @escaping () -> Void) -> UIBarButtonItem {
        BarItems.icon(id: ID.share, image: UIImage(systemName: "arrowshape.turn.up.right"), label: "Share", action: action)
    }
}
