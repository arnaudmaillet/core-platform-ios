import AuthInterface
import CoreModels
import Foundation
import Testing

/// An auth session the test drives: sign in, sign out, sign in as someone else.
private actor FakeAuthSession: AuthSessionProviding {
    private var state: AuthState
    private var continuations: [UUID: AsyncStream<AuthState>.Continuation] = [:]

    init(_ state: AuthState) { self.state = state }

    func currentState() -> AuthState { state }

    func stateUpdates() -> AsyncStream<AuthState> {
        let (stream, continuation) = AsyncStream<AuthState>.makeStream()
        continuations[UUID()] = continuation
        continuation.yield(state)
        return stream
    }

    func logout() { set(.unauthenticated) }

    func set(_ newState: AuthState) {
        state = newState
        for continuation in continuations.values { continuation.yield(newState) }
    }
}

/// `ListProfilesByAccount`, counted, and optionally held open so a test can
/// change the account while a list is in flight.
private actor ProfileDirectory {
    private let profiles: [AccountID: [ProfileID]]
    private(set) var calls = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var holding = false

    init(_ profiles: [AccountID: [ProfileID]]) { self.profiles = profiles }

    func hold() { holding = true }

    func release() {
        holding = false
        let waiting = held
        held = []
        for continuation in waiting { continuation.resume() }
    }

    func list(_ account: AccountID) async -> [ProfileID] {
        calls += 1
        if holding {
            await withCheckedContinuation { held.append($0) }
        }
        return profiles[account] ?? []
    }

    var waitingCount: Int { held.count }
}

private let alice = AccountID("acct-alice")
private let bob = AccountID("acct-bob")
private let aliceMain = ProfileID("alice-main")
private let aliceWork = ProfileID("alice-work")
private let bobMain = ProfileID("bob-main")

private func makeSession(
    _ auth: FakeAuthSession,
    _ directory: ProfileDirectory
) -> ViewerSession {
    ViewerSession(authSession: auth) { account in await directory.list(account) }
}

private func directory() -> ProfileDirectory {
    ProfileDirectory([alice: [aliceMain, aliceWork], bob: [bobMain]])
}

struct ViewerSessionTests {
    @Test func aGuestHasNoProfile() async {
        let session = makeSession(FakeAuthSession(.unauthenticated), directory())

        #expect(await session.current() == .guest)
        await #expect(throws: ViewerError.requiresMember) {
            try await session.activeProfileID()
        }
    }

    @Test func aMemberResolvesTheFirstProfileOnce() async throws {
        let profiles = directory()
        let session = makeSession(FakeAuthSession(.authenticated(alice)), profiles)

        #expect(await session.current() == .member(alice, activeProfile: nil))
        #expect(try await session.activeProfileID() == aliceMain)
        #expect(try await session.activeProfileID() == aliceMain)
        #expect(await session.current() == .member(alice, activeProfile: aliceMain))
        #expect(await profiles.calls == 1)
    }

    @Test func concurrentFirstReadsShareOneListCall() async throws {
        let profiles = directory()
        await profiles.hold()
        let session = makeSession(FakeAuthSession(.authenticated(alice)), profiles)

        async let first = session.activeProfileID()
        async let second = session.activeProfileID()
        async let third = session.activeProfileID()
        while await profiles.waitingCount == 0 { await Task.yield() }
        await profiles.release()

        #expect(try await [first, second, third] == [aliceMain, aliceMain, aliceMain])
        #expect(await profiles.calls == 1)
    }

    @Test func anAccountWithoutProfilesSaysSo() async {
        let session = makeSession(FakeAuthSession(.authenticated(AccountID("acct-new"))), directory())

        await #expect(throws: ViewerError.noProfileForAccount) {
            try await session.activeProfileID()
        }
    }

    @Test func aSwitchIsSeenByEveryReader() async throws {
        let session = makeSession(FakeAuthSession(.authenticated(alice)), directory())
        _ = try await session.activeProfileID()

        await session.setActiveProfile(aliceWork)

        #expect(try await session.activeProfileID() == aliceWork)
        #expect(await session.current() == .member(alice, activeProfile: aliceWork))
    }

    /// Logout, then another account: the previous account's profile must
    /// never answer for the new one.
    @Test func anotherAccountNeverInheritsTheProfile() async throws {
        let auth = FakeAuthSession(.authenticated(alice))
        let session = makeSession(auth, directory())
        #expect(try await session.activeProfileID() == aliceMain)

        await auth.logout()
        #expect(await session.current() == .guest)
        await auth.set(.authenticated(bob))

        #expect(try await session.activeProfileID() == bobMain)
    }

    @Test func aListThatComesBackForASignedOutAccountIsDiscarded() async throws {
        let profiles = directory()
        await profiles.hold()
        let auth = FakeAuthSession(.authenticated(alice))
        let session = makeSession(auth, profiles)

        async let resolved = session.activeProfileID()
        while await profiles.waitingCount == 0 { await Task.yield() }
        await auth.set(.authenticated(bob))
        // Alice's list lands after Bob signed in; the session asks again for Bob.
        await profiles.release()

        #expect(try await resolved == bobMain)
        #expect(await session.current() == .member(bob, activeProfile: bobMain))
    }

    @Test func transitionsSkipTheStartAndFirstResolution() async throws {
        let auth = FakeAuthSession(.authenticated(alice))
        let session = makeSession(auth, directory())
        var transitions = await session.transitions().makeAsyncIterator()

        _ = try await session.activeProfileID() // first resolution: not a change
        await session.setActiveProfile(aliceWork) // leaving alice-main: a change
        #expect(await transitions.next() == .member(alice, activeProfile: aliceWork))

        await auth.logout()
        _ = await session.current()
        #expect(await transitions.next() == .guest)

        await auth.set(.authenticated(bob))
        _ = await session.current()
        #expect(await transitions.next() == .member(bob, activeProfile: nil))
    }

    @Test func updatesStartWithTheCurrentState() async throws {
        let session = makeSession(FakeAuthSession(.authenticated(alice)), directory())
        var updates = await session.updates().makeAsyncIterator()

        #expect(await updates.next() == .member(alice, activeProfile: nil))
        _ = try await session.activeProfileID()
        #expect(await updates.next() == .member(alice, activeProfile: aliceMain))
    }
}
