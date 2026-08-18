import CoreModels
import Foundation
import Testing
@testable import Maps

/// The Places row's "Favorites" refinement: client-side (the followed set
/// lives on the device), applied by the view model to the RESPONSE — only
/// pins whose place ladder holds a followed place survive — while the wire
/// sees the bare primary.
@MainActor
struct MapFollowedPlacesFilterTests {
    private static let paris = MapViewport.make(
        centerLat: 48.8566, centerLng: 2.3522, latitudeSpan: 0.09, longitudeSpan: 0.09
    )

    private let parisPlace = MapPlace(id: "city:paris", name: "Paris", kind: .city)
    private let lyonPlace = MapPlace(id: "city:lyon", name: "Lyon", kind: .city)

    private func pin(_ id: String, places: [MapPlace] = []) -> MapPin {
        MapPin(postID: PostID(id), latitude: 48.85, longitude: 2.35,
               thumbnailURL: nil, kind: .text, places: places)
    }

    private func makePins() -> [MapPin] {
        [
            pin("post-paris", places: [parisPlace]),
            pin("post-lyon", places: [lyonPlace]),
            pin("post-untagged"),
        ]
    }

    /// Activating the refinement narrows the map to followed places' posts;
    /// the wire filter stays the bare primary (`.followedPlaces` never
    /// resolves into the header).
    @Test func theFavoritesRefinementShowsOnlyFollowedPlaces() async {
        let provider = PinServingFakeProvider(pins: makePins())
        let viewModel = MapsViewModel(
            repository: provider,
            followedPlaceIDs: { ["city:paris"] }
        )
        var shown: Set<PostID> = []
        viewModel.onDiff = { diff in
            for pin in diff.added { shown.insert(pin.postID) }
            for pin in diff.removed { shown.remove(pin.postID) }
        }

        viewModel.viewportChanged(Self.paris)
        viewModel.filterChanged(.pinned)
        await waitUntil { provider.calls.count == 2 }
        await waitUntil { shown.count == 3 }
        #expect(shown == [PostID("post-paris"), PostID("post-lyon"), PostID("post-untagged")])

        viewModel.subFiltersChanged([.followedPlaces])
        await waitUntil { provider.calls.count == 3 }
        await waitUntil { shown.count == 1 }
        #expect(shown == [PostID("post-paris")], "only the followed place's post survives")
        #expect(provider.calls.last?.filter == .pinned, "the refinement never rides the wire")
    }

    /// A follow-set change re-applies an ACTIVE refinement (the gallery
    /// toggle writes while the map sits beneath the Case-B stack) — and is
    /// ignored while the refinement is off, where nothing reads the set.
    @Test func aFollowChangeReappliesOnlyAnActiveRefinement() async {
        let followed = SendableBox<Set<String>>(["city:paris"])
        let provider = PinServingFakeProvider(pins: makePins())
        let viewModel = MapsViewModel(
            repository: provider,
            followedPlaceIDs: { followed.value }
        )
        var shown: Set<PostID> = []
        viewModel.onDiff = { diff in
            for pin in diff.added { shown.insert(pin.postID) }
            for pin in diff.removed { shown.remove(pin.postID) }
        }
        viewModel.viewportChanged(Self.paris)
        viewModel.filterChanged(.pinned)
        viewModel.subFiltersChanged([.followedPlaces])
        await waitUntil { provider.calls.count == 3 }
        await waitUntil { shown == [PostID("post-paris")] }

        // The viewer follows Lyon too, from the gallery header.
        followed.value = ["city:paris", "city:lyon"]
        viewModel.followedPlacesChanged()
        await waitUntil { provider.calls.count == 4 }
        await waitUntil { shown.count == 2 }
        #expect(shown == [PostID("post-paris"), PostID("post-lyon")])

        // Refinement off: the same signal has nothing to re-apply.
        viewModel.subFiltersChanged([])
        await waitUntil { provider.calls.count == 5 }
        viewModel.followedPlacesChanged()
        #expect(provider.calls.count == 5)
    }

    /// Bounded yield-polling: the fake answers synchronously, so the query
    /// task only needs scheduler turns, never wall-clock time.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }
}

/// A box the test mutates across the `@Sendable` provider closure boundary.
private final class SendableBox<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}

private final class PinServingFakeProvider: GeoDiscoveryProviding, @unchecked Sendable {
    struct Call: Equatable {
        let viewport: MapViewport
        let filter: MapFilter?
    }

    private let pins: [MapPin]
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }

    init(pins: [MapPin]) {
        self.pins = pins
    }

    func queryTile(_ viewport: MapViewport, filter: MapFilter?) async throws -> TileResult {
        lock.withLock { _calls.append(Call(viewport: viewport, filter: filter)) }
        return TileResult(pins: pins, tileCount: 1)
    }
}
