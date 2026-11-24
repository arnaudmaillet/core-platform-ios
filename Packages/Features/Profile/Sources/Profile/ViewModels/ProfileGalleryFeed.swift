import CoreModels
import CoreNetworking
import DesignSystem
import PostGrid
import ProfileData

/// What the gallery's paging asks of its view model (#2522): the profile,
/// whose it is and how the viewer stands with it, where the pages, Undo and
/// results go, and the refresh a failed first page falls back to.
@MainActor
protocol ProfileGalleryFeedHost: AnyObject {
    var profile: UserProfile? { get }
    var isOwnProfile: Bool { get }
    var isBlocked: Bool { get }
    var isFollowing: Bool { get }
    var isPrivateToViewer: Bool { get }
    var isRelationshipSettled: Bool { get }
    var followButton: ProfileViewModel.FollowButton { get }
    var onGalleryChange: ((ProfileViewModel.GallerySnapshot) -> Void)? { get }
    var onUndoable: ((UndoableAction) -> Void)? { get }
    var onActionResult: ((ProfileViewModel.ActionResult) -> Void)? { get }
    func refresh()
}

/// The gallery's pages, out of `ProfileViewModel` (#2522): the first pages
/// and the next ones, the Liked and Saved reads beside them, the tab's
/// source, a feed's continuation, deleting a post with Undo, and the
/// snapshot it publishes. It owns `galleryStore`; Saved and History write
/// their own pages in it.
///
/// ⚠️ THE NEXT PAGES HOLD THE VIEW MODEL WHILE THEY RUN
/// (`appendGalleryPages`, `let host = self.host`): the view model used to be
/// what that Task kept alive, and the host is `unowned`.
@MainActor
final class ProfileGalleryFeed {
    typealias GallerySnapshot = ProfileViewModel.GallerySnapshot

    private unowned let host: any ProfileGalleryFeedHost
    private let gallery: (any ProfileGalleryProviding)?
    private let galleryPreferences: GalleryPreferences?
    private let cache: ProfileCache?

    init(
        host: any ProfileGalleryFeedHost,
        gallery: (any ProfileGalleryProviding)?,
        galleryPreferences: GalleryPreferences?,
        cache: ProfileCache?,
        postDeleted: (@MainActor (PostID) -> Void)?
    ) {
        self.host = host
        self.gallery = gallery
        self.galleryPreferences = galleryPreferences
        self.cache = cache
        self.postDeleted = postDeleted
    }

    /// The corpora, their paging and failures, and the pages built from them
    /// (#846). This view model fetches and publishes; the store decides.
    let galleryStore = ProfileGalleryStore()
    public var galleryFilter: GalleryFilter { galleryStore.filter }
    private var galleryLoad: Task<Void, Never>?
    /// Whether the last first-page load came back with a failure (either
    /// corpus): the fetch that confirms a cache seed then tries the grid
    /// again instead of trusting the seed's revalidation (#1091).
    private(set) var galleryLoadFailed = false
    /// The next page(s) on their way — one round at a time.
    private var galleryMoreLoad: Task<Void, Never>?
    /// Pages walked through in a row that add nothing to the tab on screen
    /// (Short over a run of photos) before waiting for the next approach.
    static let maxUnchangedGalleryPages = 5

    /// The pages a cache seed puts back (`ProfileViewModel.seedFromCache`).
    func restore(_ pages: ProfileGalleryStore.Corpora) {
        galleryStore.restore(pages)
    }

    /// The gallery's half of a follow change (`ProfileViewerRelation.isFollowing`).
    func viewerFollowDidChange() {
        let privateToOthers = host.profile?.visibility.isPrivate == true && !host.isOwnProfile
        // Unfollowed: what the follow let in goes, and the tabs with it
        // (#1422) — a read still on its way would bring it back.
        if privateToOthers, !host.isFollowing {
            galleryLoad?.cancel()
            galleryLoad = nil
            galleryMoreLoad?.cancel()
            galleryMoreLoad = nil
            engagementTabsLoad?.cancel()
            engagementTabsLoad = nil
            galleryStore.withholdAuthored()
        }
        renderGallery()
        // Followed (a request accepted): the pages the server withheld are
        // the viewer's now, so they are read again — and the tabs come back
        // as they fill, without leaving the screen (#1422). A read already
        // on its way was asked as a stranger: it starts again.
        if privateToOthers, host.isFollowing, let profile = host.profile {
            galleryLoad?.cancel()
            galleryLoad = nil
            loadGallery(for: profile, reset: false)
        }
    }

