import CoreModels
import CoreStorage
import EntityStore
import PostGrid

/// Where the viewer stands with each author a surface shows, and the shared
/// follow: the state behind the badge (passive since #2419) and behind the
/// Follow buttons that took over from the face's "+".
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
final public class SnapAuthorFollowStore {
    /// Follows an author from the pill's "+", and says what the pill's badge
    /// draws. The pill draws one only when BOTH are wired and the reader has
    /// answered for the author — see `badge(for:)`.
    private let writer: (any SocialGraphWriting)?
    private let reader: (any SocialGraphReading)?
    /// Where the answers live: what the reader answered, per author, and
    /// every follow the graph accepted, from any screen.
    private let entities: any ProfileEntityReading & ProfileEntityWriting
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
    public var onRelationChange: ((ProfileID) -> Void)?

    /// Called after every relation was forgotten at once — a viewer change
    /// (#1972): an author whose answer was unknown before and still is
    /// reports nothing through `onRelationChange`, yet must be asked again.
    public var onEveryRelationChange: (() -> Void)?

    /// The profile using the app: its own posts wear no badge from the first
    /// frame, never the skeleton's first (#2098) — the reader's `.viewer`
    /// answer would come a call later.
    private let viewer: @MainActor () -> ProfileID?

    public init(
        writer: (any SocialGraphWriting)?, reader: (any SocialGraphReading)?, entities: any ProfileEntityReading & ProfileEntityWriting = EntityStore(),
        viewer: @escaping @MainActor () -> ProfileID?
    ) {
        self.writer = writer
        self.reader = reader
        self.entities = entities
        self.viewer = viewer
        observation = entities.observeProfiles { [weak self] change in
            self?.entitiesDidChange(change)
        }
    }

