import CoreModels
import CoreStorage
import Foundation
import ProfileData

/// What Saved and History ask of their view model (#2522): the gallery's
/// store, where they write their pages, and its render.
@MainActor
protocol ProfileViewerPilesHost: AnyObject {
    var galleryStore: ProfileGalleryStore { get }
    func renderGallery()
}

/// The viewer's piles, out of `ProfileViewModel` (#2522): the Saved page
/// from the bookmarks and the server's list, and History from the device's
/// views, held still while the viewer is on it. They are the only writers
/// of the store's `saved` and `history…` pages.
@MainActor
final class ProfileViewerPiles {
    private unowned let host: any ProfileViewerPilesHost
    private let gallery: (any ProfileGalleryProviding)?
    private let bookmarks: PostBookmarkStore?
    private let viewHistory: PostViewHistoryStore?

    init(
        host: any ProfileViewerPilesHost,
        gallery: (any ProfileGalleryProviding)?,
        bookmarks: PostBookmarkStore?,
        viewHistory: PostViewHistoryStore?
    ) {
        self.host = host
        self.gallery = gallery
        self.bookmarks = bookmarks
        self.viewHistory = viewHistory
        // A new viewer's pile (the active profile resolving after the first
        // read, a profile switch): History shows it now, holding nothing of
        // the last one's.
        viewerObservation = viewHistory?.viewerChanges.observeOnMain { [weak self] in
            self?.refreshHistory()
        }
    }

    /// Ends with this object (`StoreObservation`).
    private var viewerObservation: StoreObservation?

    /// Rebuilds the Saved page from the pile the viewer has curated, then
    /// from the server's list (#837) when it brings anything new.
    ///
    /// ⚠️ Reads the ids EVERY time rather than caching them. The pile is
    /// mutable from outside this screen — the feed's bookmark button writes to
    /// the same store — so the ids are the store's answer at the moment of
    /// asking, not a copy taken when the profile opened.
    ///
    /// The pile shows first: it is what the device knew, offline included.
    /// The server's list replaces it once read (`PostSaveSyncing`), which is
    /// how saves made on another device arrive — and how a new device, whose
    /// pile is empty, shows anything at all.
    ///
    /// A post that no longer resolves simply drops out, the same way a tile
    /// that fails to hydrate does everywhere else: the list can outlive what
    /// it points at.
    func loadSavedPosts() {
        guard let bookmarks, gallery != nil else { return }
        let sync = bookmarks.sync.flatMap { $0.readsServer ? $0 : nil }
        showSavedPosts(bookmarks.savedPostIDs, awaitingServer: sync != nil)
        guard let sync else { return }
        savedRefresh?.cancel()
        savedRefresh = Task { [weak self] in
            await sync.refreshFromServer()
            guard let self, !Task.isCancelled else { return }
            let fresh = bookmarks.savedPostIDs
            // The same list again costs the page nothing.
            if fresh != shownSavedIDs || isAwaitingSavedList {
                showSavedPosts(fresh, awaitingServer: false)
            }
        }
    }

    /// The ids the Saved page last asked to show.
    private var shownSavedIDs: [String]?
    /// Whether the page shows bones until the server's list arrives: an
    /// empty pile on a device that has not heard the list yet.
    private var isAwaitingSavedList = false
    /// The server's list on its way (`loadSavedPosts`).
    private var savedRefresh: Task<Void, Never>?
    /// Bumped by every `showSavedPosts`: a hydration that lands after a newer
    /// one started is dropped.
    private var savedGeneration = 0

    private func showSavedPosts(_ ids: [String], awaitingServer: Bool) {
        guard let gallery else { return }
        shownSavedIDs = ids
        savedGeneration += 1
        let generation = savedGeneration
        guard !ids.isEmpty else {
            // Nothing on the device yet may be everything on the server: the
            // page waits for it rather than saying "nothing saved" first —
            // bones, or the tiles it already shows (never bones over tiles,
            // see below), until the list answers.
            isAwaitingSavedList = awaitingServer
            if !awaitingServer {
                host.galleryStore.saved = .empty(message: "")
            } else if case .content = host.galleryStore.saved {
                return
            } else {
                host.galleryStore.saved = .loading
            }
            host.renderGallery()
            return
        }
        isAwaitingSavedList = false
        // ⚠️ SKELETONS ONLY FOR A PAGE WITH NOTHING TO SHOW. This runs on
        // every appearance, including the one a closing post delivers, and a
        // `.loading` over shown tiles reloaded the grid as bones mid-dismissal:
        // the card had no tile to land on and collapsed to the fallback rect.
        // A page already showing its tiles keeps them while the refresh runs.
        if case .content = host.galleryStore.saved {} else {
            host.galleryStore.saved = .loading
            host.renderGallery()
        }
        Task { [weak self] in
            let tiles = (try? await gallery.posts(ids: ids)) ?? []
            guard let self, generation == savedGeneration else { return }
            host.galleryStore.saved = tiles.isEmpty
                ? .empty(message: "Nothing saved yet.")
                : .content(tiles)
            host.renderGallery()
        }
    }

