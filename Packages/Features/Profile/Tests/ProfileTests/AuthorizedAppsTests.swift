import CoreContracts
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

// Settings → Security and Login → Apps and Websites (#485).

private actor FakeApps: AuthorizedAppsManaging {
    var apps: [AuthorizedApp]
    var failsList = false
    var failsRevoke = false
    private(set) var revoked: [String] = []

    init(_ apps: [AuthorizedApp]) { self.apps = apps }

    func setFailsList(_ fails: Bool) { failsList = fails }
    func setFailsRevoke(_ fails: Bool) { failsRevoke = fails }

    func authorizedApps() async throws -> [AuthorizedApp] {
        if failsList { throw URLError(.notConnectedToInternet) }
        return apps
    }

    func revokeAuthorizedApp(_ appID: String) async throws -> [AuthorizedApp] {
        if failsRevoke { throw URLError(.notConnectedToInternet) }
        revoked.append(appID)
        apps.removeAll { $0.id == appID }
        return apps
    }
}

private func app(_ id: String, scopes: [String] = ["email"], lastUsed: Date? = nil) -> AuthorizedApp {
    AuthorizedApp(id: id, name: "App \(id)", iconURL: nil, scopes: scopes, grantedAt: nil, lastUsedAt: lastUsed)
}

@MainActor
struct AuthorizedAppsTests {
    @Test func theListIsTheServers() async {
        let model = AuthorizedAppsViewModel(manager: FakeApps([app("a"), app("b")]))
        await model.load()
        #expect(model.phase == .loaded([app("a"), app("b")]))
    }

    /// Not optimistic: the row goes once the server has removed the access.
    @Test func removingAccessDropsTheRowTheServerDropped() async throws {
        let fake = FakeApps([app("a"), app("b")])
        let model = AuthorizedAppsViewModel(manager: fake)
        await model.load()

        try await model.remove(app("a"))

        #expect(await fake.revoked == ["a"])
        #expect(model.phase == .loaded([app("b")]))
        #expect(model.removing.isEmpty)
    }

    /// A removal that fails keeps the app listed.
    @Test func aFailedRemovalKeepsTheApp() async {
        let fake = FakeApps([app("a")])
        await fake.setFailsRevoke(true)
        let model = AuthorizedAppsViewModel(manager: fake)
        await model.load()

        await #expect(throws: (any Error).self) { try await model.remove(app("a")) }

        #expect(model.phase == .loaded([app("a")]))
        #expect(model.removing.isEmpty)
    }

    /// A failed load is a failed row with why; a retry loads.
    @Test func aFailedLoadSaysWhyAndCanBeRetried() async {
        let fake = FakeApps([app("a")])
        await fake.setFailsList(true)
        let model = AuthorizedAppsViewModel(manager: fake)
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.failure == .offline)

        await fake.setFailsList(false)
        await model.load()
        #expect(model.phase == .loaded([app("a")]))
    }

    @Test func theRowSaysWhatItMayDoAndWhenItLastDid() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(AuthorizedAppsViewController.subtitle(
            for: app("a", scopes: ["email", "profile:read"], lastUsed: now.addingTimeInterval(-3 * 3_600)), now: now
        ) == "Email address and Profile · Last used 3h ago")
        #expect(AuthorizedAppsViewController.subtitle(for: app("b", scopes: []), now: now) == "Sign-in only · Never used")
    }
}

/// Over the mock edge: the seeded apps, and a revoke that answers the list.
struct AuthorizedAppsRepositoryTests {
    private struct Token: AuthTokenProviding {
        func validAccessToken() async throws -> String? { "at-1" }
    }

    @Test func theRepositoryListsAndRevokes() async throws {
        let bff = MockBFF()
        MockAuthorizedAppsService(seeded: true).register(on: bff)
        let client = ConnectClientFactory.makeAuthenticated(host: "https://mock.bff.local", tokenProvider: Token(), httpClient: bff)
        let repository = AccountSessionsRepository(authClient: Auth_V1_AuthServiceClient(client: client))

        let apps = try await repository.authorizedApps()
        #expect(apps.map(\.id) == ["app-trailmap", "app-snapframe"])
        #expect(apps.first?.lastUsedAt != nil)
        #expect(apps.last?.lastUsedAt == nil)

        let after = try await repository.revokeAuthorizedApp("app-trailmap")
        #expect(after.map(\.id) == ["app-snapframe"])
        #expect(try await repository.authorizedApps().map(\.id) == ["app-snapframe"])
    }
}
