import CoreModels
import EntityStore

/// Where the viewer stands with each author the feed's pill shows, and the
/// pill's "+" follow — the state behind the badge, without the pill.
///
/// The answers live in the app's `EntityStore` (#896), not here: every snap
/// feed (For You's vertical feed, the Following feed, a pushed one) reads the
/// same relation per author, so a follow on one is the badge of all of them,
/// and a viewer change forgets them all at once. This keeps what is the
/// screen's own: the lookups and follows it has in flight.
///
/// The screen keeps the drawing (the badge, by its symbol replace),
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
    /// Where the answers live: what the reader answered, per author, and
    /// every follow the graph accepted, from any screen.
    private let entities: EntityStore
    /// What this screen last reported per author through `onRelationChange`
    /// — so a store write that did not move an author's answer (their
    /// profile summary loaded by a list) re-draws nothing, and a viewer
    /// change re-draws every author it had drawn.
    private var reported: [ProfileID: FollowRelation?] = [:]
    private var observation: EntityObservation?
    /// Lookups in flight, so paging back and forth asks once per author.
    private(set) var lookupsInFlight: Set<ProfileID> = []
    /// Follows in flight, so a double tap sends one.
    private(set) var followsInFlight: Set<ProfileID> = []

    /// Called after an author's answer changed — the screen re-draws the
    /// badge and forgets what a pair of pages draws.
    var onRelationChange: ((ProfileID) -> Void)?

    /// Called after every relation was forgotten at once — a viewer change
    /// (#1972): an author whose answer was unknown before and still is
    /// reports nothing through `onRelationChange`, yet must be asked again.
    var onEveryRelationChange: (() -> Void)?

    init(writer: (any SocialGraphWriting)?, reader: (any SocialGraphReading)?, entities: EntityStore = EntityStore()) {
        self.writer = writer
        self.reader = reader
        self.entities = entities
        observation = entities.observeProfiles { [weak self] change in
            self?.entitiesDidChange(change)
        }
    }

    /// Where the viewer stands with `author`, as far as the store knows.
    /// Nil: not known yet, which draws no badge.
    func relation(for author: ProfileID) -> FollowRelation? {
        entities.relation(to: author)
    }

    private func entitiesDidChange(_ change: EntityChange<ProfileID>) {
        let authors: [ProfileID] = switch change {
        case .some(let ids): ids.filter { reported[$0] != nil }
        case .everything: Array(reported.keys)
        }
        for author in authors {
            let relation = entities.relation(to: author)
            guard reported[author] != relation else { continue }
            // `.some`: a nil answer is still a drawn author, not a removal.
            reported[author] = .some(relation)
            onRelationChange?(author)
        }
        if case .everything = change { onEveryRelationChange?() }
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
        guard writer != nil, let author else { return .none }
        let known = relation(for: author)
        // Drawn from now on: a later change of answer is reported.
        if reported[author] == nil { reported[author] = .some(known) }
        guard let known else { return .none }
        return SnapAuthorIdentityView.FollowBadge(known)
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
              refresh || relation(for: author) == nil,
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
        let known = relation(for: author) ?? .notFollowing
        setRelation(known.settingFollow(change.isFollowing), for: author)
    }

    /// Records `relation` in the store — every snap feed hears it — and
    /// reports it to this screen at once.
    func setRelation(_ relation: FollowRelation, for author: ProfileID) {
        entities.setRelation(relation, for: author)
        guard reported[author] != .some(relation) else { return }
        reported[author] = relation
        onRelationChange?(author)
    }

    /// The pill's "+": follows the author, OPTIMISTICALLY — the profile's
    /// Follow button's rule (`ProfileViewModel.toggleFollow`). The "+" turns
    /// at once into the followed mark — the FRIENDS mark for someone who
    /// already follows the viewer — and comes back if the graph refuses,
    /// after which `onRefused` runs.
    ///
    /// A PRIVATE author is asked, not followed (#968): the graph says so, and
    /// the followed mark becomes the pending one. The pill cannot know
    /// beforehand — the relation read carries no privacy — so the optimistic
    /// mark is the followed one, as for everyone.
    ///
    /// Returns whether a follow was sent: nothing is for an author the pill
    /// does not offer "+" for, or while one is already in flight.
    @discardableResult
    func follow(_ author: ProfileID, onRefused: @escaping @MainActor () -> Void) -> Bool {
        guard let writer, offersFollow(to: author), !followsInFlight.contains(author),
              let before = relation(for: author) else { return false }
        followsInFlight.insert(author)
        setRelation(before.settingFollow(true), for: author)
        Task { [weak self] in
            let outcome = try? await writer.follow(author)
            guard let self else { return }
            self.followsInFlight.remove(author)
            switch outcome {
            case .following: return
            case .requested: self.setRelation(.requested, for: author)
            case nil:
                self.setRelation(before, for: author)
                onRefused()
            }
        }
        return true
    }
}