    /// Whether a gallery row may offer Report.
    ///
    /// No seam, no row — a screen that cannot file withholds the action rather
    /// than showing one that cannot act.
    ///
    /// And never for the viewer's OWN post. A report is a complaint about
    /// someone else's content; offered on your own it reads as a bug, and it is
    /// the only row this menu has, so the whole "..." disappears with it. The
    /// Tagged tab is why this is a per-POST question rather than a per-screen
    /// one: those rows are other people's posts on your own profile.
    /// Whether a gallery post is the VIEWER's own: on their own profile, a
    /// post whose author is the profile. Anyone else's post there (the Tagged
    /// tab) is not, and neither is anything on someone else's profile.
    public func isViewerPost(by authorID: ProfileID?) -> Bool {
        guard let authorID, let profile = host.profile else { return false }
        return host.followButton == .edit && authorID == profile.id
    }

    /// Whether the viewer's own posts can be deleted here (#408).
    public var canDeletePosts: Bool { gallery is any PostTrashManaging }

    /// A delete the server accepted, told to the app (#896): its
    /// `EntityStore` drops the post from every feed and from For You.
    private let postDeleted: (@MainActor (PostID) -> Void)?

    /// Deletes one of the viewer's own posts, with Undo (#957): the tile
    /// leaves at once, and the delete is sent only when the toast's countdown
    /// runs out — a DEFERRED commit, so Undo puts the tile back where it was
    /// with nothing to take back on the server. A refused delete brings the
    /// tile back and says so. Once deleted it can be restored for 30 days
    /// from Settings → Your Activity → Recently Deleted.
    ///
    /// The app's `EntityStore` hears of it (#896) when the server ACCEPTED it
    /// — at the commit, whether or not this screen is still there — so an
    /// Undo, which sends nothing, leaves no tombstone anywhere.
    public func deletePost(_ postID: PostID) {
        guard let profile = host.profile, host.followButton == .edit, let trash = gallery as? any PostTrashManaging else { return }
        let author = profile.id
        let cache = cache
        let postDeleted = postDeleted
        galleryStore.hidePendingRemoval(postID)
        renderGallery()
        let action = UndoableAction(
            message: "Post deleted",
            symbol: AppSymbol.trashFill.rawValue,
            commit: { [weak self] in
                Task { @MainActor [weak self] in
                    do {
                        try await trash.deletePost(postID, author: author)
                        // Every other screen first: the feeds and For You
                        // drop it in the same turn as this gallery.
                        postDeleted?(postID)
                        guard let self else {
                            // The screen is gone: its kept gallery still
                            // holds the post, and the next visit would open
                            // on it — dropped, so that visit loads afresh.
                            cache?.removeGallery(for: author)
                            return
                        }
                        self.galleryStore.removeAuthoredPost(postID)
                        self.galleryStore.unhidePendingRemoval(postID)
                        // The next visit must not open on the deleted post.
                        self.rememberGallery(of: author)
                        self.renderGallery()
                    } catch {
                        guard let self else { return }
                        self.galleryStore.unhidePendingRemoval(postID)
                        self.renderGallery()
                        host.onActionResult?(.commitFailed(message: "Couldn't delete this post"))
                    }
                }
            },
            undo: { [weak self] in
                self?.galleryStore.unhidePendingRemoval(postID)
                self?.renderGallery()
            }
        )
        // No screen to offer Undo: sent now — never left hidden and unsent.
        if let onUndoable = host.onUndoable { onUndoable(action) } else { action.commit() }
    }

