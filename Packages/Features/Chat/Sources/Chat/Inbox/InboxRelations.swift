import AuthInterface
import CoreModels
import CoreNavigation
import DesignSystem
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
/// VIEWER-SCOPED (`ViewerScoped`, registered in
/// `AppContainer.observeViewerTransitions`): a sign-out or a profile switch
/// drops every answer, so a mark never outlives the viewer it was read for.
@MainActor
public final class InboxRelations: ViewerScoped {
    private let reader: (any SocialGraphReading)?
    private let writer: (any SocialGraphWriting)?
    private var known: [ProfileID: FollowRelation] = [:]
    private var lookups: Set<ProfileID> = []
    /// Peers with a follow on its way: a read that lands meanwhile is older
    /// than the tap and is dropped.
    private var follows: Set<ProfileID> = []
    /// Bumped by a viewer change: a read asked for the previous viewer is
    /// dropped when it lands.
    private var generation = 0
    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor (Set<ProfileID>) -> Void
    }
    private var observers: [Observer] = []

    /// Nil `reader` or `writer`: no mark at all — the "+" would mean nothing.
    public init(reader: (any SocialGraphReading)?, writer: (any SocialGraphWriting)?) {
        self.reader = reader
        self.writer = writer
    }

    /// Whether the rows wear a mark at all.
    var isEnabled: Bool { reader != nil && writer != nil }

    /// The answer for `peer`, nil while it is not known.
    func relation(for peer: ProfileID) -> FollowRelation? {
        known[peer]
    }

    /// Tells `handler` the peers whose answer changed, for as long as
    /// `owner` lives — a list goes with its screen, unregistered by nobody.
    func observe(by owner: AnyObject, _ handler: @escaping @MainActor (Set<ProfileID>) -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    /// The mark a row wears for `peer`: none for a group (nil), a relation
    /// not known yet, or no graph.
    func mark(for peer: ProfileID?) -> PersonPill.Badge {
        guard isEnabled, let peer else { return .none }
        return PersonPill.Badge(relation: known[peer])
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
        for peer in Set(peers) where (refresh || known[peer] == nil) && !lookups.contains(peer) && !follows.contains(peer) {
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
        guard let writer, let before = known[peer], before.offersFollow, !follows.contains(peer) else { return }
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

    private func set(_ relation: FollowRelation, for peer: ProfileID) {
        guard known[peer] != relation else { return }
        known[peer] = relation
        notify([peer])
    }

    /// Drops every answer, and every read in flight (`generation`).
    func reset() {
        generation += 1
        let peers = Set(known.keys)
        known = [:]
        lookups = []
        follows = []
        guard !peers.isEmpty else { return }
        notify(peers)
    }

    private func notify(_ peers: Set<ProfileID>) {
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.handler(peers) }
    }

    public func viewerDidChange(_ state: ViewerState) async {
        reset()
    }

    #if DEBUG
    /// Sets an answer outright. Tests and QA.
    func debugSet(_ relation: FollowRelation, for peer: ProfileID) {
        set(relation, for: peer)
    }
    #endif
}
