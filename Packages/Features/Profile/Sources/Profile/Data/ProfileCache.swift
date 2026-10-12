import AuthInterface
import CoreModels
import Foundation
import LocalStore

/// Last-known profiles, keyed by id — the "stale" half of stale-while-revalidate.
///
/// **What this is for.** Switching accounts used to leave the PREVIOUS profile
/// on screen until the network answered. That reads as stale data rather than as
/// a transition, and it is worse than stale: it is the wrong person's name and
/// numbers under the identity you just chose. With a cache, a switch to someone
/// you have already opened renders them immediately and the fetch becomes a
/// silent revalidation.
///
/// **Why the repository does not own it.** `ProfileRepository` is an actor, so
/// every read costs a hop and cannot seed a view synchronously — and seeding
/// synchronously is the entire point. This is `@MainActor` and read on the same
/// turn the switch is handled, so the first frame after a switch already carries
/// the new identity.
///
/// **Two tiers (#893).** Memory is the fast path, bounded by `limit`. Behind
/// it, when the app hands one in, the LocalStore keeps what each profile
/// screen showed (`ProfileDiskTier`), so a COLD START opens the viewer's own
/// profile and the profiles they visited on their last content too, then
/// revalidates exactly as a revisit does. A memory miss reads the device
/// synchronously (one indexed row); every change is written back off the main
/// thread, coalesced per turn. The device tier is viewer-scoped by the store
/// and wiped by the cache coordinator on a viewer change, as memory is here.
///
/// One instance is held by `ProfileFeatureBuilder` for the app's lifetime, so
/// every profile screen shares it.
@MainActor
public final class ProfileCache {
    /// Enough for an account's own profiles plus a browsing session's worth of
    /// other people. Past it the oldest read is dropped — the cost of a miss is
    /// one fetch, which is what would have happened anyway.
    private let limit: Int
    private struct Entry {
        var profile: UserProfile?
        var relationship: ProfileRelationship?
        /// The posts gallery as far as it was loaded (#887): a revisit opens
        /// its grid on them instead of on skeletons, then revalidates.
        var gallery: ProfileGalleryStore.Corpora?
    }
    private var entries: [ProfileID: Entry] = [:]
    /// Ids in least-recently-used order.
    private var recency: [ProfileID] = []
    /// Keeps cached relationships agreeing with a follow made anywhere else
    /// while no screen for that profile is alive to hear it.
    private var followSubscription: FollowGraphSubscription?
    /// Every relationship here is the VIEWER's ("you follow them"): once the
    /// viewer is someone else, none of it is true any more.
    private var viewerObserver: NSObjectProtocol?
    /// The device tier; nil keeps this cache in memory only (tests, previews).
    private let disk: ProfileDiskTier?
    /// Ids the device was asked for and did not have, so a miss reads it once.
    private var missingOnDisk: Set<ProfileID> = []
    /// Ids changed this turn, written back together at its end.
    private var pendingWrites: Set<ProfileID> = []
    private var writeScheduled = false
    /// Which profile is the viewer's own, once known.
    private var currentUser: ProfileID?
    /// Whether the device was asked which profile is the viewer's own.
    private var askedDiskForCurrentUser = false