    /// Where the user is — set by a tab tap or a settled swipe. Pure state
    /// (pages are always computed): the view pages to it, empty messages
    /// name it, and the choice persists globally for the next profile.
    public func setGalleryFormat(_ format: GalleryFilter.Format) {
        galleryStore.filter.format = format
        galleryPreferences?.filter = galleryStore.filter
        // A tab the loaded pages leave empty fills itself as it arrives.
        fillEmptyGalleryTab()
    }

    /// The page on screen. Format pages set the format (above); the page
    /// also picks the corpus the paging, "View all" and a feed's continuation
    /// read (#696) — on your own profile too since #772. Saved and Liked read
    /// no corpus of the profile's and leave it on Posts.
    public func setActiveTab(_ tab: ProfileTab) {
        if let format = tab.format { setGalleryFormat(format) }
        let source: GalleryFilter.Source = switch tab {
        case .reposts: .reposts
        case .tagged: .tagged
        default: .posts
        }
        guard source != galleryStore.pageSource else { return }
        galleryStore.pageSource = source
        // The media "View all" shows, and an empty page fills itself.
        renderGallery()
    }

    /// The source the page on screen reads.
    ///
    /// ⚠️ EVERY PROFILE'S PAGES ARE ITS SOURCES (#696, and your own since
    /// #772): Posts (its own posts, reposts excluded), Reposts, Tagged. So it
    /// always opens on Posts. The stored filter's source — the top menu your
    /// own profile had — is read by nothing any more.
    var gallerySource: GalleryFilter.Source { galleryStore.pageSource }

    /// Fetches both corpora concurrently once the profile is known (the pager
    /// shows neighbors mid-swipe, so tagged can't be lazy). Called from the
    /// profile load path; `reset` makes pull-to-refresh refresh the grid too.
    func loadGallery(for profile: UserProfile, reset: Bool) {
        guard let gallery else { return }
        if reset {
            galleryLoad?.cancel()
            galleryLoad = nil
            galleryMoreLoad?.cancel()
            galleryMoreLoad = nil
            galleryStore.reset()
        }
        if reset {
            // Read for this viewer only (#892): never shown to the next one.
            engagementTabsLoad?.cancel()
            engagementTabsLoad = nil
            galleryStore.reactions = .empty(message: "")
            galleryStore.othersSaved = .empty(message: "")
        }
        guard galleryLoad == nil else { return }
        loadEngagementTabs(for: profile)
        galleryStore.resumePaging()
        renderGallery() // all pages report loading — or, revalidating, what they hold
        galleryLoad = Task { [weak self] in
            async let authoredFetch = gallery.authoredPage(for: profile.id, after: nil)
            async let taggedFetch = gallery.taggedPage(for: profile.id, handle: profile.handle, after: nil)

            // The two fetches fail independently: one page family degrading
            // must not blank the other. Each keeps WHY it failed (#794).
            let authored: GalleryPage?, tagged: GalleryPage?
            var authoredFailure: NetworkFailure?, taggedFailure: NetworkFailure?
            do { authored = try await authoredFetch } catch {
                authored = nil
                authoredFailure = NetworkFailure.of(error)
            }
            do { tagged = try await taggedFetch } catch {
                tagged = nil
                taggedFailure = NetworkFailure.of(error)
            }
            guard let self, !Task.isCancelled else { return }

            self.galleryStore.applyFirstPages(
                authored: authored, authoredFailure: authoredFailure,
                tagged: tagged, taggedFailure: taggedFailure
            )
            self.rememberGallery(of: profile.id)
            self.galleryLoadFailed = authoredFailure != nil || taggedFailure != nil
            self.galleryLoad = nil
            self.renderGallery()
        }
    }

    /// The gallery's Try Again (#797, #1770). After a failure, a refresh.
    /// Past "taking longer" the first pages are still out, and a refresh
    /// would wait on that same read (`loadGallery` keeps one in flight):
    /// the hung read is dropped and asked again.
    public func retryGallery() {
        // The page went back to loading on the tap (#1900): it hears an
        // answer even when it equals the one it had — a page that had
        // answered long ago was left on "taking longer", its Try Again dead.
        publishedGallery = nil
        guard let profile = host.profile, galleryLoad != nil else {
            renderGallery()
            return host.refresh()
        }
        galleryLoad?.cancel()
        galleryLoad = nil
        loadGallery(for: profile, reset: false)
    }

