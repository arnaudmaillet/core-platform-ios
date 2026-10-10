import CoreNetworking
import Foundation
@testable import Profile

/// Settings reads that fail on command (#799): `fails` flips without a
/// clock, so a test steps failure → retry → success deterministically.
actor SwitchableAccount: AccountProviding {
    private(set) var details: AccountDetails
    private(set) var fails: Bool
    private(set) var reads = 0
    /// Holds each read until released, for in-flight tests.
    private let gate: ReadGate?
    /// Why a failing read failed (#794): nil reads as a server fault.
    private let failure: NetworkFailure?

    init(
        details: AccountDetails = SwitchableAccount.sample, fails: Bool = false, gate: ReadGate? = nil,
        failure: NetworkFailure? = nil
    ) {
        self.details = details
        self.fails = fails
        self.gate = gate
        self.failure = failure
    }

    static let sample = AccountDetails(
        email: "a@b.c", emailVerified: true, phone: "+33600000000", phoneVerified: true, country: "FR",
        dateOfBirth: BirthDate(year: 2001, month: 3, day: 12), ageBracket: .adult
    )

    func setFails(_ fails: Bool) { self.fails = fails }
    func setDetails(_ details: AccountDetails) { self.details = details }

    func currentAccount() async throws -> AccountDetails {
        reads += 1
        await gate?.pass()
        if fails { throw AccountError.transport(message: "offline", failure: failure) }
        return details
    }
}

/// Parks a read until the test releases it, and tells the test when the
/// read has started — an ordering without a clock, for "a second call while
/// the first is in flight" tests.
actor ReadGate {
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    /// Called by the stub's read: signals entry, then waits for release.
    func pass() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    /// Returns once a read has entered the gate.
    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}

actor SwitchableSessions: AccountSessionsManaging {
    private(set) var fails: Bool
    private let count: Int
    /// Why a failing read failed (#794): nil reads as a server fault.
    private let failure: NetworkFailure?

    init(count: Int, fails: Bool = false, failure: NetworkFailure? = nil) {
        self.count = count
        self.fails = fails
        self.failure = failure
    }

    func setFails(_ fails: Bool) { self.fails = fails }

    func activeSessions() async throws -> [AccountSession] {
        if fails { throw AccountSessionsError.transport(message: "offline", failure: failure) }
        return (0..<count).map {
            AccountSession(id: "s\($0)", device: SessionDevice(userAgent: ""), isCurrent: $0 == 0, signedInAt: nil)
        }
    }

    func revokeSession(id: String) async throws {}
    func revokeAllSessions() async throws {}
}
