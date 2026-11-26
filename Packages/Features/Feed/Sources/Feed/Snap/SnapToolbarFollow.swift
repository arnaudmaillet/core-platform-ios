import CoreModels
import DesignSystem
import PostGrid
import ThreadKit
import UIKit

/// What the full-screen page's Follow asks of its screen (#2409): the bar to
/// stand again once what it shows changed, and the follow and the request's
/// withdrawal for the author on the pill.
@MainActor
protocol SnapToolbarFollowHost: AnyObject {
    /// The Follow item, or the pill's stretch, changed: the toolbar and the
    /// pill stand again, through the bar's own animation.
    func toolbarFollowDidChange()
    func followShownAuthor()
    func cancelShownAuthorRequest()
}

/// THE FULL-SCREEN PAGE'S FOLLOW (#2409, `-snap-layout-v2`): its own bar item
/// beside the author pill, in the brand primary — the page's one filled
/// control.
///
/// ```
///   not followed:  [◉ Tessa / @tessa] (  Follow  ) ———————— [⇄]
///   follows you:   [◉ Tessa / @tessa] (Follow back) ——————— [⇄]
///   tap:           [◉ Tessa / @tessa] (✓ Following) ——————— [⇄]   ~1 s
///   followed:      [◉✓ Tessa / ♪ Original sound · Tessa… ——] [⇄]
///   requested:     [◉ Tessa / @tessa] ( Requested ) ——————— [⇄]   quiet, menu
/// ```
///
/// - **One source**: it draws `AuthorFollowOffer`, which the author binding
///   hands the bar's pill from the SAME answer as its badge
///   (`AuthorBadgeBinding`, `AuthorFollowDrawing`) — the badge and the
///   button never disagree.
/// - **The words and the confirmation are the list rows' (#2419)**:
///   `AuthorFollowOffer.buttonTitle`, `confirmsFollow`, `confirmationDuration`.
/// - **The bar's own morph** (#1679): every face is a stock item under its
///   own identifier, kept while it stays (`BarItemStore`, #2331); a change of
///   face is a new identifier the bar morphs to, and the fold is the item
///   leaving the toolbar while the pill takes its room. No fade, no
///   transform on glass.
/// - Unfollow is never here: the profile, and the share sheet's actions.
@MainActor
final class SnapToolbarFollow {
    /// What stands beside the pill.
    enum Face: Equatable {
        case none
        /// Follow, Follow back or Requested.
        case offer(AuthorFollowOffer)
        /// "✓ Following", waiting for its fold.
        case confirming
    }

    static let followID = "feed.snap.follow"
    static let requestedID = "feed.snap.follow-requested"
    static let confirmedID = "feed.snap.follow-confirmed"

    private unowned let host: any SnapToolbarFollowHost
    /// The author the face is for, and their offer.
    private(set) var author: ProfileID?
    private(set) var offer: AuthorFollowOffer = .none
    /// The viewer's own post: no button, the pill stretched.
    private(set) var isViewer = false
    private(set) var face: Face = .none
    /// The confirmation's clock: a test steps it.
    var clock: LoadingClock = .system
    private var fold: LoadingTimer?
    private let items = BarItemStore()

    init(host: any SnapToolbarFollowHost) {
        self.host = host
    }

    /// Draws `offer` for `author`. `seen`: the change happens on screen — only
    /// then does a follow made from the button say "✓ Following" before it
    /// folds. Another author, or a page filled afresh, draws its face at once.
    func show(_ offer: AuthorFollowOffer, for author: ProfileID?, isViewer: Bool, seen: Bool) {
        let sameAuthor = author == self.author
        guard !sameAuthor || offer != self.offer || isViewer != self.isViewer else { return }
        let old = sameAuthor ? self.offer : .none
        let shown = face
        self.author = author
        self.offer = offer
        self.isViewer = isViewer
        fold?.cancel()
        fold = nil
        if sameAuthor, seen, offer.confirmsFollow(from: old), shown != .none {
            face = .confirming
            fold = clock.schedule(AuthorFollowOffer.confirmationDuration) { [weak self] in
                guard let self else { return }
                fold = nil
                face = .none
                host.toolbarFollowDidChange()
            }
        } else {
            face = offer.showsButton ? .offer(offer) : .none
        }
        host.toolbarFollowDidChange()
    }

