import CoreGraphics

/// What the badge says about the viewer and the person.
///
/// Only `.follow` is an ACTION (the "+"). The others are STATE, drawn so
/// following someone does not simply make the pill forget it — and so a
/// friend (a mutual follow) reads apart from a one-way follow, and a
/// request a private account has not answered reads apart from both. A
/// state mark takes no tap of its own: it falls through to the pill's.
///
/// ⚠️ `PersonPill.Badge` (MediaUI) is this type, moved down so the author
/// band's model (`PostAuthorBandModel`, PostGridSeam) can carry a mark
/// without MediaCore (#2380). Every host still spells it `PersonPill.Badge`.
public enum PersonRelationBadge: Equatable, Sendable {
    /// Nothing drawn, for good: the viewer themself, someone blocked, or a
    /// host that offers no follow at all. No disc, no cutout.
    case none
    /// The relation is not known yet (#2098): the badge's place is held by
    /// a skeleton bone, its cutout already taken out of the face, so the
    /// mark that lands changes only what the disc draws. No symbol, no
    /// tap, no accessibility element.
    case loading
    /// "+": the viewer does not follow them. A tap follows.
    case follow
    /// The viewer follows them; they do not follow back.
    case following
    /// Both follow each other.
    case friends
    /// The viewer asked a private account to follow them, and the request
    /// is pending (#968).
    case pending

    /// The symbols the owner chose (#925):
    /// - `plus` — the action;
    /// - `checkmark.circle.fill` — the viewer follows them;
    /// - `person.2.fill` — two people: the app already means "Friends" by
    ///   it (the map's Friends filter), and it is the one symbol that says
    ///   the relation goes BOTH ways;
    /// - `clock.circle.fill` — waiting on the other person (#968). Not
    ///   `clock.fill`: that symbol is ONE layer, a white disc with its
    ///   hands cut out, so on the badge it can only be a white disc with
    ///   black hands. `clock.circle.fill` is the same clock in two layers,
    ///   like the check: its circle draws black and its hands white — and
    ///   the two marks a "+" can turn into share one construction.
    public var symbolName: String? {
        switch self {
        case .none, .loading: nil
        case .follow: "plus"
        case .following: "checkmark.circle.fill"
        case .friends: "person.2.fill"
        case .pending: "clock.circle.fill"
        }
    }

    /// The symbol the badge draws: the relation's glyph inside its own
    /// disc (#1199), so the disc and the mark move as one.
    public var circledSymbolName: String {
        switch self {
        case .none, .loading, .follow: "plus.circle.fill"
        case .following: "checkmark.circle.fill"
        case .friends: "person.2.circle.fill"
        case .pending: "clock.circle.fill"
        }
    }

    /// Each glyph's size on the badge's disc: the check and the clock are
    /// discs of their own, as large as it; the "+" and the two people sit
    /// inside it.
    public var pointSize: CGFloat {
        switch self {
        case .following, .pending: 13
        case .friends: 7
        case .none, .loading, .follow: 9
        }
    }

    public var accessibilityLabel: String? {
        switch self {
        case .none, .loading: nil
        case .follow: "Follow"
        case .following: "Following"
        case .friends: "Friends"
        case .pending: "Requested"
        }
    }

    /// Whether the face loses the badge's disc: for every badge drawn, the
    /// skeleton's included — only "no badge, for good" leaves it whole.
    public var cutsTheFace: Bool { self != .none }
}
