import Testing
@testable import Profile

/// Settings → Privacy → Private Account (#388): the switch shows what the
/// server holds, never what was merely asked for.
@MainActor
struct PrivacySectionTests {
    @Test func loadsTheServersValue() async {
        let model = PrivacySectionViewModel(visibility: StubVisibility(isPrivate: true))
        await model.load()
        #expect(model.phase == .loaded(isPrivate: true))
    }

    @Test func goingPrivateWritesThenShows() async throws {
        let stub = StubVisibility(isPrivate: false)
        let model = PrivacySectionViewModel(visibility: stub)
        await model.load()
        try await model.setPrivate(true)
        #expect(await stub.writes == [true])
        #expect(model.phase == .loaded(isPrivate: true))
        #expect(!model.isSaving)
    }

    /// A failed write leaves the phase on the old value, so the switch snaps
    /// back to the truth.
    @Test func aFailedWriteKeepsTheOldValue() async {
        let model = PrivacySectionViewModel(visibility: StubVisibility(isPrivate: false, failsWrite: true))
        await model.load()
        await #expect(throws: (any Error).self) { try await model.setPrivate(true) }
        #expect(model.phase == .loaded(isPrivate: false))
        #expect(!model.isSaving)
    }

    @Test func settingTheSameValueSendsNothing() async throws {
        let stub = StubVisibility(isPrivate: true)
        let model = PrivacySectionViewModel(visibility: stub)
        await model.load()
        try await model.setPrivate(true)
        #expect(await stub.writes.isEmpty)
    }

    @Test func aFailedLoadCanBeRetried() async {
        let stub = StubVisibility(isPrivate: false, failsRead: true)
        let model = PrivacySectionViewModel(visibility: stub)
        await model.load()
        #expect(model.phase == .failed)
        await stub.recover()
        await model.load()
        #expect(model.phase == .loaded(isPrivate: false))
    }
}

private actor StubVisibility: ProfileVisibilityManaging {
    private var isPrivate: Bool
    private var failsRead: Bool
    private let failsWrite: Bool
    private(set) var writes: [Bool] = []

    init(isPrivate: Bool, failsRead: Bool = false, failsWrite: Bool = false) {
        self.isPrivate = isPrivate
        self.failsRead = failsRead
        self.failsWrite = failsWrite
    }

    func recover() { failsRead = false }

    func activeProfileIsPrivate() async throws -> Bool {
        if failsRead { throw ProfileError.notAuthenticated }
        return isPrivate
    }

    func setActiveProfilePrivate(_ isPrivate: Bool) async throws {
        if failsWrite { throw ProfileError.notAuthenticated }
        writes.append(isPrivate)
        self.isPrivate = isPrivate
    }
}
