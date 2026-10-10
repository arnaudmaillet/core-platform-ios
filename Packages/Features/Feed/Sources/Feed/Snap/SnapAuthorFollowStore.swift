import CoreModels

/// Where the viewer stands with each author the feed's pill shows, and the
/// pill's "+" follow — the state behind the badge, without the pill.
///
/// The screen keeps the drawing (the badge, through the pill's own blur),
/// the member gate, the failure toast and the graph-event subscription; it
/// hears every change of answer through `onRelationChange`.
///
/// Unit-tested without a screen (`SnapAuthorFollowStoreTests`).
@MainActor
final class SnapAuthorFollowStore {
    /// Follows an author from the pill's "+", and says what the pill's badge
    /// draws. The pill draws one only when BOTH are wired and the reader has
    /// answered for the author — see `badge(for:)`.
    private let writer: (any SocialGraphWriting)?
    private let reader: (any SocialGraphReading)?
    /// What the reader answered, per author, overlaid by this screen's own
    /// follows. Absent: not known yet, which draws no badge.
    private(set) var relationsByAuthor: [ProfileID: FollowRelation] = [:]
    /// Lookups in flight, so paging back and forth asks once per author.
    private(set) var lookupsInFlight: Set<ProfileID> = []
    /// Follows in flight, so a double tap sends one.
    private(set) var followsInFlight: Set<ProfileID> = []

    /// Called after an author's answer changed — the screen re-draws the
    /// badge and forgets what a pair of pages draws.
    var onRelationChange: ((ProfileID) -> Void)?

    init(writer: (any SocialGraphWriting)?, reader: (any SocialGraphReading)?) {
        self.writer = writer
        self.reader = reader
    }

    /// What the pill's badge draws for `author`: "+" for someone the viewer
    /// does not follow, the followed mark for a one-way follow, the friends
    /// mark for a mutual one — and nothing for the viewer's own posts, someone
    /// blocked, or without a follow seam to act through.
    ///
    /// Unknown is NOTHING — a "+" drawn for someone the viewer follows and
    /// then withdrawn is worse than a badge that arrives late (the neighbours'
    /// answers are asked for at every settle, so a paged-to author is usually
    /// known already).
    func badge(for author: ProfileID?) -> SnapAuthorIdentityView.FollowBadge {
        guard writer != nil, let author,
              let relation = relationsByAuthor[author] else { return .none }
        return SnapAuthorIdentityView.FollowBadge(relation)
    }

    /// Whether the pill offers "+" for `author`.
    func offersFollow(to author: ProfileID?) -> Bool {
        badge(for: author) == .follow
    }

    /// Asks the graph where the viewer stands with `author`, once per author
    /// — or again with `refresh`, for an answer that may have moved while the
    /// screen was covered (a follow on the author's own profile). The cached
    /// answer keeps drawing until the new one lands.
    func resolve(for author: ProfileID, refresh: Bool = false) {
        guard writer != nil, let reader,
              refresh || relationsByAuthor[author] == nil,
              !lookupsInFlight.contains(author), !followsInFlight.contains(author) else { return }
        lookupsInFlight.insert(author)
        Task { [weak self] in
            let relation = try? await reader.followRelation(to: author)
            guard let self else { return }
            self.lookupsInFlight.remove(author)
            // A tap that followed while the question was out outranks it.
            guard let relation, !self.followsInFlight.contains(author) else { return }
            self.setRelation(relation, for: author)
        }
    }

    /// A follow or unfollow the graph accepted, from any surface. This
    /// screen's own tap comes back through here too, and changes nothing: the
    /// answer is already the one it drew. The viewer themself, and someone
    /// they block, keep their answer — an unfollow does not make either
    /// followable (`settingFollow`). Whether the author follows the viewer
    /// BACK is kept too: following a follower makes a friend.
    func graphDidChange(_ change: FollowChange) {
        let author = change.profileID
        guard !followsInFlight.contains(author) else { return }
        let known = relationsByAuthor[author] ?? .notFollowing
        setRelation(known.settingFollow(change.isFollowing), for: author)
    }

    func setRelation(_ relation: FollowRelation, for author: ProfileID) {
        guard relationsByAuthor[author] != relation else { return }
        relationsByAuthor[author] = relation
        onRelationChange?(author)
    }

    /// The pill's "+": follows the author, OPTIMISTICALLY — the profile's
    /// Follow button's rule (`ProfileViewModel.toggleFollow`). The "+" turns
    /// at once into the followed mark — the FRIENDS mark for someone who
    /// already follows the viewer — and comes back if the graph refuses,
    /// after which `onRefused` runs.
    ///
    /// Returns whether a follow was sent: nothing is for an author the pill
    /// does not offer "+" for, or while one is already in flight.
    @discardableResult
    func follow(_ author: ProfileID, onRefused: @escaping @MainActor () -> Void) -> Bool {
        guard let writer, offersFollow(to: author), !followsInFlight.contains(author),
              let before = relationsByAuthor[author] else { return false }
        followsInFlight.insert(author)
        setRelation(before.settingFollow(true), for: author)
        Task { [weak self] in
            let accepted = (try? await writer.setFollowing(true, for: author)) != nil
            guard let self else { return }
            self.followsInFlight.remove(author)
            guard !accepted else { return }
            self.setRelation(before, for: author)
            onRefused()
        }
        return true
    }
}
