import CoreModels
import Foundation
import Testing
@testable import CoreStorage

/// In-memory `SecureDataStore`: the real keychain requires an entitlement
/// that bare test runners don't have, and the serialization/keying logic is
/// what this suite owns.
private final class FakeSecureDataStore: SecureDataStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func save(_ data: Data, forKey key: String) throws {
        lock.withLock { values[key] = data }
    }

    func load(forKey key: String) throws -> Data? {
        lock.withLock { values[key] }
    }

    func delete(forKey key: String) throws {
        lock.withLock { values[key] = nil }
    }
}

struct SessionStoreTests {
    private static func fixtureSession() -> AuthSession {
        AuthSession(
            accountID: AccountID("acct-1"),
            sessionID: SessionID("sess-1"),
            accessToken: "at-1",
            accessTokenExpiry: Date(timeIntervalSince1970: 1_000_000),
            refreshToken: "rt-1"
        )
    }

    @Test func sessionRoundTripsThroughSecureStore() throws {
        let store = KeychainSessionStore(store: FakeSecureDataStore())
        let session = Self.fixtureSession()

        #expect(try store.load() == nil)
        try store.save(session)
        #expect(try store.load() == session)

        var rotated = session
        rotated.refreshToken = "rt-2"
        try store.save(rotated)
        #expect(try store.load()?.refreshToken == "rt-2")

        try store.clear()
        #expect(try store.load() == nil)
    }

    @Test func inMemoryRoundTrip() throws {
        let store = InMemorySessionStore()
        #expect(try store.load() == nil)
        try store.save(Self.fixtureSession())
        #expect(try store.load() == Self.fixtureSession())
        try store.clear()
        #expect(try store.load() == nil)
    }
}