    /// Where the viewer stands with `author`, as far as the store knows.
    /// Nil: not known yet, which draws the skeleton's badge.
    public func relation(for author: ProfileID) -> FollowRelation? {
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

    /// What the badge draws for `author`: the followed mark for a one-way
    /// follow, the friends mark for a mutual one, and nothing for someone the
    /// viewer doesn't follow or asked (#2419), the viewer's own posts, someone
    /// blocked, or without a follow seam to act through.
    ///
    /// Unknown is the SKELETON'S BADGE (#2098), never a guess: a mark drawn
    /// and then withdrawn is worse than one that lands late. A read that
    /// fails leaves it until a later one answers.
    public func badge(for author: ProfileID?) -> SnapAuthorIdentityView.FollowBadge {
        guard writer != nil, let author else { return .none }
        if author == viewer() { return .none }
        let known = relation(for: author)
        // Drawn from now on: a later change of answer is reported.
        if reported[author] == nil { reported[author] = .some(known) }
        // No reader: no answer is coming, so nothing rather than a bone
        // that never resolves.
        guard let known else { return reader == nil ? .none : .loading }
        return SnapAuthorIdentityView.FollowBadge(known)
    }

    /// What a Follow button offers for `author` (#2419): Follow, Follow back,
    /// Requested, or nothing (the viewer's own posts, someone blocked, a
    /// relation not known yet, no follow seam). Followed reads `.following`,
    /// which draws no button at rest.
    public func followOffer(for author: ProfileID?) -> AuthorFollowOffer {
        guard writer != nil, let author, author != viewer() else { return .none }
        let known = relation(for: author)
        if reported[author] == nil { reported[author] = .some(known) }
        return AuthorFollowOffer(relation: known)
    }

    /// Whether a follow is on offer for `author`.
    func offersFollow(to author: ProfileID?) -> Bool {
        guard writer != nil, let author, author != viewer() else { return false }
        return relation(for: author)?.offersFollow == true
    }

    /// Asks the graph where the viewer stands with `author`, once per author
    /// — or again with `refresh`, for an answer that may have moved while the
    /// screen was covered (a follow on the author's own profile). The cached
    /// answer keeps drawing until the new one lands.
    public func resolve(for author: ProfileID, refresh: Bool = false) {
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
    public func graphDidChange(_ change: FollowChange) {
        let author = change.profileID
        guard !followsInFlight.contains(author) else { return }
        let known = relation(for: author) ?? .notFollowing
        setRelation(known.settingFollow(change.isFollowing), for: author)
    }

    /// Records `relation` in the store — every snap feed hears it — and
    /// reports it to this screen at once.
    public func setRelation(_ relation: FollowRelation, for author: ProfileID) {
        entities.setRelation(relation, for: author)
        guard reported[author] != .some(relation) else { return }
        reported[author] = relation
        onRelationChange?(author)
    }

    /// The shared follow (a Follow button's, #2419): follows the author,
    /// OPTIMISTICALLY — the profile's Follow button's rule
    /// (`ProfileViewModel.toggleFollow`). The relation turns at once into the
    /// followed one (a FRIEND for someone who already follows the viewer) and
    /// comes back if the graph refuses, after which `onRefused` runs.
    ///
    /// A PRIVATE author is asked, not followed (#968): the graph says so, and
    /// the relation becomes the pending request. Nothing tells beforehand,
    /// since the relation read carries no privacy, so the optimistic answer
    /// is the followed one, as for everyone.
    ///
    /// Returns whether a follow was sent: nothing is for an author with no
    /// follow on offer, or while one is already in flight.
    @discardableResult
    public func follow(_ author: ProfileID, onRefused: @escaping @MainActor () -> Void) -> Bool {
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

    /// Cancels the pending request to `author` (#2419: Requested's menu),
    /// OPTIMISTICALLY: the relation is "not followed" at once, then read
    /// again (a follower is Follow back); it comes back to the request if
    /// the graph refuses, after which `onRefused` runs.
    /// Returns whether a withdrawal was sent.
    @discardableResult
    public func cancelRequest(to author: ProfileID, onRefused: @escaping @MainActor () -> Void) -> Bool {
        guard let writer, relation(for: author) == .requested, !followsInFlight.contains(author) else { return false }
        followsInFlight.insert(author)
        setRelation(.notFollowing, for: author)
        Task { [weak self] in
            let withdrawn = (try? await writer.withdrawFollowRequest(to: author)) != nil
            guard let self else { return }
            self.followsInFlight.remove(author)
            guard withdrawn else {
                self.setRelation(.requested, for: author)
                onRefused()
                return
            }
            // A request carries no inbound half: whether they follow the
            // viewer (Follow back) is the graph's to say again.
            self.resolve(for: author, refresh: true)
        }
        return true
    }

    /// Whether `author` is the viewer: their own posts offer no follow, and
    /// the full-screen page's pill stands stretched from the start (#2409).
    public func isViewer(_ author: ProfileID?) -> Bool {
        author != nil && author == viewer()
    }

    /// Unfollows the author (#2409: the share sheet's Unfollow, the page's
    /// Follow never undoing itself), OPTIMISTICALLY — the inbound half kept
    /// (`settingFollow`), so a friend becomes a follower. Put back if the
    /// graph refuses, after which `onRefused` runs. Returns whether an
    /// unfollow was sent: nothing for an author the viewer does not follow,
    /// or while a follow is in flight.
    @discardableResult
    public func unfollow(_ author: ProfileID, onRefused: @escaping @MainActor () -> Void) -> Bool {
        guard let writer, let before = relation(for: author), before.isFollowing,
              !followsInFlight.contains(author) else { return false }
        followsInFlight.insert(author)
        setRelation(before.settingFollow(false), for: author)
        Task { [weak self] in
            let done = (try? await writer.setFollowing(false, for: author)) != nil
            guard let self else { return }
            self.followsInFlight.remove(author)
            guard !done else { return }
            self.setRelation(before, for: author)
            onRefused()
        }
        return true
    }
}
