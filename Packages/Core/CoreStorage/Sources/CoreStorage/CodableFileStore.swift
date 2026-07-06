import Foundation

/// Single-value JSON snapshot persistence in Application Support. Used for
/// offline-first render paths (e.g. the first feed page): write the last
/// known snapshot, read it synchronously-cheap on next cold launch.
///
/// Deliberately not a database: snapshots are wholesale replace/read. When a
/// feature needs queryable or mutable local state, that's the cue for the
/// SQLite-backed store, not for growing this type.
public struct CodableFileStore<Value: Codable & Sendable>: Sendable {
    public enum StoreError: Error {
        case applicationSupportUnavailable
    }

    private let name: String
    // FileManager.default is thread-safe; not stored because FileManager
    // is not Sendable.
    private var fileManager: FileManager { .default }

    public init(name: String) {
        self.name = name
    }

    public func save(_ value: Value) throws {
        let url = try fileURL()
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    public func load() throws -> Value? {
        let url = try fileURL()
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Value.self, from: data)
    }

    public func clear() throws {
        let url = try fileURL()
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private func fileURL() throws -> URL {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.applicationSupportUnavailable
        }
        let directory = base.appendingPathComponent("Snapshots", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("\(name).json")
    }
}
