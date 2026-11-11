import CoreModels
import CoreNavigation
import DesignSystem
import EntityStore
import MediaCore
import UIKit

/// Where the viewer stands with each conversation's peer, for the rows'
/// relation mark (#2049).
///
/// ⚠️ ONE READ PER PEER. There is no batched relation read — not in
/// `social_graph.v1`, and `profile.v1` carries no viewer relation — so the
/// inbox asks `followRelation(to:)` for the peers of the rows on screen and
/// the next page's, concurrently, and keeps the answers here, keyed by peer.
/// A first page on an iPhone 18 Pro costs about twenty calls (ten rows on
/// screen, ten ahead). A batched read (`BatchGetRelationStatus`) would make
/// it one.
///
/// ⚠️ THE ANSWERS LIVE IN THE APP'S ONE PLACE FOR THEM, `EntityStore` (the
/// owner, 2026-11-02: one state per person, everywhere). The thread opened
/// from a row starts from what the row knew instead of loading it again; a
/// follow made anywhere — the thread's "+", a profile card, a profile, the
/// feed — reaches the store through the follow channel and every mark
/// follows. The store's viewer facts are wiped on a sign-out or a profile
/// switch (the cache coordinator), so a mark never outlives the viewer it
/// was read for; reads in flight then are dropped (`generation`).
@MainActor
public final class InboxRelations {
    private let reader: (any SocialGraphReading)?
    private let writer: (any SocialGraphWriting)?
    private let entities: EntityStore
    private var observation: EntityObservation?
    private var lookups: Set<ProfileID> = []
    /// Peers with a follow on its way: a read that lands meanwhile is older
    /// than the tap and is dropped.
    private var follows: Set<ProfileID> = []
    /// Bumped by a viewer change: a read asked for the previous viewer is
    /// dropped when it lands.
    private var generation = 0
    private struct Observer {
        weak var owner: AnyObject?
        /// The peers that changed; nil for every one (a viewer change).
        let handler: @MainActor (Set<ProfileID>?) -> Void
    }
    private var observers: [Observer] = []

    /// Nil `reader` or `writer`: no mark at all — the "+" would mean nothing.
    public init(entities: EntityStore, reader: (any SocialGraphReading)?, writer: (any SocialGraphWriting)?) {
        self.entities = entities
        self.reader = reader
        self.writer = writer
        observation = entities.observeProfiles { [weak self] change in self?.entitiesDidChange(change) }
    }

    /// Whether the rows wear a mark at all.
    var isEnabled: Bool { reader != nil && writer != nil }

    /// The answer for `peer`, nil while it is not known.
    func relation(for peer: ProfileID) -> FollowRelation? {
        entities.relation(to: peer)
    }

