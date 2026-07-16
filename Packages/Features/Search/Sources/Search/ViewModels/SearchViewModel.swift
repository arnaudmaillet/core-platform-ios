import CoreModels
import CoreNavigation
import Foundation

@MainActor
public final class SearchViewModel {
    public nonisolated enum Phase: Equatable, Sendable {
        /// No query entered — the resting state.
        case idle
        case loading
        case results([SearchResultDisplayModel])
        /// A non-empty query that matched nothing.
        case empty(query: String)
        case failed(message: String)
    }

    public var onPhaseChange: ((Phase) -> Void)?

    private let repository: any SearchProviding
    private let router: (any Router)?
    private let debounce: Duration
    private let pageSize: Int32

    private var phase: Phase = .idle {
        didSet { onPhaseChange?(phase) }
    }
    private var query = ""
    private var searchTask: Task<Void, Never>?

    public init(
        repository: any SearchProviding,
        router: (any Router)? = nil,
        debounce: Duration = .milliseconds(300),
        pageSize: Int32 = 25
    ) {
        self.repository = repository
        self.router = router
        self.debounce = debounce
        self.pageSize = pageSize
    }

    // MARK: - Inputs

    /// Called on every keystroke. Debounced, and cancels any in-flight search
    /// so results always reflect the latest query.
    public func queryChanged(_ text: String) {
        query = text
        searchTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .idle
            return
        }

        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounce)
            guard !Task.isCancelled else { return }
            await self.runSearch(trimmed)
        }
    }

    /// Result tapped — hand off to cross-feature routing. Search never imports
    /// Profile; it only emits a route. The identity slice the row already
    /// renders rides along so the profile screen composes its navigation
    /// chrome before the push animates.
    public func didSelectResult(_ id: ProfileID) {
        var stub: ProfileIdentityStub?
        if case .results(let models) = phase, let hit = models.first(where: { $0.id == id }) {
            // The display model's handle carries the "@" sigil; the stub is raw.
            stub = ProfileIdentityStub(
                handle: String(hit.handle.dropFirst(hit.handle.hasPrefix("@") ? 1 : 0)),
                displayName: hit.displayName
            )
        }
        router?.route(to: .profile(id, stub: stub))
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
                phase = .results(results.map(SearchResultDisplayModel.init))
            }
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(message: "Couldn't search. Please try again.")
        }
    }
}
