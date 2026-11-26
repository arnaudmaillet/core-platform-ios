import CoreGraphics

/// What the badge on a person's face says about the viewer and the person.
///
/// INFORMATION, NEVER A CONTROL (#2419, the owner 2026-11-13): the badge
/// keeps only the two relations worth reading on a face, a one-way follow
/// and a friend (a mutual follow). Someone the viewer doesn't follow, or
/// asked to follow, wears no badge: the face stays whole. Following is done
/// with a Follow button (the post lists' row action, the full-screen page's),
/// never on the face, and the badge takes no touch on any host.
///
/// ⚠️ `PersonPill.Badge` (MediaUI) is this type, moved down so the author
/// band's model (`PostAuthorBandModel`, PostGridSeam) can carry a mark
/// without MediaCore (#2380). Every host still spells it `PersonPill.Badge`.
public enum PersonRelationBadge: Equatable, Sendable {
    /// Nothing drawn: the viewer themself, someone blocked, someone the
    /// viewer doesn't follow (a follower included), a request still pending,
    /// or a host with no graph. No disc, no cutout.
    case none
    /// The relation is not known yet (#2098): the badge's place is held by
    /// a skeleton bone, its cutout already taken out of the face, so the
    /// mark that lands changes only what the disc draws, and a relation that
    /// turns out to draw nothing closes the cutout as the bone fades.
    /// No symbol, no accessibility element.
    case loading
    /// The viewer follows them; they do not follow back.
    case following
    /// Both follow each other.
    case friends

    /// The symbols the owner chose (#925):
    /// - `checkmark.circle.fill`: the viewer follows them;
    /// - `person.2.fill`: two people. The app already means "Friends" by
    ///   it (the map's Friends filter), and it is the one symbol that says
    ///   the relation goes BOTH ways.
    public var symbolName: String? {
        switch self {
        case .none, .loading: nil
        case .following: "checkmark.circle.fill"
        case .friends: "person.2.fill"
        }
    }

    /// The symbol the badge draws: the relation's glyph inside its own
    /// disc (#1199), so the disc and the mark move as one. No badge draws a
    /// circled symbol in clear ink, so a badge appearing or leaving is a
    /// replace too: it grows in from its centre, or shrinks into it.
    public var circledSymbolName: String {
        switch self {
        case .none, .loading: "plus.circle.fill"
        case .following: "checkmark.circle.fill"
        case .friends: "person.2.circle.fill"
        }
    }

    /// Each glyph's size on the badge's disc: the check is a disc of its
    /// own, as large as it; the two people sit inside it.
    public var pointSize: CGFloat {
        switch self {
        case .following: 13
        case .friends: 7
        case .none, .loading: 9
        }
    }

    /// The badge's words, read with the face ("Following", "Friends").
    public var accessibilityLabel: String? {
        switch self {
        case .none, .loading: nil
        case .following: "Following"
        case .friends: "Friends"
        }
    }

    /// Whether the face loses the badge's disc: for every badge drawn, the
    /// skeleton's included. Only "no badge" leaves it whole.
    public var cutsTheFace: Bool { self != .none }
}