    /// Whether the pill stands stretched to the repost, its second line the
    /// sound: an author the viewer follows, once "✓ Following" has folded, or
    /// the viewer.
    var stretchesPill: Bool { face == .none && Self.stretches(offer: offer, isViewer: isViewer) }

    /// The rule for an author arriving — no confirmation can be under way.
    static func stretches(offer: AuthorFollowOffer, isViewer: Bool) -> Bool {
        isViewer || offer == .following
    }

    /// The item beside the pill, nil for none.
    var item: UIBarButtonItem? {
        switch face {
        case .none:
            return nil
        case .confirming:
            return items.item(Self.confirmedID) {
                let made = BarItems.labeled(
                    id: Self.confirmedID, title: "Following", image: UIImage(systemName: "checkmark"), action: {}
                )
                made.label.accessibilityLabel = "Following"
                return made.item
            }
        case .offer(.requested):
            return items.item(Self.requestedID) {
                let cancel = UIAction(
                    title: "Cancel Request", image: UIImage(systemName: "xmark"), attributes: .destructive
                ) { [weak self] _ in self?.host.cancelShownAuthorRequest() }
                let item = BarItems.title(id: Self.requestedID, title: "Requested", menu: UIMenu(children: [cancel]))
                item.accessibilityHint = "Offers to cancel your follow request."
                return item
            }
        case .offer(let offer):
            // Follow and Follow back: one identifier, a new item for a new
            // word (a title item is measured when it is made).
            let title = offer.buttonTitle ?? "Follow"
            return items.item(Self.followID, variant: title) {
                let item = BarItems.title(id: Self.followID, title: title, prominent: true) { [weak self] in
                    self?.host.followShownAuthor()
                }
                // The brand primary, white words: the page's one filled
                // control (the toolbar's own tint is white).
                item.tintColor = Palette.primaryFill
                return item
            }
        }
    }

    #if DEBUG
    /// The confirmation's fold, run now. Tests.
    func debugFold() {
        guard let fold else { return }
        fold.cancel()
        self.fold = nil
        face = .none
        host.toolbarFollowDidChange()
    }
    #endif

    // MARK: - The pill's room

    /// The pill's budget on v2's footer, read off the bar's measured platters
    /// (`SnapBarPillWidths.toolbarReserve`): the margins (28 a side), the
    /// pill's glass (10), the 13 pt gaps, the repost's bubble (its glyph and
    /// 10) and the slack — and, beside it, the Follow's bubble at its word's
    /// width (`followWidth`). Never `•••` (R4): a long name truncates, and on
    /// a narrow bar at a large text size the pill folds to its face.
    static func pillBudget(toolbarWidth: CGFloat, icon: CGFloat, follow: CGFloat?) -> CGFloat {
        let repost = icon + 10
        let beside = follow.map { 13 + $0 } ?? 0
        let reserve = 28 + 10 + beside + 13 + repost + 28 + SnapBarPillWidths.slack
        return max(SnapBarPillWidths.minimum, toolbarWidth - reserve).rounded(.down)
    }

    /// The Follow's bubble for `title` at `traits`' text size: the word in
    /// the bar's semibold body, the glass's padding each side, a glyph's room
    /// for "✓ Following".
    static func followWidth(title: String, glyph: Bool, traits: UITraitCollection) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .body, compatibleWith: traits)
        let semibold = UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        let word = (title as NSString).size(withAttributes: [.font: semibold]).width
        return ceil(word) + 2 * 16 + (glyph ? font.pointSize + 6 : 0)
    }

    /// The Follow's bubble as it stands now; nil without one.
    func currentFollowWidth(traits: UITraitCollection) -> CGFloat? {
        switch face {
        case .none: nil
        case .confirming: Self.followWidth(title: "Following", glyph: true, traits: traits)
        case .offer(let offer): Self.followWidth(title: offer.buttonTitle ?? "Follow", glyph: false, traits: traits)
        }
    }
}
