import DesignSystem
import Testing
@testable import Profile

/// The age read behind Family and Teens and What You See (#799): a failed
/// read used to answer "adult" — the adult wording on Family and Teens, and
/// Standard offered on What You See. It now fails the age-dependent part.
@MainActor
struct TeenCheckFailureTests {
    private struct Offline: Error {}

    @Test func aFailedAgeReadIsFailedNotAdult() async {
        let age = await FamilyAndTeensViewController.readAge { throw Offline() }
        #expect(age == .failed(message: FamilyAndTeensViewController.failedText))
        #expect(age.content == nil)
    }

    @Test func aRetriedAgeReadLoadsTheAge() async {
        let account = SwitchableAccount(
            details: AccountDetails(email: "a@b.c", emailVerified: true, phone: "", phoneVerified: false, country: "FR", ageBracket: .teen13to15),
            fails: true
        )
        let isTeen: () async throws -> Bool = { try await account.currentAccount().ageBracket.isTeen }
        #expect(await FamilyAndTeensViewController.readAge(isTeen).isFailed)
        await account.setFails(false)
        #expect(await FamilyAndTeensViewController.readAge(isTeen) == .content(true))
    }

    @Test func aKnownAdultStillReadsAsAdult() async {
        #expect(await FamilyAndTeensViewController.readAge { false } == .content(false))
    }

    @Test func theAgeCheckFailsThenLoadsOnRetry() async {
        let account = SwitchableAccount(fails: true)
        let check = TeenAgeCheck { try await account.currentAccount().ageBracket.isTeen }
        #expect(await check.read() == false)
        #expect(check.age.isFailed)
        await account.setFails(false)
        #expect(await check.read())
        #expect(check.age == .content(false))
    }

    /// A double tap on the failed row: one read, so offline one toast.
    @Test(.timeLimit(.minutes(10))) func aSecondAgeReadWhileOneIsInFlightSendsNoSecondRead() async {
        let gate = ReadGate()
        let account = SwitchableAccount(fails: true, gate: gate)
        let check = TeenAgeCheck { try await account.currentAccount().ageBracket.isTeen }
        let first = Task { await check.read() }
        await gate.waitUntilEntered()
        #expect(check.isReading)
        #expect(await check.read(), "the duplicate has nothing to report")
        await gate.release()
        #expect(await first.value == false)
        #expect(await account.reads == 1)
        #expect(!check.isReading)
    }

    /// What You See: Standard is only offered once the age says adult.
    @Test func aFailedAgeReadFailsTheSensitiveContentSection() async {
        let loaded = await WhatYouSeeViewController.loadSensitive(preferences: StubPreferences()) { throw Offline() }
        #expect(loaded.phase == .failed)
        #expect(loaded.teen == nil)
    }

    @Test func aRetryWithTheAgeReadableLoadsTheSection() async {
        let account = SwitchableAccount(fails: true)
        let isTeen: () async throws -> Bool = { try await account.currentAccount().ageBracket.isTeen }
        #expect(await WhatYouSeeViewController.loadSensitive(preferences: StubPreferences(), isTeen: isTeen).phase == .failed)
        await account.setFails(false)
        let loaded = await WhatYouSeeViewController.loadSensitive(preferences: StubPreferences(), isTeen: isTeen)
        #expect(loaded.phase == .loaded(.less, personalized: true))
        #expect(loaded.teen == false)
    }
}

private actor StubPreferences: FeedPreferencesManaging {
    func sensitiveContent() async throws -> SensitiveContentLevel { .less }
    func setSensitiveContent(_ level: SensitiveContentLevel) async throws {}
    func personalizedFeed() async throws -> Bool { true }
    func setPersonalizedFeed(_ isOn: Bool) async throws {}
}