    /// `center` is where viewer changes are heard: the default one; a test
    /// hands its own, since posting on the shared one reaches every suite.
    /// `store` is the device tier (#893); nil keeps the cache in memory.
    public init(limit: Int = 16, center: NotificationCenter = .default, store: LocalStore? = nil) {
        self.limit = limit
        disk = store.map(ProfileDiskTier.init(store:))
        viewerObserver = center.addObserver(
            forName: .viewerDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeAll() }
        }
    }

    /// Forgets everything — what a change of viewer calls. The device tier is
    /// wiped by the cache coordinator on the same change.
    public func removeAll() {
        entries.removeAll()
        recency.removeAll()
        missingOnDisk.removeAll()
        pendingWrites.removeAll()
        currentUser = nil
        askedDiskForCurrentUser = false
    }

    public func profile(for id: ProfileID) -> UserProfile? {
        loadFromDisk(id)
        guard let profile = entries[id]?.profile else { return nil }
        touch(id)
        return profile
    }

    public func store(_ profile: UserProfile) {
        entries[profile.id, default: Entry()].profile = profile
        touch(profile.id)
        persist(profile.id)
    }

    /// Which profile is the viewer's own, as last loaded: what the viewer's
    /// own profile screen seeds from at a cold start, before the network
    /// can say who they are (#893).
    public func currentUserID() -> ProfileID? {
        if currentUser == nil, !askedDiskForCurrentUser {
            askedDiskForCurrentUser = true
            currentUser = disk?.currentUserID()
        }
        return currentUser
    }

    /// Records `id` as the viewer's own profile (it is then kept longest).
    public func storeCurrentUser(_ id: ProfileID) {
        guard currentUser != id else { return }
        currentUser = id
        persist(id)
    }

    /// The viewer's relationship to `id` as last read or changed here — the
    /// Follow / Following a revisit opens on. Stale-while-revalidate like the
    /// profile: the screen reads it again and corrects in place.
    public func relationship(for id: ProfileID) -> ProfileRelationship? {
        loadFromDisk(id)
        return entries[id]?.relationship
    }

    public func store(_ relationship: ProfileRelationship, for id: ProfileID) {
        loadFromDisk(id)
        dropGalleryIfHidden(by: relationship, for: id)
        entries[id, default: Entry()].relationship = relationship
        touch(id)
        persist(id)
    }

    /// The gallery pages last loaded for `id`, as far as they went — what a
    /// revisit renders at frame 0 (#887). Stale-while-revalidate like the
    /// profile: the screen fetches the first pages again and merges them in.
    func gallery(for id: ProfileID) -> ProfileGalleryStore.Corpora? {
        loadFromDisk(id)
        return entries[id]?.gallery
    }

    /// Keeps the gallery a screen holds. A corpus the screen has not loaded
    /// (a failed fetch) keeps the one already cached: the next visit still
    /// has something true-ish to open on, and revalidates it.
    func store(_ gallery: ProfileGalleryStore.Corpora, for id: ProfileID) {
        loadFromDisk(id)
        let kept = entries[id]?.gallery
        entries[id, default: Entry()].gallery = ProfileGalleryStore.Corpora(
            authored: gallery.authored ?? kept?.authored,
            tagged: gallery.tagged ?? kept?.tagged
        )
        touch(id)
        persist(id)
    }

    /// Forgets `id`'s gallery: what it showed may no longer be what the viewer
    /// may see.
    func removeGallery(for id: ProfileID) {
        loadFromDisk(id)
        guard entries[id]?.gallery != nil else { return }
        entries[id]?.gallery = nil
        persist(id)
    }

    /// ⚠️ A FOLLOW OR A BLOCK CAN CHANGE WHAT THE GALLERY SHOWS. A private
    /// profile's posts are its followers' alone, and a block hides them both
    /// ways: kept across either change, a revisit would open on posts the
    /// viewer can no longer see, or on an empty grid for ones they now can.
    /// A public profile's gallery is the same whoever follows it.
    private func dropGalleryIfHidden(by relationship: ProfileRelationship, for id: ProfileID) {
        guard let old = entries[id]?.relationship, entries[id]?.gallery != nil else { return }
        let isPublic = entries[id]?.profile.map { !$0.visibility.isPrivate } ?? false
        let (wasFollowing, wasBlocked) = Self.edges(of: old)
        let (following, blocked) = Self.edges(of: relationship)
        if blocked != wasBlocked || (!isPublic && following != wasFollowing) {
            entries[id]?.gallery = nil
        }
    }

    private static func edges(of relationship: ProfileRelationship) -> (following: Bool, blocked: Bool) {
        switch relationship {
        case .me, .requested, .cannotFollow: (false, false)
        case .other(let following, _, let blocked): (following, blocked)
        }
    }

    /// Hears the app's follow channel, once. A follow accepted on a card or
    /// in a list updates the cached answer, so the next visit does not open
    /// on the old one and flip.
    public func observe(_ events: FollowGraphEvents?) {
        guard followSubscription == nil, let events else { return }
        followSubscription = events.subscribeOnMain { [weak self] change in
            self?.followGraphDidChange(change)
        }
    }

    private func followGraphDidChange(_ change: FollowChange) {
        // A profile visited in an earlier session hears it too: its device
        // copy must not reopen on the old answer, or on posts it now hides.
        loadFromDisk(change.profileID)
        guard case .other(let wasFollowing, let isMutual, let isBlocked)? = entries[change.profileID]?.relationship,
              wasFollowing != change.isFollowing else { return }
        // Mutual implies following: an unfollow ends it. A follow cannot say
        // whether they follow back, so it keeps what was known.
        let relationship = ProfileRelationship.other(
            isFollowing: change.isFollowing,
            isMutual: change.isFollowing && isMutual,
            isBlocked: isBlocked
        )
        dropGalleryIfHidden(by: relationship, for: change.profileID)
        entries[change.profileID]?.relationship = relationship
        persist(change.profileID)
    }

    // MARK: - Device tier

    /// Fills memory from the device for an id memory does not hold. Read once
    /// per id: a miss is remembered until something is stored for it.
    private func loadFromDisk(_ id: ProfileID) {
        guard entries[id] == nil, let disk, !missingOnDisk.contains(id) else { return }
        guard let record = disk.record(for: id) else {
            missingOnDisk.insert(id)
            return
        }
        entries[id] = Entry(
            profile: record.profile?.userProfile,
            relationship: record.relationship?.relationship,
            gallery: record.gallery?.corpora
        )
        touch(id)
    }

    /// Writes `id`'s entry back at the end of this turn, with every other
    /// change of the turn: a profile, its relationship and its gallery landing
    /// together cost one write.
    private func persist(_ id: ProfileID) {
        guard let disk else { return }
        missingOnDisk.remove(id)
        pendingWrites.insert(id)
        guard !writeScheduled else { return }
        writeScheduled = true
        // Who the entries belong to, asked now: memory holds this viewer's.
        let viewer = disk.viewer
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.writePending(as: viewer) }
        }
    }

    private func writePending(as viewer: LocalStoreViewer?) {
        writeScheduled = false
        let ids = pendingWrites
        pendingWrites.removeAll()
        guard let disk, !ids.isEmpty else { return }
        var records: [ProfileID: ProfileDiskRecord] = [:]
        for id in ids {
            guard let entry = entries[id] else { continue }
            records[id] = ProfileDiskRecord(
                profile: entry.profile.map(ProfileDiskRecord.Header.init),
                relationship: entry.relationship.map(ProfileDiskRecord.Relationship.init),
                gallery: entry.gallery.map(ProfileDiskRecord.Gallery.init)
            )
        }
        disk.save(records, currentUser: currentUser.flatMap { ids.contains($0) ? $0 : nil }, as: viewer)
    }

    /// Waits until every change so far is on the device. Tests only.
    func waitForDeviceWrites() {
        if writeScheduled { writePending(as: disk?.viewer) }
        disk?.waitForPendingWrites()
    }

    private func touch(_ id: ProfileID) {
        recency.removeAll { $0 == id }
        recency.append(id)
        while recency.count > limit, let oldest = recency.first {
            recency.removeFirst()
            entries[oldest] = nil
        }
    }
}
