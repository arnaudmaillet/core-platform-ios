import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
@testable import Auth

/// Exercises the entire client stack — SessionManager → generated Connect
/// client → real ProtocolClient (Connect framing, binary proto codec) →
/// MockBFF — proving the slice works with production wire bytes, in-process.
struct AuthEndToEndTests {
    private func makeBFF(accessTokenLifetimeSeconds: Int64) -> MockBFF {
        let bff = MockBFF()
        MockAuthService(accessTokenLifetimeSeconds: accessTokenLifetimeSeconds).register(on: bff)
        return bff
    }

    private func makeManager(bff: MockBFF, store: InMemorySessionStore) -> SessionManager {
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return SessionManager(
            authClient: Auth_V1_AuthServiceClient(client: client),
            store: store,
            configuration: .init(deviceID: "e2e-device")
        )
    }

    private func makeStack(
        accessTokenLifetimeSeconds: Int64 = 900
    ) -> (SessionManager, InMemorySessionStore) {
        let store = InMemorySessionStore()
        let manager = makeManager(bff: makeBFF(accessTokenLifetimeSeconds: accessTokenLifetimeSeconds), store: store)
        return (manager, store)
    }

    @Test func fullLoginRefreshLogoutLifecycle() async throws {
        let (manager, store) = makeStack(accessTokenLifetimeSeconds: 0) // expires immediately

        // Login with the fixture credentials over real Connect framing.
        try await manager.login(
            username: MockAuthService.defaultCredentials.username,
            password: MockAuthService.defaultCredentials.password
        )
        #expect(await manager.currentState() == .authenticated(AccountID(MockAuthService.accountID)))
        let initialRefreshToken = try #require(try store.load()?.refreshToken)

        // The zero-lifetime access token forces a real Refresh round-trip,
        // which must rotate the refresh token per the contract.
        let refreshed = try #require(try await manager.validAccessToken())
        #expect(refreshed.hasPrefix("at-"))
        let rotated = try #require(try store.load()?.refreshToken)
        #expect(rotated != initialRefreshToken)

        await manager.logout()
        #expect(await manager.currentState() == .unauthenticated)
    }

