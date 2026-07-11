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
        queryTask?.cancel()
        queryTask = Task { [weak self] in
            guard let self else { return }
            let result: TileResult
            do {
                result = try await self.repository.queryTile(viewport)
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
