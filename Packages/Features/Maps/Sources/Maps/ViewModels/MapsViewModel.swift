import CoreModels
import Foundation

/// Owns the map's pin state and turns each settled viewport into the minimal
/// annotation diff the view controller applies. The view controller stays a
/// thin MapKit dispatcher: it reports viewport changes in and applies diffs out,
/// holding no query or diffing logic of its own.
///
/// Concurrency: a new viewport supersedes any in-flight query (a fast pan fires
/// several), so a slow response that lost the race is dropped rather than
/// clobbering fresher pins. Fail-open by contract — a failed query keeps the
/// current pins and never surfaces as a blocking error.
@MainActor
public final class MapsViewModel {
    private let repository: any GeoDiscoveryProviding

    /// Authoritative id → pin state; the diff is computed against this.
    private var pins: [PostID: MapPin] = [:]
    private var queryTask: Task<Void, Never>?
    /// The last settled viewport, so a filter change re-queries in place
    /// without waiting for the next pan.
    private var lastViewport: MapViewport?
    /// The active pill; `nil` is "all". Applied to every query until changed.
    public private(set) var activeFilter: MapFilter?
    /// The active refinement of `activeFilter` (a person under Friends/
    /// Following, a category under Places); cleared whenever the primary
    /// changes.
    public private(set) var activeSubFilter: MapSubFilter?

    /// The annotation mutations to apply. Emitted only when non-empty.
    public var onDiff: ((MapAnnotationDiff) -> Void)?
    /// The tile count for the last successful query — a "viewport too wide"
    /// telemetry/hint signal, not an error.
    public var onTileCount: ((Int) -> Void)?

    public init(repository: any GeoDiscoveryProviding) {
        self.repository = repository
    }

    /// The map settled on a new viewport (debounced by the caller). Cancels any
    /// in-flight query and starts a fresh one.
    public func viewportChanged(_ viewport: MapViewport) {
        lastViewport = viewport
        query(viewport)
    }

    /// The filter bar changed selection. Re-queries the current viewport under
    /// the new filter; the resulting diff removes the pins that fell out and
    /// adds the ones that qualify. Before the first settle there is no
    /// viewport yet — the pending filter still applies to the first query.
    public func filterChanged(_ filter: MapFilter?) {
        guard filter != activeFilter else { return }
        activeFilter = filter
        // A new primary invalidates any refinement of the old one.
        activeSubFilter = nil
        guard let viewport = lastViewport else { return }
        query(viewport)
    }

    /// The sub-filter bar changed selection (`nil` clears the refinement,
    /// falling back to the primary). Meaningless without a primary — ignored.
    public func subFilterChanged(_ subFilter: MapSubFilter?) {
        guard activeFilter != nil, subFilter != activeSubFilter else { return }
        activeSubFilter = subFilter
        guard let viewport = lastViewport else { return }
        query(viewport)
    }

    /// (primary, sub) resolved into the one filter that goes on the wire: a
    /// person refinement becomes `.profile` (a person's posts are already a
    /// subset of Friends/Following), a category refinement becomes
    /// `.pinnedCategory`. A sub that doesn't fit the primary is ignored
    /// (defensive — the UI never produces one).
    private var resolvedFilter: MapFilter? {
        guard let activeFilter else { return nil }
        switch (activeFilter, activeSubFilter) {
        case (.friends, .profile(let id)), (.following, .profile(let id)):
            return .profile(id)
        case (.pinned, .placeCategory(let category)):
            return .pinnedCategory(category)
        default:
            return activeFilter
        }
    }

    private func query(_ viewport: MapViewport) {
        queryTask?.cancel()
        let filter = resolvedFilter
        queryTask = Task { [weak self] in
            guard let self else { return }
            let result: TileResult
            do {
                result = try await self.repository.queryTile(viewport, filter: filter)
            } catch {
                // Fail-open (TIER-1): keep the pins we have, drop this attempt.
                return
            }
            guard !Task.isCancelled else { return }
            self.apply(result.pins)
            self.onTileCount?(result.tileCount)
        }
    }

    /// Reconciles the authoritative state with `incoming` and emits the diff.
    private func apply(_ incoming: [MapPin]) {
        let diff = MapAnnotationDiffer.diff(from: pins, to: incoming)
        guard !diff.isEmpty else { return }
        for pin in diff.removed { pins[pin.postID] = nil }
        for pin in diff.added { pins[pin.postID] = pin }
        for pin in diff.updated { pins[pin.postID] = pin }
        onDiff?(diff)
    }

    #if DEBUG
    var pinCount: Int { pins.count }
    #endif
}
