/// Why a viewer is reporting something.
///
/// A deliberately short list. `moderation.v1`'s `PolicyCategory` carries nine
/// values, but three of them (`csam`, `ncii`, `violentExtremism`) are
/// legal-escalation categories that belong behind a dedicated, guided flow
/// rather than a one-tap menu row, and `unspecified` is not a user intent. The
/// rest map 1:1 onto the wire enum.
public enum ReportReason: String, CaseIterable, Sendable {
    case spam
    case harassment
    case hate
    case misinformation
    case other

    /// The row title in the reason picker.
    public var title: String {
        switch self {
        case .spam: "Spam or scam"
        case .harassment: "Harassment or bullying"
        case .hate: "Hate speech"
        case .misinformation: "False information"
        case .other: "Something else"
        }
    }
}

/// What is being reported.
///
/// The wire's `EntityType` has seven values; this carries the two the app can
/// actually raise a case about today. Adding a case here is the whole cost of
/// letting comments or chat messages be reported — the transport already
/// accepts them.
public enum ReportSubject: Equatable, Sendable {
    case profile(ProfileID)
    case post(PostID)
}

/// Files moderation reports.
///
/// Kept apart from the read-side protocols on purpose: reporting is a
/// moderation-domain COMMAND with its own service and its own failure
/// semantics. It lives in `CoreModels` rather than in a feature's interface
/// package because two features raise cases now — a profile's "..." menu and a
/// post card's — and neither may import the other.
public protocol ContentReporting: Sendable {
    /// Opens a moderation case against `subject`.
    ///
    /// `surface` names WHERE the report was raised, for the moderation queue's
    /// triage — the contract's `SubjectRef.surface` is a free-form string, and
    /// "reported from the following feed" and "reported from a profile" are
    /// different signals about the same post.
    ///
    /// Throws if the report was not accepted: the caller surfaces that, because
    /// a silently-dropped report is worse than an honest failure.
    func report(_ subject: ReportSubject, reason: ReportReason, surface: String) async throws
}

/// Follows and unfollows on the viewer's behalf.
///
/// The write half of the social graph, extracted so a surface that shows an
/// author — a feed row's "..." menu — can act on the relationship without
/// importing the Profile feature that owns the read model. One method, because
/// one method is all any of those surfaces needs; anything richer belongs to
/// the profile screen.
public protocol SocialGraphWriting: Sendable {
    func setFollowing(_ following: Bool, for profileID: ProfileID) async throws
}

/// Where the viewer stands with one person, as far as a follow affordance
/// cares — the answer a surface needs to decide whether to offer "Follow",
/// and what to draw once it is no longer on offer.
///
/// Both DIRECTIONS of the edge are here, not just the viewer's: a mutual
/// follow is a FRIEND (social_graph.v1's `RelationStatus.mutual`, the map's
/// "Friends" filter), and it is drawn differently from a one-way follow. The
/// inbound half also has to be known while the viewer does NOT follow back —
/// following someone who already follows the viewer makes a friend, not a
/// one-way follow, and a surface that follows optimistically has to draw the
/// right one before the graph confirms (`settingFollow(_:)`).
public enum FollowRelation: Equatable, Sendable {
    /// The person IS the viewer: there is nobody to follow.
    case viewer
    /// The viewer follows them, and they do not follow back.
    case following
    /// Both follow each other: a friend.
    case mutual
    /// Neither follows the other. Offers "Follow".
    case notFollowing
    /// They follow the viewer, who does not follow back. Offers "Follow" too
    /// — following back is what makes a friend.
    case followedBy
    /// The viewer blocks them. Following is not on offer until the block is
    /// lifted, which is the profile screen's business.
    case blocked
    /// They're private and the viewer asked to follow them; the request is
    /// pending (social_graph.v1 `REQUESTED`). Following isn't on offer again:
    /// the profile screen withdraws the request.
    case requested

    /// Whether a follow affordance should be drawn for this person.
    public var offersFollow: Bool { self == .notFollowing || self == .followedBy }

    /// Whether the viewer follows them — a friend included.
    public var isFollowing: Bool { self == .following || self == .mutual }

    /// This relation after the viewer follows (`true`) or unfollows them —
    /// the INBOUND half is kept, so following someone who follows the viewer
    /// makes a friend, and unfollowing a friend leaves someone who still
    /// follows the viewer. The viewer themself and a blocked person do not
    /// move: neither is followable.
    public func settingFollow(_ follows: Bool) -> FollowRelation {
        switch self {
        case .viewer, .blocked: self
        case .requested: follows ? .requested : .notFollowing
        case .following, .notFollowing: follows ? .following : .notFollowing
        case .mutual, .followedBy: follows ? .mutual : .followedBy
        }
    }
}

/// Reads the viewer's relation to one person.
///
/// The read half beside `SocialGraphWriting`, for the same reason and with the
/// same shape: a surface that shows an author (the snap feed's author pill)
/// has to know whether its "+" means anything, without importing the Profile
/// feature that owns the relationship model.
public protocol SocialGraphReading: Sendable {
    func followRelation(to profileID: ProfileID) async throws -> FollowRelation
}
