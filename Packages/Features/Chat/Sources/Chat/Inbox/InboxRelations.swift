import CoreModels
import CoreNavigation
import DesignSystem
import EntityStore
import MediaCore
import MediaUI
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
/// follow made anywhere — a profile card, a profile, the feed — reaches the
/// store through the follow channel and every mark follows. The rows' mark
/// is passive (#2419): no follow from a conversation row. The store's viewer facts are wiped on a sign-out or a profile
/// switch (the cache coordinator), so a mark never outlives the viewer it
/// was read for; reads in flight then are dropped (`generation`).
///
/// It sees the store through `ProfileEntityReading` and
/// `ProfileEntityWriting` (#2377): the people and the viewer's relations, no
/// posts. Tests hand it a fake.
@MainActor
public final class InboxRelations {
    private let reader: (any SocialGraphReading)?
    private let writer: (any SocialGraphWriting)?
    private let entities: any ProfileEntityReading & ProfileEntityWriting
    private var observation: EntityObservation?
    private var lookups: Set<ProfileID> = []
    /// Bumped by a viewer change: a read asked for the previous viewer is
    /// dropped when it lands.
    private var generation = 0
    private struct Observer {
        weak var owner: AnyObject?
        /// The peers that changed; nil for every one (a viewer change).
        let handler: @MainActor (Set<ProfileID>?) -> Void
    }
    private var observers: [Observer] = []

    /// Nil `reader` or `writer`: no mark at all — no graph to stand in.
    public init(
        entities: any ProfileEntityReading & ProfileEntityWriting,
        reader: (any SocialGraphReading)?,
        writer: (any SocialGraphWriting)?
    ) {
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

    /// Asks for `peers` not known yet — or again with `refresh`, for answers
    /// that may have moved while the inbox was covered (a follow in the
    /// thread or on the profile). A known answer keeps drawing until the new
    /// one lands; a failed read draws nothing new and blocks nothing.
    func resolve(_ peers: [ProfileID], refresh: Bool = false) {
        guard isEnabled, let reader else { return }
        let generation = generation
        for peer in Set(peers) where (refresh || relation(for: peer) == nil) && !lookups.contains(peer) {
            lookups.insert(peer)
            Task { [weak self] in
                let relation = try? await reader.followRelation(to: peer)
                guard let self, self.generation == generation else { return }
                self.lookups.remove(peer)
                guard let relation else { return }
                self.set(relation, for: peer)
            }
        }
    }

    // MARK: - Who the peer is (#2049)

    /// What a row knows of its peer — the name and the @handle — kept in
    /// the store, never over what it holds (`ifUnknown`): a thread opened
    /// from the row starts whole instead of filling in under its push.
    func saw(_ model: ConversationDisplayModel) {
        guard let peer = model.peerID else { return }
        entities.upsert(
            AuthorSummary(id: peer, handle: model.peerHandle ?? "", displayName: model.title, avatarURL: nil),
            tier: .recent,
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
    let entities: any ProfileEntityWriting

    func avatarURLs(for ids: [ProfileID]) async -> [ProfileID: URL] {
        let urls = await base.avatarURLs(for: ids)
        for (id, url) in urls {
            entities.upsert(AuthorSummary(id: id, handle: "", displayName: "", avatarURL: url), tier: .recent, freshness: .ifUnknown)
        }
        return urls
    }

    func handles(for ids: [ProfileID]) async -> [ProfileID: String] {
        await base.handles(for: ids)
    }
}

extension PersonPill.Badge {
    /// The mark for a relation (#2049): the author pill's mapping — the
    /// check, friends (#2419: Following and Friends only), nothing for
    /// someone not followed, a request, the viewer or someone blocked, and
    /// the skeleton's badge for a relation not known yet (#2098), never
    /// nothing. Stayed in Chat when the marked face moved to MediaCore
    /// (#2300): MediaCore knows no `FollowRelation`.
    init(relation: FollowRelation?) {
        self = switch relation {
        case .following: .following
        case .mutual: .friends
        case .notFollowing, .followedBy, .requested, .viewer, .blocked: .none
        case nil: .loading
        }
    }
}
