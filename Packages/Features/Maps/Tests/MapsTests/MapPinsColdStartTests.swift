import CoreModels
import Foundation
import LocalStore
import Synchronization
import Testing
@testable import Maps

// The map opens on the pins of its last viewports at a cold start, offline
// included, from the LocalStore (#893).

private final class StoreFolder: Sendable {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "MapPinsColdStartTests-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit { try? FileManager.default.removeItem(at: url) }
}

private final class ViewerBox: Sendable {
    private let current = Mutex<LocalStoreViewer?>(.member(account: "acct-1", profile: "me"))

    var viewer: LocalStoreViewer? {
        get { current.withLock { $0 } }
        set { current.withLock { $0 = newValue } }
    }
}

/// Answers every query with `pins`, or fails while offline; counts queries.
private final class TileServer: GeoDiscoveryProviding, @unchecked Sendable {
    struct Offline: Error {}

    private let lock = NSLock()
    private var _pins: [MapPin]
    private var _offline = false
    private var _calls = 0

    init(pins: [MapPin] = []) { _pins = pins }

    var pins: [MapPin] {
        get { lock.withLock { _pins } }
        set { lock.withLock { _pins = newValue } }
    }
    var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }
    var calls: Int { lock.withLock { _calls } }

    func queryTile(_ viewport: MapViewport, filter: MapFilter?) async throws -> TileResult {
        let (pins, offline) = lock.withLock { () -> ([MapPin], Bool) in
            _calls += 1
            return (_pins, _offline)
        }
        if offline { throw Offline() }
        return TileResult(pins: pins, tileCount: 1)
    }
}

private func pin(_ id: String, lat: Double = 48.8566, lng: Double = 2.3522, kind: MapPin.Kind = .photo, likes: Int64 = 0) -> MapPin {
    MapPin(
        postID: PostID(id), latitude: lat, longitude: lng,
        thumbnailURL: kind == .text ? nil : URL(string: "https://cdn.example/\(id).jpg"),
        kind: kind, likeCount: likes
    )
}

@MainActor
final class MapPinsColdStartTests {
    private let folder = StoreFolder()
    private let viewer = ViewerBox()

    private static let paris = MapViewport.make(centerLat: 48.8566, centerLng: 2.3522, latitudeSpan: 0.09, longitudeSpan: 0.09)
    private static let tokyo = MapViewport.make(centerLat: 35.6762, centerLng: 139.6503, latitudeSpan: 0.09, longitudeSpan: 0.09)