    /// Tells `handler` the peers whose answer changed, for as long as
    /// `owner` lives — a list goes with its screen, unregistered by nobody.
    func observe(by owner: AnyObject, _ handler: @escaping @MainActor (Set<ProfileID>?) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    /// The mark a row wears for `peer`: none for a group (nil), a relation
    /// not known yet, or no graph.
    func mark(for peer: ProfileID?) -> PersonPill.Badge {
        guard isEnabled, let peer else { return .none }
        return PersonPill.Badge(relation: entities.relation(to: peer))
    }

    /// The row's "+", from `host`: through the member gate, then `follow`;
    /// a refusal is said over `host` (#802), naming the handle, else the
    /// conversation's title.
    func follow(_ peer: ProfileID, handle: String?, name: String?, from host: UIViewController) {
        MemberGates.perform(.follow(handle: handle), from: host) { [weak self, weak host] in
            self?.follow(peer) {
                guard let host else { return }
                Feedback.failure(PlusFollow.failureMessage(handle: handle, name: name), from: host)
            }
        }
    }

    /// Asks for `peers` not known yet — or again with `refresh`, for answers
    /// that may have moved while the inbox was covered (a follow in the
    /// thread or on the profile). A known answer keeps drawing until the new
    /// one lands; a failed read draws nothing new and blocks nothing.
    func resolve(_ peers: [ProfileID], refresh: Bool = false) {
        guard isEnabled, let reader else { return }
        let generation = generation
        for peer in Set(peers) where (refresh || relation(for: peer) == nil) && !lookups.contains(peer) && !follows.contains(peer) {
            lookups.insert(peer)
            Task { [weak self] in
                let relation = try? await reader.followRelation(to: peer)
                guard let self, self.generation == generation else { return }
                self.lookups.remove(peer)
                guard let relation, !self.follows.contains(peer) else { return }
                self.set(relation, for: peer)
            }
        }
    }

    /// The "+": follows `peer` through the shared seam (`PlusFollow`) —
    /// the check at once, the clock for a private person, the "+" back on a
    /// failure, then a fresh read. `failed` is told when the graph refused.
    /// Does nothing unless the "+" is what `peer` shows.
    func follow(_ peer: ProfileID, failed: @escaping @MainActor () -> Void) {
        guard let writer, let before = relation(for: peer), before.offersFollow, !follows.contains(peer) else { return }
        follows.insert(peer)
        let generation = generation
        PlusFollow.commit(peer, from: before, through: writer, apply: { [weak self] relation in
            guard let self, self.generation == generation else { return }
            self.set(relation, for: peer)
        }, completion: { [weak self] didFail in
            guard let self, self.generation == generation else { return }
            self.follows.remove(peer)
            if didFail { failed() }
            // What the graph now says: following someone who follows back
            // is a friend, and the graph is the one to say so.
            self.resolve([peer], refresh: true)
        })
    }

    // MARK: - Who the peer is (#2049)

    /// What a row knows of its peer — the name and the @handle — kept in
    /// the store, never over what it holds (`ifUnknown`): a thread opened
    /// from the row starts whole instead of filling in under its push.
    func saw(_ model: ConversationDisplayModel) {
        guard let peer = model.peerID else { return }
        entities.upsert(
            AuthorSummary(id: peer, handle: model.peerHandle ?? "", displayName: model.title, avatarURL: nil),
            freshness: .ifUnknown
        )
    }

    /// `avatars`, its answers kept in the store as they land — the face a
    /// row read is the face the thread opens with.
    func recording(_ avatars: (any PeerAvatarProviding)?) -> (any PeerAvatarProviding)? {
        avatars.map { StoreRecordingAvatars(base: $0, entities: entities) }
    }

    /// Written to the store: every surface showing `peer` hears it, these
    /// rows through `entitiesDidChange`.
    private func set(_ relation: FollowRelation, for peer: ProfileID) {
        entities.setRelation(relation, for: peer)
    }

    /// The store moved: the rows showing those people re-read their mark. A
    /// viewer change wiped every answer — reads in flight for the previous
    /// viewer are dropped, and every row is told.
    private func entitiesDidChange(_ change: EntityChange<ProfileID>) {
        switch change {
        case .some(let peers): notify(peers)
        case .everything:
            generation += 1
            lookups = []
            follows = []
            notify(nil)
        }
    }

    private func notify(_ peers: Set<ProfileID>?) {
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.handler(peers) }
    }

    #if DEBUG
    /// Sets an answer outright. Tests and QA.
    func debugSet(_ relation: FollowRelation, for peer: ProfileID) {
        set(relation, for: peer)
    }
    #endif
}

/// A face source whose answers are kept in the app's `EntityStore`, never
/// over what it holds (#2049).
private struct StoreRecordingAvatars: PeerAvatarProviding {
    let base: any PeerAvatarProviding
    let entities: EntityStore

    func avatarURLs(for ids: [ProfileID]) async -> [ProfileID: URL] {
        let urls = await base.avatarURLs(for: ids)
        for (id, url) in urls {
            entities.upsert(AuthorSummary(id: id, handle: "", displayName: "", avatarURL: url), freshness: .ifUnknown)
        }
        return urls
    }

    func handles(for ids: [ProfileID]) async -> [ProfileID: String] {
        await base.handles(for: ids)
    }
}

extension PersonPill.Badge {
    /// The mark for a relation (#2049): the author pill's mapping — "+" for
    /// someone not followed (a follower included: following back makes a
    /// friend), the clock for a request, the check, friends — nothing for
    /// the viewer or someone blocked, and the skeleton's badge for a relation
    /// not known yet (#2098), never nothing. Stayed in Chat when the marked
    /// face moved to MediaCore (#2300): MediaCore knows no `FollowRelation`.
    init(relation: FollowRelation?) {
        self = switch relation {
        case .notFollowing, .followedBy: .follow
        case .following: .following
        case .mutual: .friends
        case .requested: .pending
        case .viewer, .blocked: .none
        case nil: .loading
        }
    }
}