    /// Whether the grid's first pages are on their way, for tests.
    var isGalleryLoading: Bool { galleryLoad != nil }

    /// The Liked tab, and someone else's Saved tab (#411, #837): the
    /// server's lists, read with the grid's first pages — beside them, never
    /// a second grid load. A tab shows only once its list holds something
    /// (#742), so a hidden tab (the server answers empty) never appears; a
    /// failed read leaves what was shown.
    ///
    /// ⚠️ LIKED IS KEPT WITH THE GRID (#1776), cache first like Posts: it used
    /// to be kept nowhere, so that a viewer change could not show it to the
    /// next viewer. The device copy is the viewer's own (the LocalStore's
    /// viewer scope; `ProfileCache` drops its memory on a viewer change),
    /// so that rule holds without a cold tab at every visit. Someone else's
    /// Saved stays out of it.
    func loadEngagementTabs(for profile: UserProfile) {
        guard let gallery else { return }
        engagementTabsLoad?.cancel()
        let readsSaved = !host.isOwnProfile
        engagementTabsLoad = Task { [weak self] in
            async let liked = try? gallery.likedPosts(of: profile.id)
            async let saved = readsSaved ? try? gallery.savedPosts(of: profile.id) : nil
            let (likedPosts, savedPosts) = await (liked, saved)
            guard let self, !Task.isCancelled, host.profile?.id ?? profile.id == profile.id else { return }
            if let likedPosts {
                galleryStore.reactions = likedPosts.isEmpty ? .empty(message: "") : .content(likedPosts)
            }
            if readsSaved, let savedPosts {
                galleryStore.othersSaved = savedPosts.isEmpty ? .empty(message: "") : .content(savedPosts)
            }
            engagementTabsLoad = nil
            if likedPosts != nil { rememberGallery(of: profile.id) }
            renderGallery()
        }
    }

    /// The Liked / Saved reads on their way.
    private var engagementTabsLoad: Task<Void, Never>?

    /// The viewer neared the end of the grid on screen: the next page of
    /// every corpus its source reads, if any has one and none is on its way
    /// (#634). Appended below what is shown; a failure is retried on the next
    /// approach.
    /// The posts after `id` on the tab the viewer is on, for a full-screen
    /// feed opened from the grid (#638): what the grid holds past it, then
    /// its next pages, under the same source — the same order the grid
    /// shows, so a post the feed reaches is a tile the grid also has.
    ///
    /// `nil`: nothing follows and the corpora have no more. EMPTY: none yet
    /// (a page failed, or the first load is still out); the feed asks again
    /// on its next approach.
    ///
    /// `format` is the list the feed was opened from: Posts, or the media
    /// gallery its "View all" pushes (#631).
    public func galleryPostIDs(
        after id: PostID, in format: GalleryFilter.Format = .activity
    ) async -> [PostID]? {
        for _ in 0..<Self.maxUnchangedGalleryPages {
            let tiles = galleryStore.tiles(format)
            guard let index = tiles.firstIndex(where: { $0.id == id }) else { return nil }
            let following = tiles[(index + 1)...]
            if !following.isEmpty { return following.prefix(Self.continuationWindow).map(\.id) }
            guard !galleryStore.isComplete() else { return nil }
            if galleryMoreLoad == nil { loadMoreGallery() }
            // Not started: the first load is still out.
            guard let round = galleryMoreLoad else { return [] }
            await round.value
            if galleryStore.isPausedByFailure { return [] }
        }
        return []
    }

    /// How many posts a feed opened from the grid is handed per step.
    static let continuationWindow = 12

    public func loadMoreGallery() {
        galleryStore.resumePaging()
        startGalleryPages()
    }