    // MARK: - History (#1344)

    /// The History page from the device's pile, newest first — on every
    /// appearance and on every change. Like Saved: a post that no longer
    /// resolves drops out, and a page already showing tiles keeps them while
    /// the refresh runs.
    func loadHistory() {
        guard let viewHistory, let gallery else { return }
        // Undated views (recorded before the times were kept) last, under
        // "Earlier". While History is held (`holdHistory`), the pile it
        // showed, less what has left the store since.
        let pile = Self.heldOrLive(held: heldHistory, live: viewHistory.views)
        let views = pile.filter { $0.viewedAt != nil } + pile.filter { $0.viewedAt == nil }
        let ids = views.map(\.postID)
        // The day is part of what is shown: "Today" is yesterday's by now.
        let shown = HistoryShown(views: views, day: Calendar.current.startOfDay(for: now()))
        guard shown != shownHistory || !hasShownHistory else { return }
        shownHistory = shown
        historyGeneration += 1
        let generation = historyGeneration
        guard !ids.isEmpty else {
            hasShownHistory = true
            host.galleryStore.history = .empty(message: "")
            host.galleryStore.historyGroups = []
            host.galleryStore.historyViewedAt = [:]
            host.renderGallery()
            return
        }
        if case .content = host.galleryStore.history {} else {
            host.galleryStore.history = .loading
            host.renderGallery()
        }
        Task { [weak self] in
            let tiles = (try? await gallery.posts(ids: ids)) ?? []
            guard let self, generation == historyGeneration else { return }
            hasShownHistory = true
            let viewedAt = Dictionary(views.map { ($0.postID, $0.viewedAt) }, uniquingKeysWith: { first, _ in first })
            host.galleryStore.history = tiles.isEmpty ? .empty(message: "") : .content(tiles)
            host.galleryStore.historyGroups = HistoryDayGroups.groups(
                for: tiles.map { viewedAt[$0.id.rawValue] ?? nil }, now: now()
            )
            host.galleryStore.historyViewedAt = tiles.reduce(into: [:]) { dates, tile in
                if let date = viewedAt[tile.id.rawValue] ?? nil { dates[tile.id] = date }
            }
            host.renderGallery()
        }
    }

    /// ⚠️ **HISTORY HOLDS STILL WHILE THE VIEWER IS ON IT** (the owner,
    /// 2026-11-07). A post opened from History, and every post paged to
    /// after it, is recorded at once (`PostViewHistoryStore`), but the page
    /// keeps the posts it showed, in their order and with their times, until
    /// the viewer leaves the History page or the profile (`releaseHistory`):
    /// closing the post lands on the row it left, which has not moved to the
    /// top. A removal (the menu, VoiceOver, Clear History) still applies.
    private var heldHistory: [PostViewHistoryStore.View]?

    /// Whether History is held now.
    var holdsHistory: Bool { heldHistory != nil }

    /// Holds History as it is shown — the viewer opened a post from it.
    func holdHistory() {
        guard heldHistory == nil, let viewHistory else { return }
        heldHistory = shownHistory?.views ?? viewHistory.views
    }

    /// The viewer left the History page: it takes in every view since.
    func releaseHistory() {
        guard heldHistory != nil else { return }
        heldHistory = nil
        loadHistory()
    }

    /// A pull on the profile (the owner, 2026-11-07): History takes in
    /// every view since, held or not.
    func refreshHistory() {
        heldHistory = nil
        loadHistory()
    }

    /// The pile History shows: `live`, or `held` less what left `live`.
    static func heldOrLive(
        held: [PostViewHistoryStore.View]?, live: [PostViewHistoryStore.View]
    ) -> [PostViewHistoryStore.View] {
        guard let held else { return live }
        let kept = Set(live.map(\.postID))
        return held.filter { kept.contains($0.postID) }
    }

    /// Takes one post out of the history (its menu's "Remove from History").
    func removeFromHistory(_ id: PostID) {
        removeFromHistory([id])
    }

    /// Takes several posts out of the history at once — the History page's
    /// select mode (the owner, 2026-11-08): one reload, one animation.
    func removeFromHistory(_ ids: [PostID]) {
        guard !ids.isEmpty else { return }
        for id in ids { viewHistory?.remove(id.rawValue) }
        loadHistory()
    }

    /// Empties the history (the profile menu's "Clear History").
    func clearHistory() {
        viewHistory?.clear()
        loadHistory()
    }

    /// Whether there is any history to clear.
    var hasHistory: Bool { !(viewHistory?.postIDs.isEmpty ?? true) }

    /// The clock History's days are read against. Tests set it.
    var now: @Sendable () -> Date = Date.init

    /// What the History page was last built from.
    private struct HistoryShown: Equatable {
        var views: [PostViewHistoryStore.View]
        var day: Date
    }
    private var shownHistory: HistoryShown?
    private var hasShownHistory = false
    private var historyGeneration = 0
}
