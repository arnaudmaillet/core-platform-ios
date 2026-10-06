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
    private let key: String
    private let store: any SecureDataStore

    /// `key` is the keychain item: the member's session by default; the guest
    /// session (guest mode) keeps its own, so a sign-in never overwrites it.
    public init(store: any SecureDataStore, key: String = "auth.session") {
        self.store = store
        self.key = key
    }

    public func save(_ session: AuthSession) throws {
        try store.save(JSONEncoder().encode(session), forKey: key)
    }

    public func load() throws -> AuthSession? {
        guard let data = try store.load(forKey: key) else { return nil }
        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    public func clear() throws {
        try store.delete(forKey: key)
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