    /// A tab on screen that the loaded pages leave empty has no tile to come
    /// on screen and ask for more: it asks here — unless the last round
    /// failed, which waits for the viewer.
    private func fillEmptyGalleryTab() {
        guard !galleryStore.isPausedByFailure, galleryStore.tiles(galleryFilter.format).isEmpty else { return }
        startGalleryPages()
    }

    private func startGalleryPages() {
        guard let gallery, let profile = host.profile, galleryLoad == nil, galleryMoreLoad == nil,
              !galleryStore.isComplete()
        else { return }
        galleryMoreLoad = Task { [weak self] in
            await self?.appendGalleryPages(from: gallery, for: profile)
        }
    }

    private func appendGalleryPages(from gallery: any ProfileGalleryProviding, for profile: UserProfile) async {
        let host = self.host
        for _ in 0..<Self.maxUnchangedGalleryPages {
            let tokens = galleryStore.tokensToFollow()
            guard tokens != (nil, nil) else { break }
            let before = galleryStore.tiles(galleryFilter.format).count
            async let authoredFetch = Self.page(of: tokens.authored) { token in
                try await gallery.authoredPage(for: profile.id, after: token)
            }
            async let taggedFetch = Self.page(of: tokens.tagged) { token in
                try await gallery.taggedPage(for: profile.id, handle: profile.handle, after: token)
            }
            let (authored, tagged) = await (authoredFetch, taggedFetch)
            // A reset since — another profile, a pull that started over —
            // owns the grid now, and the slot with it.
            guard !Task.isCancelled, host.profile?.id == profile.id else { return }
            let failed = galleryStore.applyNextPages(tokens: tokens, authored: authored, tagged: tagged)
            rememberGallery(of: profile.id)
            // The tab on screen gained tiles: they come on screen and ask
            // again. It gained none (Short over a run of photos): no tile will
            // ask, so the next page is asked now — within a bound.
            if failed || galleryStore.tiles(galleryFilter.format).count > before { break }
        }
        // ⚠️ THE SLOT FREES BEFORE THE TILES RENDER: a page that lands wholly
        // on screen asks for the next one while it renders (#596).
        galleryMoreLoad = nil
        renderGallery()
    }

    /// The page after `token`, or why it failed (#794: it used to be `try?`,
    /// and the failed tab could not tell offline from a refusal). Nil when
    /// there is no token to follow.
    private static func page(
        of token: String?, _ fetch: @Sendable (String) async throws -> GalleryPage
    ) async -> Result<GalleryPage, any Error>? {
        guard let token else { return nil }
        do {
            return .success(try await fetch(token))
        } catch {
            return .failure(error)
        }
    }

    /// Keeps the pages loaded so far beside the cached profile, for the next
    /// visit's first frame (#887). Every change to the corpora calls it, so
    /// the cache never holds a post this screen has already let go of.
    private func rememberGallery(of id: ProfileID) {
        // A page landing after a block is not kept: the block dropped it.
        guard let cache, !host.isBlocked, let corpora = galleryStore.corpora else { return }
        cache.store(corpora, for: id)
    }

    /// Recomputes the snapshot — Posts, Reposts, Tagged, the media of the page
    /// on screen, Saved — from the caches. Every data landing and page change
    /// funnels here.
    func renderGallery() {
        guard gallery != nil else { return }
        var snapshot = galleryStore.snapshot(isOwnProfile: host.isOwnProfile)
        // Known private and not followed: locked from the first frame
        // (#1900). While the relationship is a wait, only what came back
        // empty locks.
        if host.isPrivateToViewer {
            if host.isRelationshipSettled { snapshot.restrictWithheldPages() } else { snapshot.restrictEmptyPages() }
        }
        fillEmptyGalleryTab()
        // The same pages again is no news: a revalidation that agrees with
        // the screen must cost the screen nothing.
        guard snapshot != publishedGallery else { return }
        publishedGallery = snapshot
        host.onGalleryChange?(snapshot)
    }

    /// The pages last handed to the view — what `renderGallery` compares a
    /// new answer against.
    /// The pages last published — what a screen bound after the gallery
    /// landed renders first (#742: its tabs follow what the sources hold).
    public private(set) var publishedGallery: GallerySnapshot?
}
