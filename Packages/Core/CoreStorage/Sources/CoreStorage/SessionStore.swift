import CoreModels
import Foundation

/// Persistence boundary for the auth session. Synchronous by design — the
/// keychain is a fast local call and callers are already off the main actor.
public protocol SessionStore: Sendable {
    func save(_ session: AuthSession) throws
    func load() throws -> AuthSession?
    func clear() throws
}

/// Keychain-backed store; the session (including the refresh token) never
/// touches UserDefaults or disk files. Generic over `SecureDataStore` so the
/// serialization logic is testable where the keychain is unavailable (bare
/// test runners lack the required entitlement).
public struct KeychainSessionStore: SessionStore {
    private static let key = "auth.session"
    private let store: any SecureDataStore

    public init(store: any SecureDataStore) {
        self.store = store
    }

    public func save(_ session: AuthSession) throws {
        try store.save(JSONEncoder().encode(session), forKey: Self.key)
    }

    public func load() throws -> AuthSession? {
        guard let data = try store.load(forKey: Self.key) else { return nil }
        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    public func clear() throws {
        try store.delete(forKey: Self.key)
    }
}

/// Non-persisting store for tests and previews.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: AuthSession?

    public init(session: AuthSession? = nil) {
        self.session = session
    }

    public func save(_ session: AuthSession) throws {
        lock.withLock { self.session = session }
    }

    public func load() throws -> AuthSession? {
        lock.withLock { session }
    }

    public func clear() throws {
        lock.withLock { session = nil }
    }
}