    /// One launch's cache, over a new store on the same file.
    private func launchCache() throws -> MapPinsLocalCache {
        let box = viewer
        return MapPinsLocalCache(store: try LocalStore(directory: folder.url, viewer: { box.viewer }))
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<2_000 where !condition() {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func ids(_ pins: [MapPin]?) -> Set<String> {
        Set((pins ?? []).map(\.postID.rawValue))
    }

    /// The previous session: the map settled on `viewport` online and got
    /// `pins` back.
    private func previousSession(_ pins: [MapPin], at viewport: MapViewport = paris) async throws {
        let cache = try launchCache()
        let server = TileServer(pins: pins)
        let viewModel = MapsViewModel(repository: server, localCache: cache)
        var answered = 0
        viewModel.onTileCount = { _ in answered += 1 }
        viewModel.viewportChanged(viewport)
        await waitUntil { answered == 1 }
        try #require(answered == 1)
        cache.waitForPendingWrites()
    }

    @Test func theMapOpensOnItsLastPinsOfflineAfterAColdStart() async throws {
        try await previousSession([pin("a", likes: 12), pin("b", kind: .text), pin("c", kind: .video)])

        let server = TileServer()
        server.offline = true
        let viewModel = MapsViewModel(repository: server, localCache: try launchCache())
        var diffs: [MapAnnotationDiff] = []
        viewModel.onDiff = { diffs.append($0) }
        var failures: [String] = []
        viewModel.onRepeatedQueryFailure = { failures.append($0) }

        // Before any query and any await: the markers are back.
        viewModel.restoreStoredPins()
        #expect(server.calls == 0)
        #expect(ids(diffs.first?.added) == ["a", "b", "c"], "the cold start opened on an empty map")
        let restored = Dictionary(uniqueKeysWithValues: (diffs.first?.added ?? []).map { ($0.postID.rawValue, $0) })
        #expect(restored["a"]?.likeCount == 12, "the cluster face competes on its stored like count")
        #expect(restored["b"]?.kind == .text)
        #expect(restored["c"]?.kind == .video)
        #expect(restored["a"]?.thumbnailURL == URL(string: "https://cdn.example/a.jpg"))

        // Offline, the queries fail and the pins stay (fail-open).
        viewModel.viewportChanged(Self.paris)
        await waitUntil { server.calls == 1 }
        viewModel.viewportChanged(Self.paris)
        await waitUntil { failures.count == 1 }
        #expect(diffs.count == 1, "a failed query took the restored pins away")
        #expect(viewModel.pinCount == 3)
    }

    @Test func anOnlineAnswerRevalidatesTheRestoredPinsInPlace() async throws {
        try await previousSession([pin("a"), pin("b")])

        let server = TileServer(pins: [pin("a"), pin("c")])
        let viewModel = MapsViewModel(repository: server, localCache: try launchCache())
        var diffs: [MapAnnotationDiff] = []
        viewModel.onDiff = { diffs.append($0) }
        viewModel.restoreStoredPins()
        viewModel.viewportChanged(Self.paris)
        await waitUntil { diffs.count == 2 }

        let revalidation = try #require(diffs.last)
        #expect(ids(revalidation.added) == ["c"])
        #expect(ids(revalidation.removed) == ["b"])
        #expect(revalidation.updated.isEmpty, "a confirmed pin was rebuilt")
    }

    @Test func eachAnswerReplacesItsViewportAndKeepsTheOthers() async throws {
        let cache = try launchCache()
        let server = TileServer(pins: [pin("p1"), pin("p2")])
        let viewModel = MapsViewModel(repository: server, localCache: cache)
        var answered = 0
        viewModel.onTileCount = { _ in answered += 1 }
        viewModel.viewportChanged(Self.paris)
        await waitUntil { answered == 1 }
        server.pins = [pin("t1", lat: 35.6762, lng: 139.6503)]
        viewModel.viewportChanged(Self.tokyo)
        await waitUntil { answered == 2 }
        // Paris again: p2 is gone from there now.
        server.pins = [pin("p1"), pin("p3")]
        viewModel.viewportChanged(Self.paris)
        await waitUntil { answered == 3 }
        try #require(answered == 3)
        cache.waitForPendingWrites()

        let stored = try #require(try launchCache().stored())
        #expect(stored.map(\.postID.rawValue) == ["p1", "p3", "t1"], "newest viewport first, the other viewport kept")
    }

    @Test func aFilteredAnswerIsNotStored() async throws {
        try await previousSession([pin("a")])
        let cache = try launchCache()
        let server = TileServer(pins: [pin("friend-1")])
        let viewModel = MapsViewModel(repository: server, localCache: cache)
        var answered = 0
        viewModel.onTileCount = { _ in answered += 1 }
        viewModel.filterChanged(.friends)
        viewModel.viewportChanged(Self.paris)
        await waitUntil { answered == 1 }
        try #require(answered == 1)
        cache.waitForPendingWrites()

        #expect(ids(try launchCache().stored()) == ["a"])
        // And a filtered map does not open on the unfiltered pins.
        var diffs: [MapAnnotationDiff] = []
        let filtered = MapsViewModel(repository: TileServer(), localCache: try launchCache())
        filtered.onDiff = { diffs.append($0) }
        filtered.filterChanged(.friends)
        filtered.restoreStoredPins()
        #expect(diffs.isEmpty)
    }

    @Test func theStoredPinsAreBounded() {
        let many = (0..<(MapPinsLocalCache.maxStoredPins + 50)).map { MapPinsLocalCache.Record(pin("n\($0)", lat: 10, lng: 10)) }
        let folded = MapPinsLocalCache.folding(many, in: Self.paris, into: [MapPinsLocalCache.Record(pin("old"))])
        #expect(folded.count == MapPinsLocalCache.maxStoredPins)
        #expect(folded.first?.id == "n0", "the newest answer is kept first")
    }

    @Test func theDecorationRunsOverRestoredPins() async throws {
        try await previousSession([pin("a", kind: .text)])
        var diffs: [MapAnnotationDiff] = []
        let viewModel = MapsViewModel(
            repository: TileServer(),
            decorate: { pins in pins.map { $0.tagged(with: [MapPlace(id: "city:paris", name: "Paris", kind: .city)]) } },
            localCache: try launchCache()
        )
        viewModel.onDiff = { diffs.append($0) }
        viewModel.restoreStoredPins()
        #expect(diffs.first?.added.first?.place?.id == "city:paris")
    }

    @Test func anotherViewerOpensOnAnEmptyMap() async throws {
        try await previousSession([pin("a"), pin("b")])

        viewer.viewer = .member(account: "acct-2", profile: "prof-9")
        let cache = try launchCache()
        #expect(cache.stored() == nil)
        var diffs: [MapAnnotationDiff] = []
        let viewModel = MapsViewModel(repository: TileServer(), localCache: cache)
        viewModel.onDiff = { diffs.append($0) }
        viewModel.restoreStoredPins()
        #expect(diffs.isEmpty)
    }

    @Test func anAnswerForAViewerWhoLeftIsDropped() async throws {
        let cache = try launchCache()
        cache.record([pin("a")], in: Self.paris, as: .member(account: "acct-1", profile: "me"))
        cache.waitForPendingWrites()
        // Fetched for the previous viewer, landing after the switch.
        viewer.viewer = .member(account: "acct-2", profile: "prof-9")
        cache.record([pin("x")], in: Self.tokyo, as: .member(account: "acct-1", profile: "me"))
        cache.waitForPendingWrites()
        #expect(cache.stored() == nil)
    }
}
