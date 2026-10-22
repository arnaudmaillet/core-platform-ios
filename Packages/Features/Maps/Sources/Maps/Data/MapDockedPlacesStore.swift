import CoreStorage
import Foundation

/// The PLACES the viewer pinned to the map's dock (#1598, the owner
/// 2026-10-22): the place page's "Add Pin to Map". Each is a pill in the
/// dock beside the people's; a tap flies the map there.
///
/// Like `MapPlaceFollowStore`, the device is the source of truth (no place
/// contract on the server). Unlike it, an ordered LIST: the dock shows them
/// in the order they were pinned. Each entry is the place's public link
/// (`PlaceLink.url`, what its QR code carries — the one identity every
/// route agrees on) and the name its pill wears.
public final class MapDockedPlacesStore: @unchecked Sendable {
    public struct Entry: Codable, Equatable, Hashable, Sendable {
        /// `PlaceLink.url`'s string: the place's identity.
        public let url: String
        /// What the pill says: the place's name.
        public let name: String

        public init(url: String, name: String) {
            self.url = url
            self.name = name
        }
    }

    private static let baseKey = "maps.dockedPlaces"
    private let defaults: UserDefaults
    private let scope: StorageScope
    private var key: String { scope.profileKey(Self.baseKey, adoptingLegacyIn: defaults) }
    private let lock = NSLock()

    private var scopeObserver: NSObjectProtocol?

    public init(defaults: UserDefaults = .standard, scope: StorageScope = .shared) {
        self.defaults = defaults
        self.scope = scope
        // ⚠️ THE LIST IS THE PROFILE'S, AND THE PROFILE ARRIVES LATE: the map
        // reads the dock as it loads, before the active profile is known
        // (measured: no entry at launch, the pinned place under the
        // profile's key). A new owner is a new list — announced as one.
        scopeObserver = NotificationCenter.default.addObserver(
            forName: StorageScope.didChangeNotification, object: scope, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
    }

    deinit {
        if let scopeObserver { NotificationCenter.default.removeObserver(scopeObserver) }
    }

    /// Posted after every write, whatever screen made it: the map's dock
    /// re-reads the list. `object` is the store.
    public static let didChangeNotification = Notification.Name("maps.dockedPlaces.didChange")

    /// The docked places, in pin order.
    public var entries: [Entry] {
        lock.withLock { read() }
    }

    public func isDocked(_ url: String) -> Bool {
        lock.withLock { read().contains { $0.url == url } }
    }

    /// Docks an undocked place (at the end) and undocks a docked one.
    /// - Returns: the NEW state — what the toggling button renders.
    @discardableResult
    public func toggle(_ entry: Entry) -> Bool {
        let docked: Bool = lock.withLock {
            var list = read()
            if let index = list.firstIndex(where: { $0.url == entry.url }) {
                list.remove(at: index)
                write(list)
                return false
            }
            list.append(entry)
            write(list)
            return true
        }
        // Outside the lock: an observer re-entering the store must not deadlock.
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        return docked
    }

    private func read() -> [Entry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    private func write(_ list: [Entry]) {
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
    }
}
