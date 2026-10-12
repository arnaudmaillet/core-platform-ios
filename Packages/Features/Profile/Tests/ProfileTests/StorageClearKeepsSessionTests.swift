import CacheKit
import CoreModels
import CoreStorage
import Foundation
import LocalStore
import MediaCore
import Testing
@testable import Profile

/// A CLEAR NEVER SIGNS THE VIEWER OUT (#899).
///
/// Settings → Storage clears caches: memory and disk, per category or all of
/// them. Everything that says WHO is here lives outside them and must come
/// through untouched: the session in the keychain, the device preferences,
/// the identity the stores are scoped by (`StorageScope`), and the LocalStore's
/// viewer, which keeps answering the same person (with no rows to give once
/// Other is cleared, and taking theirs again at the next load).
///
/// Every clear goes through the app's own inventory (`.standard`), over a
/// coordinator holding the app's kinds of namespace: the image pipeline's,
/// a LocalStore, a videos disk store and a messages memory cache.
@MainActor
@Suite(.serialized)
final class StorageClearKeepsSessionTests {
    private let root: URL
    private let suite = "StorageClearKeepsSessionTests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let keychainService = "cn.wynn.tests.storage-clear.\(UUID().uuidString)"

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "storage-clear-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        UserDefaults().removePersistentDomain(forName: suite)
        try? KeychainStore(service: keychainService).delete(forKey: "auth.session")
    }

    private static let viewer = LocalStoreViewer.member(account: "acc-1", profile: "prof-1")
    private static let listKey = "profile.grid.prof-1"

    private struct Device {
        let coordinator: CacheCoordinator
        let inventory: MediaCacheInventory
        let pipeline: ImagePipeline
        let localStore: LocalStore
        let caches: [any ManagedCache]
        var reasons: [TrimReason] { recorder.reasons }
        let recorder: Recorder
        let observation: CacheObservation?
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [TrimReason] = []
        var reasons: [TrimReason] { lock.withLock { stored } }
        func record(_ reason: TrimReason) { lock.withLock { stored.append(reason) } }
    }

    /// A coordinator over one namespace of each kind the app has, each holding
    /// something, and the viewer's LocalStore holding a page.
    private func device(scope: StorageScope) async throws -> Device {
        let coordinator = CacheCoordinator(
            device: CacheDevice(physicalMemory: { 4 << 30 }, availableDiskCapacity: { 100 * Int64(CacheBytes.gigabyte) }),
            storageLimit: .automatic
        )
        let pipeline = ImagePipeline(
            fetcher: PlaceholderImageFetcher(), disk: .folder(root.appending(path: "images")), coordinator: coordinator
        )
        await pipeline.waitUntilDiskIsOpen()
        _ = try await pipeline.image(for: URL(string: "mock://storage-clear/1?w=300&h=300")!)

        // Whose rows the store may hold, from the scope, as the app maps it
        // (`LocalStoreWiring`).
        let localStore = try LocalStore(directory: root.appending(path: "LocalStore")) {
            switch scope.owner {
            case .unscoped: nil
            case .guest: .guest
            case .member(let account, let profile): .member(account: account, profile: profile)
            }
        }
        coordinator.register(localStore)
        try Self.writePage(to: localStore)

        let videos = try DiskStore(
            namespace: CacheNamespace("t.video", category: .videos, scope: .public),
            budget: DiskBudget(pool: .video), root: root
        )
        _ = try videos.write(Data(count: 3_000), for: "v")
        let messages = MemoryCache<String, String>(
            namespace: CacheNamespace("t.messages", category: .messages, scope: .viewer),
            budget: .fixed(bytes: 10_000)
        )
        messages.insert("m", for: "m", cost: 70)
        for cache in [videos, messages] as [any ManagedCache] { coordinator.register(cache) }

        let recorder = Recorder()
        let observation = coordinator.observeTrims { recorder.record($0) }
        return Device(
            coordinator: coordinator, inventory: .standard(coordinator: coordinator), pipeline: pipeline,
            localStore: localStore, caches: [videos, messages], recorder: recorder, observation: observation
        )
    }

    private static func writePage(to store: LocalStore) throws {
        let key = LocalEntityKey(type: "post", id: "p1")
        let page = LocalListPage(
            items: [key],
            entities: [LocalEntityWrite(key: key, payload: Data("post".utf8), lifetime: 3_600)],
            nextCursor: nil, tier: .retained
        )
        #expect(try store.replaceList(listKey, with: page, as: viewer), "guard: the viewer's page is stored")
    }

    private static func session() -> AuthSession {
        AuthSession(
            accountID: AccountID("acc-1"), sessionID: SessionID("session-1"),
            accessToken: "access", accessTokenExpiry: Date(timeIntervalSince1970: 2_000_000_000), refreshToken: "refresh"
        )
    }

    /// `nil` is Clear All.
    @Test(arguments: [CacheCategory?.none, .images, .videos, .messages, .other])
    func aClearKeepsTheSessionTheScopeAndThePreferences(_ category: CacheCategory?) async throws {
        let scope = StorageScope(owner: .member(account: "acc-1", profile: "prof-1"))
        let device = try await self.device(scope: scope)
        let sharedOwner = StorageScope.shared.owner

        // The session, in the keychain as the app keeps it when the host allows
        // it (a bare simulator test runner has no keychain entitlement: the
        // simulator check covers the app's real keychain), and its in-memory
        // twin.
        let keychain = KeychainSessionStore(store: KeychainStore(service: keychainService))
        let keychainWorks = (try? keychain.save(Self.session())) != nil
        let memorySession = InMemorySessionStore(session: Self.session())

        // Device preferences, and a profile-scoped value (#443).
        CacheStoragePreference.save(.total(bytes: CacheBytes.gigabyte), to: defaults)
        let playback = MediaPlaybackPreferencesStore(defaults: defaults)
        playback.update { $0.dataSaver = true }
        let scopedKey = scope.profileKey("storage-clear.seen")
        defaults.set(["p1"], forKey: scopedKey)

        // Files beside the caches that no clear may reach: an upload capture
        // in the temporary folder, an unowned file under Caches.
        let capture = FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString).mov")
        try Data(count: 10).write(to: capture)
        defer { try? FileManager.default.removeItem(at: capture) }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let unowned = caches.appending(path: "storage-clear-unowned-\(UUID().uuidString)")
        try Data(count: 10).write(to: unowned)
        defer { try? FileManager.default.removeItem(at: unowned) }

        let model = StorageSettingsModel(
            inventory: device.inventory, coordinator: device.coordinator, playback: playback, defaults: defaults
        )
        await model.clear(category)

        // Who is here.
        if keychainWorks {
            #expect(try keychain.load() == Self.session(), "the clear signed the viewer out of the keychain")
        }
        #expect(try memorySession.load() == Self.session())
        #expect(scope.owner == .member(account: "acc-1", profile: "prof-1"), "the clear changed whose stores these are")
        #expect(StorageScope.shared.owner == sharedOwner)
        #expect(device.reasons == [.clear(category)], "the clear was announced as \(device.reasons)")
        #expect(!device.reasons.contains(.viewerChanged), "a clear must never read as a viewer change")

        // The device's choices.
        #expect(CacheStoragePreference.load(from: defaults) == .total(bytes: CacheBytes.gigabyte))
        #expect(playback.preferences.dataSaver)
        #expect(defaults.stringArray(forKey: scopedKey) == ["p1"])
        #expect(FileManager.default.fileExists(atPath: capture.path), "an upload capture was deleted")
        #expect(FileManager.default.fileExists(atPath: unowned.path), "a file the inventory does not own was deleted")

        // The LocalStore's viewer: kept by every clear but Other's, and after
        // Other's the same person takes their rows again at the next load —
        // nothing wiped, nobody else's.
        let clearsLocalStore = category == nil || category == .other
        let listed = device.localStore.list(Self.listKey)
        if clearsLocalStore {
            #expect(listed == nil, "guard: Other's clear empties the LocalStore")
            try Self.writePage(to: device.localStore)
        }
        #expect(device.localStore.list(Self.listKey)?.entries.count == 1,
                "the viewer's LocalStore no longer answers them")
        withExtendedLifetime(device) {}
    }
}
