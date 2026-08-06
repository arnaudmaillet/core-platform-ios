import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import Foundation

@MainActor
public final class SearchViewModel {
    /// The screen has three resting shapes, and which one is showing is
    /// decided here rather than by the view.
    ///
    /// ⚠️ **The flow is submit-driven**, which is the thing to hold on to when
    /// reading the rest of this type. Typing narrows the *history*; it does
    /// not search. Only `submitQuery` reaches the network, and only
    /// `submitQuery` writes to the history — see its doc comment for why the
    /// two go together.
    public nonisolated enum Phase: Equatable, Sendable {
        /// The resting screen: the history, and who is worth looking at.
        case explore(ExploreDisplayModel)
        /// Typing. `rows` is the history filtered by what has been typed,
        /// followed by whatever `search.v1.Suggest` completes it to. Either
        /// half can be empty — most often both are, early in a query — and the
        /// view says so rather than showing a blank list.
        case suggesting(query: String, rows: [SearchRowDisplayModel])
        case loading
        case results([SearchResultDisplayModel])
        /// A submitted query that matched nothing.
        case empty(query: String)
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?

    /// Fires when the view model changes the query itself — tapping a recent
    /// row — so the search field can follow. Never fires for text the viewer
    /// typed; that would be the field being told what it just said.
    public var onQueryTextChange: ((String) -> Void)?

    private let repository: any SearchProviding
    private let router: (any Router)?
    private let recentSearches: RecentSearchStore?
    private let explore: (any ExploreProviding)?
    private let metadata: (any ProfileMetadataProviding)?
    private let pageSize: Int32
    private let trendingLimit: Int
    private let creatorLimit: Int
    private let suggestLimit: Int32
    private let suggestDebounce: Duration

    private var phase: Phase = .explore(ExploreDisplayModel(recents: [], hiddenRecentCount: 0)) {
        didSet { onPhaseChange?(phase) }
    }
    private var query = ""
    /// Whether the Recent section is showing everything or just the first
    /// window of it. Sticky for the life of the screen: a viewer who expanded
    /// the list has said they want the long version, and collapsing it again
    /// behind their back on the next keystroke would undo that.
    private var recentsExpanded = false
    private var searchTask: Task<Void, Never>?

    /// The trending section, held across phase changes.
    ///
    /// Fetched once per screen rather than on every return to explore: the
    /// corpus does not change between a viewer typing and clearing the field,
    /// and re-fetching would restart the rows' avatar loads and flash the
    /// skeleton back over people they were already looking at.
    private var trending: TrendingState
    private var trendingTask: Task<Void, Never>?

    /// The completions last fetched, and what they were for.
    ///
    /// Held so a history edit mid-typing can re-render the local half without
    /// throwing away the remote half — and so a keystroke that narrows a
    /// query does not blank the list while the next fetch is in flight.
    private var cachedSuggestions: (query: String, rows: [SearchRowDisplayModel])?
    private var suggestTask: Task<Void, Never>?

    /// Pictures resolved this session, overlaid onto every list that shows the
    /// person — so someone seen once in Suggestions is already complete when
    /// they turn up in the history or in a result.
    private var resolvedMetadata: [ProfileID: ProfileRowMetadata] = [:]
    private var metadataTask: Task<Void, Never>?

    public init(
        repository: any SearchProviding,
        router: (any Router)? = nil,
        recentSearches: RecentSearchStore? = nil,
        explore: (any ExploreProviding)? = nil,
        metadata: (any ProfileMetadataProviding)? = nil,
        pageSize: Int32 = 25,
        trendingLimit: Int = 30,
        creatorLimit: Int = 12,
        suggestLimit: Int32 = 8,
        suggestDebounce: Duration = .milliseconds(200)
    ) {
        self.repository = repository
        self.router = router
        self.recentSearches = recentSearches
        self.explore = explore
        self.metadata = metadata
        self.pageSize = pageSize
        self.trendingLimit = trendingLimit
        self.creatorLimit = creatorLimit
        self.suggestLimit = suggestLimit
        self.suggestDebounce = suggestDebounce
        trending = explore == nil ? .unavailable : .loading
    }

    // MARK: - Inputs

    /// Re-reads the history and shows the resting screen. Called when the
    /// screen appears, and whenever the field is emptied.
    public func showExplore() {
        searchTask?.cancel()
        let model = exploreModel()
        phase = .explore(model)
        loadTrendingIfNeeded()
        // Both lists on this screen, in one pass — the cache makes a person
        // seen in Suggestions free when they turn up in the history too.
        resolveAvatars(for: peopleNeedingAvatars(in: model.recents)
            + model.trending.creators.filter { resolvedMetadata[$0.id] == nil }.map(\.id))
    }

    /// Called on every keystroke.
    ///
    /// Narrows the history immediately, then asks `search.v1.Suggest` for
    /// completions. **It still does not search** — `Suggest` answers with text
    /// to finish typing, not with people, and the results page is still
    /// something the viewer has to ask for.
    ///
    /// The local half lands synchronously and the remote half arrives after a
    /// debounce, in that order, because the history is free and the network is
    /// not: a list that waited for the round trip would show nothing for the
    /// first 200ms of every query it could already have answered.
    public func queryChanged(_ text: String) {
        query = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return showExplore() }

        searchTask?.cancel()
        suggestTask?.cancel()
        let rows = suggestionRows(for: trimmed)
        phase = .suggesting(query: trimmed, rows: rows)
        resolveAvatars(for: peopleNeedingAvatars(in: rows))

        suggestTask = Task { [weak self] in
            guard let self else { return }
            // Debounced, so a fast typist spends one round trip rather than
            // one per letter.
            try? await Task.sleep(for: self.suggestDebounce)
            guard !Task.isCancelled else { return }
            await self.loadSuggestions(for: trimmed)
        }
    }

