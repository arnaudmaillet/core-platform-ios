import CacheKit
import CoreStorage
import Foundation

/// Settings → Storage (#899): usage and a clear per category, the storage
/// limit, and Use Less Cellular Data. Everything goes through the app's
/// `CacheCoordinator`; the screen only draws what this holds.
@MainActor
final class StorageSettingsModel {
    /// The categories the screen lists, in order.
    static let categories: [CacheCategory] = [.images, .videos, .messages, .other]

    private let inventory: MediaCacheInventory
    private let coordinator: CacheCoordinator?
    private let playback: MediaPlaybackPreferencesStore
    private let defaults: UserDefaults

    /// The last measurement; nil while measuring.
    private(set) var report: StorageReport?
    /// Called after every change the screen shows.
    var onChange: (() -> Void)?
    /// Bumped by every measurement and clear, so a measurement that started
    /// before a clear never lands after it.
    private var generation = 0

    init(
        inventory: MediaCacheInventory,
        coordinator: CacheCoordinator?,
        playback: MediaPlaybackPreferencesStore = .standard,
        defaults: UserDefaults = .standard
    ) {
        self.inventory = inventory
        self.coordinator = coordinator
        self.playback = playback
        self.defaults = defaults
    }

    // MARK: - Usage

    /// Measures every category off the main thread.
    func refresh() async {
        generation += 1
        let started = generation
        let inventory = inventory
        let measured = await Task.detached(priority: .utility) { inventory.report() }.value
        guard started == generation else { return }
        report = measured
        onChange?()
    }

    /// Clears one category, or everything (`nil`), then measures again.
    func clear(_ category: CacheCategory?) async {
        let inventory = inventory
        generation += 1
        report = nil
        onChange?()
        await Task.detached(priority: .utility) { inventory.clear(category) }.value
        await refresh()
    }

    // MARK: - Limit

    /// The limit in force: the coordinator's, or the saved one without it.
    var limit: CacheStorageLimit {
        coordinator?.storageLimit ?? CacheStoragePreference.load(from: defaults)
    }

    /// The bytes the limit allows now. Automatic follows the free disk space
    /// (the coordinator halves its pools when the iPhone is short of it).
    var limitBytes: Int64 {
        Int64(coordinator?.diskPoolBudgets.total ?? DiskPoolBudgets(limit: limit, pressure: .normal).total)
    }

    /// Saves `limit` on the device and applies it at once: a lower one evicts
    /// speculative, then recent entries until every namespace fits.
    func choose(_ limit: CacheStorageLimit) async {
        guard limit != self.limit else { return }
        CacheStoragePreference.save(limit, to: defaults)
        if let coordinator {
            // Eviction deletes files: off the main thread.
            await Task.detached(priority: .userInitiated) { coordinator.setStorageLimit(limit) }.value
        }
        onChange?()
        await refresh()
    }

    // MARK: - Cellular

    /// Use Less Cellular Data: the playback preference that already capped
    /// stream quality on cellular (Data Saver, #409), now also the
    /// coordinator's prefetch policy (`CacheConditions.usesLessCellularData`).
    var usesLessCellularData: Bool { playback.preferences.dataSaver }

    func setUsesLessCellularData(_ isOn: Bool) {
        playback.update { $0.dataSaver = isOn }
        coordinator?.updateConditions { $0.usesLessCellularData = isOn }
        onChange?()
    }
}
