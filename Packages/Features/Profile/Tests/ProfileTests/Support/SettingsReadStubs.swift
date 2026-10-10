import Foundation
@testable import Profile

/// Settings reads that fail on command (#799): `fails` flips without a
/// clock, so a test steps failure → retry → success deterministically.
actor SwitchableAccount: AccountProviding {
    private(set) var details: AccountDetails
    private(set) var fails: Bool
    private(set) var reads = 0

    init(details: AccountDetails = SwitchableAccount.sample, fails: Bool = false) {
        self.details = details
        self.fails = fails
    }

    static let sample = AccountDetails(
        email: "a@b.c", emailVerified: true, phone: "+33600000000", phoneVerified: true, country: "FR",
        dateOfBirth: BirthDate(year: 2001, month: 3, day: 12), ageBracket: .adult
    )

    func setFails(_ fails: Bool) { self.fails = fails }
    func setDetails(_ details: AccountDetails) { self.details = details }

    func currentAccount() async throws -> AccountDetails {
        reads += 1
        if fails { throw AccountError.transport(message: "offline") }
        return details
    }
}

actor SwitchableSessions: AccountSessionsManaging {
    private(set) var fails: Bool
    private let count: Int

    init(count: Int, fails: Bool = false) {
        self.count = count
        self.fails = fails
    }

    func setFails(_ fails: Bool) { self.fails = fails }

    func activeSessions() async throws -> [AccountSession] {
        if fails { throw AccountSessionsError.transport(message: "offline") }
        return (0..<count).map {
            AccountSession(id: "s\($0)", device: SessionDevice(userAgent: ""), isCurrent: $0 == 0, signedInAt: nil)
        }
    }

    func revokeSession(id: String) async throws {}
    func revokeAllSessions() async throws {}
}