    /// #486: logging out revokes the session ON THE SERVER, through an edge
    /// that — like the fleet's — refuses `Logout` without the session's
    /// bearer. Proven by the server refusing the session's refresh token
    /// afterwards; with a bare `Logout` the refresh still worked.
    @Test(arguments: [900, 0] as [Int64])
    func logoutRevokesTheSessionThroughTheEdge(accessTokenLifetimeSeconds: Int64) async throws {
        let bff = makeBFF(accessTokenLifetimeSeconds: accessTokenLifetimeSeconds)
        bff.enforcesEdgePolicy = true
        let store = InMemorySessionStore()
        let manager = makeManager(bff: bff, store: store)
        try await manager.login(
            username: MockAuthService.defaultCredentials.username,
            password: MockAuthService.defaultCredentials.password
        )
        let session = try #require(try store.load())

        await manager.logout()

        let logout = try #require(bff.recordedRequests.last { $0.path == "/auth.v1.AuthService/Logout" })
        #expect(logout.headers["Authorization"]?.first?.hasPrefix("Bearer at-") == true)
        // Whichever refresh token the session last held, the server no
        // longer honours it: the session is over there too.
        let auth = Auth_V1_AuthServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        )
        var refresh = Auth_V1_RefreshRequest()
        refresh.refreshToken = session.refreshToken
        let response = await auth.refresh(request: refresh, headers: [:])
        #expect(response.error?.code == .unauthenticated)
    }

    /// Guest mode B1 end to end: a guest reads public content through an edge
    /// that — like the fleet's — refuses an anonymous read, with the guest
    /// token `SessionManager` starts on the first read; a write stays refused.
    @Test func aGuestReadsThroughTheEdgeWithAGuestToken() async throws {
        let backend = MockBackend(enforcesEdgePolicy: true)
        let manager = SessionManager(
            authClient: Auth_V1_AuthServiceClient(
                client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: backend.bff)
            ),
            store: InMemorySessionStore(),
            configuration: .init(deviceID: "e2e-device"),
            guest: GuestSessionContext(store: InMemorySessionStore())
        )
        let reads = ConnectClientFactory.makeAuthenticated(
            host: "https://mock.bff.local", tokenProvider: manager, httpClient: backend.bff
        )
        var getPost = Post_V1_GetPostRequest()
        getPost.postID = backend.dataset.posts[0].postID

        let read = await Post_V1_PostServiceClient(client: reads).getPost(request: getPost, headers: [:])
        #expect(read.error == nil)
        let token = try #require(try await manager.validAccessToken())
        #expect(token.hasPrefix("gt-"))
        #expect(await manager.currentState() == .unauthenticated)

        var like = Engagement_V1_UpsertReactionRequest()
        like.postID = getPost.postID
        like.kind = .heart
        let write = await Engagement_V1_EngagementServiceClient(client: reads).upsertReaction(request: like, headers: [:])
        #expect(write.error?.code == .unauthenticated, "a guest token is a read pass")
    }

    // MARK: - Codes and sign-up (guest mode B4, #449)

    private struct SignUpStack {
        let backend: MockBackend
        let manager: SessionManager
        let guestStore: InMemorySessionStore
        let authService: MockAuthService
    }

    /// A guest (with a guest session) against an edge like the fleet's.
    private func makeSignUpStack() async throws -> SignUpStack {
        let backend = MockBackend(enforcesEdgePolicy: true)
        let authService = MockAuthService()
        authService.register(on: backend.bff) // the stack's own, to read back what it was sent
        let guestStore = InMemorySessionStore()
        let manager = SessionManager(
            authClient: Auth_V1_AuthServiceClient(
                client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: backend.bff)
            ),
            store: InMemorySessionStore(),
            configuration: .init(deviceID: "e2e-device"),
            guest: GuestSessionContext(store: guestStore)
        )
        #expect(try await manager.validAccessToken()?.hasPrefix("gt-") == true, "starts as a guest")
        return SignUpStack(backend: backend, manager: manager, guestStore: guestStore, authService: authService)
    }

    private func adult() -> SignUpDetails {
        SignUpDetails(
            dateOfBirth: DateComponents(year: 1990, month: 4, day: 12),
            policyVersion: "2026-10", marketing: false, analytics: true, homeCountry: "FR"
        )
    }

    @Test func aCodeSignsAnExistingAccountInAndEndsTheGuestSession() async throws {
        let stack = try await makeSignUpStack()
        let guestRefresh = try #require(try stack.guestStore.load()?.refreshToken)
        let challenge = try await stack.manager.startVerification(.email, to: MockAuthService.demoEmail)
        #expect(challenge.channel == .email && challenge.resendAfter > 0)

        let outcome = try await stack.manager.signIn(challengeID: challenge.id, code: MockAuthService.verificationCode)

        #expect(outcome == .signedIn)
        #expect(await stack.manager.currentState() == .authenticated(AccountID(MockAuthService.accountID)))
        #expect(try await stack.manager.validAccessToken()?.hasPrefix("at-") == true)
        #expect(try stack.guestStore.load() == nil, "the guest became the member")
        // The server ended the guest session it was handed.
        var refresh = Auth_V1_RefreshRequest()
        refresh.refreshToken = guestRefresh
        let auth = Auth_V1_AuthServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: stack.backend.bff)
        )
        #expect(await auth.refresh(request: refresh, headers: [:]).error?.code == .unauthenticated)
    }

    /// The whole sign-up: a new address, the steps' answers, a profile made
    /// with the pending account's token — and only then a member.
    @Test func aNewAddressSignsUpThenBecomesAMemberOnceItHasAProfile() async throws {
        let stack = try await makeSignUpStack()
        let challenge = try await stack.manager.startVerification(.email, to: "new.person@example.com")
        #expect(try await stack.manager.signIn(challengeID: challenge.id, code: MockAuthService.verificationCode) == .needsSignUp)

        let outcome = try await stack.manager.signUp(
            challengeID: challenge.id, code: MockAuthService.verificationCode, details: adult()
        )
        guard case .created(let pending) = outcome else {
            Issue.record("expected a created account, got \(outcome)")
            return
        }
        #expect(await stack.manager.currentState() == .unauthenticated, "no profile yet: not the app's member")
        let sent = try #require(stack.authService.lastSignUpRequest)
        #expect(sent.dateOfBirth == "1990-04-12")
        #expect(sent.consent.dataProcessing && sent.consent.analytics && !sent.consent.marketing)
        #expect(sent.consent.policyVersion == "2026-10" && sent.homeCountry == "FR")
        #expect(!sent.guestRefreshToken.isEmpty, "the guest session went along")

        var create = Profile_V1_CreateProfileRequest()
        create.accountID = pending.accountID.rawValue
        create.handle = "new.person"
        create.displayName = "New Person"
        let profiles = Profile_V1_ProfileServiceClient(
            client: ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: stack.backend.bff)
        )
        let created = await profiles.createProfile(
            request: create, headers: ["Authorization": ["Bearer \(pending.accessToken)"]]
        )
        #expect(created.error == nil)

        try await stack.manager.completeSignUp(pending)
        #expect(await stack.manager.currentState() == .authenticated(pending.accountID))
        #expect(try stack.guestStore.load() == nil)
    }

    @Test func underThirteenCreatesNothing() async throws {
        let stack = try await makeSignUpStack()
        let challenge = try await stack.manager.startVerification(.sms, to: "+33612345678")
        var young = adult()
        young.dateOfBirth = DateComponents(year: Calendar.current.component(.year, from: Date()) - 10, month: 1, day: 1)
        await #expect(throws: AuthError.underMinimumAge) {
            try await stack.manager.signUp(challengeID: challenge.id, code: MockAuthService.verificationCode, details: young)
        }
        #expect(await stack.manager.currentState() == .unauthenticated)
    }

    @Test func anAddressThatSignsInWithAppleSaysSo() async throws {
        let stack = try await makeSignUpStack()
        let challenge = try await stack.manager.startVerification(.email, to: MockAuthService.appleEmail)
        let outcome = try await stack.manager.signUp(
            challengeID: challenge.id, code: MockAuthService.verificationCode, details: adult()
        )
        #expect(outcome == .existingAccount(.apple))
    }

    @Test func aWrongCodeIsRefused() async throws {
        let stack = try await makeSignUpStack()
        let challenge = try await stack.manager.startVerification(.email, to: MockAuthService.demoEmail)
        await #expect(throws: AuthError.invalidCode) {
            try await stack.manager.signIn(challengeID: challenge.id, code: "000000")
        }
    }

    @Test func wrongPasswordFailsWithInvalidCredentials() async {
        let (manager, _) = makeStack()

        await #expect(throws: AuthError.invalidCredentials) {
            try await manager.login(username: "demo", password: "not-the-password")
        }
        #expect(await manager.currentState() == .unauthenticated)
    }

    @Test func replayingRotatedRefreshTokenRevokesSession() async throws {
        let bff = makeBFF(accessTokenLifetimeSeconds: 0)
        let store = InMemorySessionStore()
        let manager = makeManager(bff: bff, store: store)

        try await manager.login(
            username: MockAuthService.defaultCredentials.username,
            password: MockAuthService.defaultCredentials.password
        )
        let preRotationSession = try #require(try store.load())

        // Legitimate refresh rotates the token server-side.
        _ = try await manager.validAccessToken()
        let currentSession = try #require(try store.load())
        #expect(currentSession.refreshToken != preRotationSession.refreshToken)

        // A second client replaying the pre-rotation token (hijack or bug)
        // must be rejected AND revoke the whole session generation…
        let replayStore = InMemorySessionStore(session: preRotationSession)
        let replayManager = makeManager(bff: bff, store: replayStore)
        await #expect(throws: AuthError.sessionExpired) {
            try await replayManager.validAccessToken()
        }

        // …so even the legitimate holder of the current token is now signed out.
        let victimStore = InMemorySessionStore(session: currentSession)
        let victimManager = makeManager(bff: bff, store: victimStore)
        await #expect(throws: AuthError.sessionExpired) {
            try await victimManager.validAccessToken()
        }
        #expect(try victimStore.load() == nil)
    }
}