    /// The viewer pressed Search — the one input that searches, and the one
    /// that writes to the history.
    ///
    /// **The two are the same event on purpose.** Submission is what makes a
    /// search a *recent* search: recording as the viewer typed would leave
    /// "g", "gr", "gra" and "grac" behind every search for "grace" — four rows
    /// nobody searched for, each one a thing to delete.
    public func submitQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        query = trimmed
        recentSearches?.recordQuery(trimmed)

        searchTask?.cancel()
        searchTask = Task { [weak self] in
            await self?.runSearch(trimmed)
        }
    }

    /// A text row was tapped — a remembered search, a remembered person, or a
    /// live completion.
    ///
    /// **A row that names a PERSON opens that person, in one tap.** It used to
    /// run their name as a search, which landed on a results list where the
    /// viewer had to tap the same person a second time; the row already knows
    /// the id, so the search was a detour through a screen nobody asked for.
    /// Rows that name a *query* still search — see `SearchRowDisplayModel.Action`.
    ///
    /// Read from the phase rather than the store, because a completion is not
    /// in the store — the rows on screen are the only place all three kinds
    /// exist together.
    public func didSelectRow(_ id: String) {
        let row: SearchRowDisplayModel? = switch phase {
        case .explore(let model): model.recents.first { $0.id == id }
        case .suggesting(_, let rows): rows.first { $0.id == id }
        case .loading, .results, .empty, .failed: nil
        }
        guard let row else { return }

        switch row.action {
        case .search:
            // The field has to follow, or the screen would show results for a
            // query the search bar is not displaying.
            onQueryTextChange?(row.text)
            submitQuery(row.text)
        case .openProfile(let profileID, let handle, let displayName, let avatarURL):
            openProfile(
                id: profileID, handle: handle, displayName: displayName,
                // Whatever the row was drawn with, plus anything resolved
                // since — so the history keeps the picture rather than
                // re-recording the person with less than is known.
                avatarURL: avatarURL ?? resolvedMetadata[profileID]?.avatarURL
            )
        }
    }

    /// Opens a person and remembers that it happened.
    ///
    /// **Recording is what keeps the history honest now that tapping a person
    /// no longer runs a search.** The search used to be the thing that got
    /// written down; without this, opening someone from Suggestions would
    /// leave no trace and the Recent list would only ever know about typed
    /// queries.
    private func openProfile(
        id: ProfileID, handle: String, displayName: String?, avatarURL: URL? = nil
    ) {
        recentSearches?.recordProfile(
            id: id.rawValue, displayName: displayName ?? handle, handle: handle,
            avatarURL: avatarURL?.absoluteString
        )
        // Only a name we actually have becomes a stub — see
        // `SearchRowDisplayModel.Action.openProfile`.
        let stub = displayName.map { ProfileIdentityStub(handle: handle, displayName: $0) }
        router?.route(to: .profile(id, stub: stub))
        // The resting screen is what they come back to, and it now has one
        // more row in it.
        refreshRecentsIfShowing()
    }

    /// The ✕ on a remembered row.
    public func didDeleteRecent(_ id: RecentSearch.ID) {
        recentSearches?.remove(id: id)
        refreshRecentsIfShowing()
    }

    /// "Clear all" in the section header.
    public func didClearRecents() {
        recentSearches?.clear()
        // Nothing is being held back from an empty history, so the expansion
        // is meaningless now and would otherwise silently apply to whatever
        // the viewer searches next.
        recentsExpanded = false
        refreshRecentsIfShowing()
    }

    /// The "See more" row. One-way: the list has no second page, because the
    /// store's own cap is what bounds it.
    public func didRequestMoreRecents() {
        recentsExpanded = true
        refreshRecentsIfShowing()
    }

    /// Result tapped — hand off to cross-feature routing. Search never imports
    /// Profile; it only emits a route. The identity slice the row already
    /// renders rides along so the profile screen composes its navigation
    /// chrome before the push animates.
    public func didSelectResult(_ id: ProfileID) {
        guard case .results(let models) = phase, let hit = models.first(where: { $0.id == id }) else {
            return router?.route(to: .profile(id, stub: nil)) ?? ()
        }
        // The display model's handle carries the "@" sigil; the stub is raw.
        openProfile(
            id: id,
            handle: String(hit.handle.dropFirst(hit.handle.hasPrefix("@") ? 1 : 0)),
            displayName: hit.displayName,
            avatarURL: hit.avatarURL ?? resolvedMetadata[id]?.avatarURL
        )
    }

    // MARK: - Recents

    private func exploreModel() -> ExploreDisplayModel {
        let model = ExploreDisplayModel(
            window: RecentSearchStore.window(
                over: recentSearches?.recents ?? [],
                expanded: recentsExpanded
            ),
            trending: trending
        )
        return ExploreDisplayModel(
            recents: withResolvedAvatars(model.recents),
            hiddenRecentCount: model.hiddenRecentCount,
            trending: withResolvedContext(model.trending)
        )
    }

    // MARK: - Avatars

    /// Fills in pictures already known for the people in `rows`.
    ///
    /// A persisted URL wins over a resolved one — it is what the row was
    /// recorded with, and re-resolving is for filling gaps and replacing links
    /// that have gone stale, not for overruling.
    private func withResolvedAvatars(_ rows: [SearchRowDisplayModel]) -> [SearchRowDisplayModel] {
        rows.map { row in
            guard case .openProfile(let id, _, _, _) = row.action else { return row }
            guard let known = resolvedMetadata[id] else { return row }
            var filled = row
            if filled.avatarURL == nil { filled.avatarURL = known.avatarURL }
            filled.context = Self.context(for: known)
            return filled
        }
    }

    /// Fills the Suggestions rows in from what came back about those people.
    private func withResolvedContext(_ state: TrendingState) -> TrendingState {
        guard case .loaded(let creators) = state else { return state }
        return .loaded(creators: creators.map { creator in
            guard let known = resolvedMetadata[creator.id] else { return creator }
            var filled = creator
            filled.context = Self.context(for: known)
            return filled
        })
    }

    /// What a row says about a person, from what came back about them.
    ///
    /// **Following wins over the count.** "You already follow them" is the
    /// more actionable of the two — it is the difference between a stranger
    /// and someone the viewer knows — and showing both would put two competing
    /// labels at the end of one row.
    private static func context(for metadata: ProfileRowMetadata) -> ProfileRowContext {
        if metadata.isFollowed { return .following }
        if let followers = metadata.followerCount { return .followerCount(followers) }
        return .none
    }

    /// The people on screen who still have no picture.
    private func peopleNeedingAvatars(in rows: [SearchRowDisplayModel]) -> [ProfileID] {
        rows.compactMap { row in
            guard case .openProfile(let id, _, _, _) = row.action else { return nil }
            return resolvedMetadata[id] == nil ? id : nil
        }
    }

    /// Resolves the pictures for `ids` and re-renders whatever is showing.
    ///
    /// ⚠️ **Only for what is on screen.** This is an N+1 read — `profile.v1`
    /// has no batch — so the input is always the visible rows and never a
    /// speculative prefetch. `ProfileAvatarRepository` then makes the second
    /// sighting of the same person free.
    private func resolveAvatars(for ids: [ProfileID]) {
        guard let metadata, !ids.isEmpty else { return }
        metadataTask?.cancel()
        metadataTask = Task { [weak self] in
            let found = await metadata.metadata(for: ids)
            guard let self, !Task.isCancelled, !found.isEmpty else { return }
            self.resolvedMetadata.merge(found) { current, _ in current }
            self.rerenderWithAvatars()
        }
    }

    /// Fills a result row in from whatever came back about that person.
    private func withResolvedMetadata(_ model: SearchResultDisplayModel) -> SearchResultDisplayModel {
        guard let known = resolvedMetadata[model.id] else { return model }
        var filled = model
        if filled.avatarURL == nil { filled.avatarURL = known.avatarURL }
        filled.context = Self.context(for: known)
        return filled
    }

    /// Re-emits the current phase with the pictures that just landed. Only the
    /// phase that is actually showing — a resolution arriving after the viewer
    /// has moved on must not drag them back.
    private func rerenderWithAvatars() {
        switch phase {
        case .explore:
            phase = .explore(exploreModel())
        case .suggesting(let query, let rows):
            phase = .suggesting(query: query, rows: withResolvedAvatars(rows))
        case .results(let models):
            phase = .results(models.map(withResolvedMetadata))
        case .loading, .empty, .failed:
            break
        }
    }

    // MARK: - Trending

    /// A creator row was tapped. The identity the card already renders rides
    /// along, so the profile screen composes its chrome before the push.
    public func didSelectCreator(_ id: ProfileID) {
        guard let creator = trending.creators.first(where: { $0.id == id }) else {
            // Nothing on screen describes them, so there is nothing to
            // remember — but the tap still has to go somewhere.
            router?.route(to: .profile(id, stub: nil))
            return
        }
        openProfile(
            id: id, handle: creator.handle,
            displayName: creator.displayName, avatarURL: creator.avatarURL
        )
    }

    /// Fetches the corpus once. Subsequent calls are no-ops while a fetch is
    /// in flight or once one has landed — see `trending`.
    private func loadTrendingIfNeeded() {
        guard let explore, trendingTask == nil, trending.isLoading else { return }
        trendingTask = Task { [weak self] in
            guard let self else { return }
            let limit = self.trendingLimit
            do {
                let ranked = ExploreRanking.ranked(try await explore.corpus(limit: limit))
                guard !Task.isCancelled else { return }
                self.trending = .loaded(
                    creators: ExploreRanking.creators(from: ranked, limit: self.creatorLimit)
                )
            } catch {
                guard !Task.isCancelled else { return }
                // The section disappears; the history does not. A screen whose
                // main job still works should not wear someone else's error.
                self.trending = .failed
            }
            // Only if the resting screen is still what is showing. A fetch
            // that lands while the viewer is reading results must not throw
            // them back to explore.
            if case .explore = self.phase {
                let model = self.exploreModel()
                self.phase = .explore(model)
                // The corpus just named people nothing is known about yet.
                self.resolveAvatars(
                    for: model.trending.creators.filter { self.resolvedMetadata[$0.id] == nil }.map(\.id)
                )
            }
        }
    }

    /// How many history matches the typeahead shows above the completions.
    ///
    /// Its OWN number rather than the Recent section's `collapsedLimit`: that
    /// one governs a section the viewer came to read, and it is now ten. Ten
    /// history rows plus eight completions is a screenful of list for a
    /// half-typed word, and the completions — the half that actually answers
    /// what is being typed — would start below the fold.
    private static let historyMatchLimit = 5

    private func matchingRecents(for trimmed: String) -> [SearchRowDisplayModel] {
        (recentSearches?.recents ?? [])
            .filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
            .prefix(Self.historyMatchLimit)
            .map(SearchRowDisplayModel.init)
    }

    // MARK: - Suggestions

    /// The typeahead list: history matches first, then completions that are
    /// not already among them.
    ///
    /// **History first, always.** A row the viewer has searched before is a
    /// better bet than one the index merely completes to, and it is also the
    /// only one they can delete — putting them in one run keeps the ✕ column
    /// from appearing partway down the list.
    ///
    /// Cached completions are used only while they still belong to this query,
    /// so narrowing "sof" to "sofi" shows the local half immediately and the
    /// stale remote half not at all.
    private func suggestionRows(for trimmed: String) -> [SearchRowDisplayModel] {
        let history = matchingRecents(for: trimmed)
        guard let cached = cachedSuggestions, cached.query == trimmed else {
            return withResolvedAvatars(history)
        }
        var seen = Set(history.map(\.id))
        return withResolvedAvatars(history + cached.rows.filter { seen.insert($0.id).inserted })
    }

    /// Fetches completions and folds them in.
    ///
    /// ⚠️ **A failed suggest is silent.** The viewer is mid-word; the local
    /// matches are already on screen, and an error message under a half-typed
    /// query would be the screen complaining about something nobody asked it
    /// to do. It also fails routinely by design — `Suggest` may be unrouted on
    /// a given backend (the mock only grew it in Phase 4), and the screen has
    /// to stay usable when it is.
    private func loadSuggestions(for trimmed: String) async {
        guard let remote = try? await repository.suggestions(forPrefix: trimmed, limit: suggestLimit)
        else { return }
        // A late answer for a superseded query must not overwrite newer state.
        guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        else { return }
        cachedSuggestions = (trimmed, remote.map(SearchRowDisplayModel.init))
        // Only if typing is still what is showing. Completions that land after
        // the viewer has pressed Search must not replace their results.
        guard case .suggesting = phase else { return }
        let rows = suggestionRows(for: trimmed)
        phase = .suggesting(query: trimmed, rows: rows)
        // The completions that just landed are people this has never seen.
        resolveAvatars(for: peopleNeedingAvatars(in: rows))
    }

    /// Re-renders whichever of the two history-bearing phases is showing, and
    /// leaves the others alone.
    ///
    /// ⚠️ Deleting a row while a *results* page is up must not throw the
    /// viewer back to the history — the swipe happens on the suggestions list
    /// on the way to a search, and the results that arrive after it are what
    /// they asked for.
    private func refreshRecentsIfShowing() {
        switch phase {
        case .explore:
            phase = .explore(exploreModel())
        case .suggesting(let query, _):
            phase = .suggesting(query: query, rows: suggestionRows(for: query))
        case .loading, .results, .empty, .failed:
            break
        }
    }

    // MARK: - Search

    private func runSearch(_ trimmed: String) async {
        phase = .loading
        do {
            let results = try await repository.searchProfiles(matching: trimmed, limit: pageSize)
            // A late response for a superseded query must not overwrite newer state.
            guard !Task.isCancelled, query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
            if results.isEmpty {
                phase = .empty(query: trimmed)
            } else {
                // `search.v1` gives a storage key, never a URL, and says
                // nothing about the viewer's relationship — so a result starts
                // bare and is completed by `ProfileMetadataProviding`.
                let models = results.map { withResolvedMetadata(SearchResultDisplayModel(result: $0)) }
                phase = .results(models)
                resolveAvatars(for: models.filter { resolvedMetadata[$0.id] == nil }.map(\.id))
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(message: "Couldn't search. Please try again.")
        }
    }
}
