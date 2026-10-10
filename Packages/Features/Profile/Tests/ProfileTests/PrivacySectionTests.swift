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

    // MARK: - Side settings (#799)

    private func makeSideModel(_ sides: StubSides) -> PrivacySectionViewModel {
        PrivacySectionViewModel(
            visibility: StubVisibility(isPrivate: false),
            windows: sides, comments: sides, sharing: sides, audiences: sides
        )
    }

    /// They used to be read with `try?` and their rows simply vanished.
    @Test func failedSideSettingsAreMarkedFailedNotLeftBlank() async {
        let model = makeSideModel(StubSides(fails: true))
        await model.load()
        #expect(model.failedSides == Set(PrivacySectionViewModel.SideSetting.allCases))
        #expect(model.postWindow == nil)
        #expect(model.commentAudience == nil)
        #expect(model.mentionAudience == nil)
        #expect(model.postSharing == nil)
        #expect(model.phase == .loaded(isPrivate: false))
    }

    @Test func retryingOneSideSettingLoadsOnlyThatOne() async {
        let sides = StubSides(fails: true)
        let model = makeSideModel(sides)
        await model.load()
        await sides.setFails(false)
        #expect(await model.reload(.commentAudience))
        #expect(model.commentAudience == .followers)
        #expect(model.failedSides == [.postWindow, .interactionAudiences, .postSharing])
        #expect(model.postWindow == nil)
        #expect(await sides.commentReads == 2)
        #expect(await sides.windowReads == 1)
    }

    @Test func retryingTheAudiencesLoadsBothRows() async {
        let sides = StubSides(fails: true)
        let model = makeSideModel(sides)
        await model.load()
        await sides.setFails(false)
        #expect(await model.reload(.interactionAudiences))
        #expect(model.mentionAudience == .followers)
        #expect(model.messageAudience == .followers)
        #expect(!model.failedSides.contains(.interactionAudiences))
    }

    @Test func aSideRetryThatFailsAgainStaysFailedAndReportsIt() async {
        let model = makeSideModel(StubSides(fails: true))
        await model.load()
        #expect(await model.reload(.postSharing) == false)
        #expect(model.failedSides.contains(.postSharing))
    }

    @Test func aFailedRefreshKeepsTheSideValuesAlreadyShown() async {
        let sides = StubSides()
        let model = makeSideModel(sides)
        await model.load()
        #expect(model.failedSides.isEmpty)
        await sides.setFails(true)
        await model.load()
        #expect(model.failedSides.isEmpty)
        #expect(model.postWindow == .sixMonths)
        #expect(model.commentAudience == .followers)
        #expect(model.postSharing == PostSharing(showsLikeCounts: false, allowsDownloads: true))
    }

    /// A side the screen can't set is neither shown nor failed.
    @Test func aSideWithoutASourceIsNeverFailed() async {
        let model = PrivacySectionViewModel(visibility: StubVisibility(isPrivate: true))
        await model.load()
        #expect(model.failedSides.isEmpty)
        #expect(await model.reload(.postWindow))
    }
}

private actor StubSides: PostWindowManaging, CommentAudienceManaging, PostSharingManaging, InteractionAudienceManaging {
    private var fails: Bool
    private(set) var commentReads = 0
    private(set) var windowReads = 0

    init(fails: Bool = false) { self.fails = fails }

    func setFails(_ fails: Bool) { self.fails = fails }

    private func check() throws {
        if fails { throw ProfileError.notAuthenticated }
    }

    func postWindow() async throws -> PostWindow {
        windowReads += 1
        try check()
        return .sixMonths
    }

    func setPostWindow(_ window: PostWindow) async throws {}

    func commentAudience() async throws -> CommentAudience {
        commentReads += 1
        try check()
        return .followers
    }

    func setCommentAudience(_ audience: CommentAudience) async throws {}

    func postSharing() async throws -> PostSharing {
        try check()
        return PostSharing(showsLikeCounts: false, allowsDownloads: true)
    }

    func setPostSharing(_ sharing: PostSharing) async throws {}

    func audience(for kind: InteractionKind) async throws -> InteractionAudience {
        try check()
        return .followers
    }

    func setAudience(_ audience: InteractionAudience, for kind: InteractionKind) async throws {}
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
