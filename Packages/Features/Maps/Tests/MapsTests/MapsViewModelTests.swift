import CoreModels
import Foundation
import Testing
@testable import Maps

/// The filter/viewport query choreography: which (viewport, filter) pairs the
/// view model asks the repository for, as pills and pans interleave.
@MainActor
struct MapsViewModelTests {
    private static let paris = MapViewport.make(
        centerLat: 48.8566, centerLng: 2.3522, latitudeSpan: 0.09, longitudeSpan: 0.09
    )

    @Test func viewportChangeQueriesUnfiltered() async {
        let provider = FakeGeoProvider()
        let viewModel = MapsViewModel(repository: provider)

        viewModel.viewportChanged(Self.paris)
        await waitUntil { provider.calls.count == 1 }

        #expect(provider.calls == [.init(viewport: Self.paris, filter: nil)])
    }

    @Test func filterChangeRequeriesTheLastViewport() async {
        let provider = FakeGeoProvider()
        let viewModel = MapsViewModel(repository: provider)
        viewModel.viewportChanged(Self.paris)
        await waitUntil { provider.calls.count == 1 }

        viewModel.filterChanged(.friends)
        await waitUntil { provider.calls.count == 2 }

        #expect(provider.calls.last == .init(viewport: Self.paris, filter: .friends))
    }

    @Test func filterBeforeFirstSettleAppliesToTheFirstQuery() async {
        // Selecting a pill before the map's first settle must not fire a
        // viewport-less query — but the choice sticks to the query that the
        // settle then runs.
        let provider = FakeGeoProvider()
        let viewModel = MapsViewModel(repository: provider)

        viewModel.filterChanged(.pinned)
        #expect(provider.calls.isEmpty)

        viewModel.viewportChanged(Self.paris)
        await waitUntil { provider.calls.count == 1 }
        #expect(provider.calls == [.init(viewport: Self.paris, filter: .pinned)])
    }

    @Test func reselectingTheActiveFilterIsANoOp() async {
        let provider = FakeGeoProvider()
        let viewModel = MapsViewModel(repository: provider)
        viewModel.viewportChanged(Self.paris)
        viewModel.filterChanged(.nearby)
        await waitUntil { provider.calls.count == 2 }

        // Same value again: the guard returns before any task is spawned.
        viewModel.filterChanged(.nearby)

        #expect(provider.calls.count == 2)
        #expect(viewModel.activeFilter == .nearby)
    }

    @Test func subFilterResolvesIntoTheEffectiveWireFilter() async {
        // friends + person → .profile (a person's posts are a subset of
        // friends'); pinned + category → .pinnedCategory.
        let provider = FakeGeoProvider()
        let viewModel = MapsViewModel(repository: provider)
        viewModel.viewportChanged(Self.paris)
        viewModel.filterChanged(.friends)
        await waitUntil { provider.calls.count == 2 }

        viewModel.subFilterChanged(.profile(ProfileID("prof-0")))
        await waitUntil { provider.calls.count == 3 }
        #expect(provider.calls.last == .init(viewport: Self.paris, filter: .profile(ProfileID("prof-0"))))

        viewModel.filterChanged(.pinned)
        await waitUntil { provider.calls.count == 4 }
        viewModel.subFilterChanged(.placeCategory("cafes"))
        await waitUntil { provider.calls.count == 5 }
        #expect(provider.calls.last == .init(viewport: Self.paris, filter: .pinnedCategory("cafes")))
    }

    @Test func changingThePrimaryClearsTheSubFilter() async {
        let provider = FakeGeoProvider()
        let viewModel = MapsViewModel(repository: provider)
        viewModel.viewportChanged(Self.paris)
        viewModel.filterChanged(.friends)
        viewModel.subFilterChanged(.profile(ProfileID("prof-0")))
        await waitUntil { provider.calls.count == 3 }

        viewModel.filterChanged(.following)
        await waitUntil { provider.calls.count == 4 }

        // The refinement of the old primary must not leak into the new one.
        #expect(viewModel.activeSubFilter == nil)
        #expect(provider.calls.last == .init(viewport: Self.paris, filter: .following))
    }

    @Test func clearingTheSubFilterFallsBackToThePrimary() async {
        let provider = FakeGeoProvider()
        let viewModel = MapsViewModel(repository: provider)
        viewModel.viewportChanged(Self.paris)
        viewModel.filterChanged(.pinned)
        viewModel.subFilterChanged(.placeCategory("parks"))
        await waitUntil { provider.calls.count == 3 }

        viewModel.subFilterChanged(nil)
        await waitUntil { provider.calls.count == 4 }

        #expect(provider.calls.last == .init(viewport: Self.paris, filter: .pinned))
    }

    @Test func subFilterWithoutAPrimaryIsIgnored() async {
        let provider = FakeGeoProvider()
        let viewModel = MapsViewModel(repository: provider)
        viewModel.viewportChanged(Self.paris)
        await waitUntil { provider.calls.count == 1 }

        viewModel.subFilterChanged(.placeCategory("cafes"))

        #expect(provider.calls.count == 1)
        #expect(viewModel.activeSubFilter == nil)
    }

    @Test func clearingTheFilterRequeriesAll() async {
        let provider = FakeGeoProvider()
        let viewModel = MapsViewModel(repository: provider)
        viewModel.viewportChanged(Self.paris)
        viewModel.filterChanged(.following)
        await waitUntil { provider.calls.count == 2 }

        viewModel.filterChanged(nil)
        await waitUntil { provider.calls.count == 3 }

        #expect(provider.calls.last == .init(viewport: Self.paris, filter: nil))
        #expect(viewModel.activeFilter == nil)
    }

    /// Bounded yield-polling: the fake answers synchronously, so the query
    /// task only needs scheduler turns, never wall-clock time.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { await Task.yield() }
    }
}

private final class FakeGeoProvider: GeoDiscoveryProviding, @unchecked Sendable {
    struct Call: Equatable {
        let viewport: MapViewport
        let filter: MapFilter?
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }

    func queryTile(_ viewport: MapViewport, filter: MapFilter?) async throws -> TileResult {
        lock.withLock { _calls.append(Call(viewport: viewport, filter: filter)) }
        return TileResult(pins: [], tileCount: 1)
    }
}
