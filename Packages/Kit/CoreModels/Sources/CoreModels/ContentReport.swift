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
/// cares — the answer a surface needs to decide whether to offer "Follow".
public enum FollowRelation: Equatable, Sendable {
    /// The person IS the viewer: there is nobody to follow.
    case viewer
    /// The viewer already follows them (a mutual included).
    case following
    /// The viewer does not follow them: the one case that offers "Follow".
    case notFollowing
    /// The viewer blocks them. Following is not on offer until the block is
    /// lifted, which is the profile screen's business.
    case blocked

    /// Whether a follow affordance should be drawn for this person.
    public var offersFollow: Bool { self == .notFollowing }
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
