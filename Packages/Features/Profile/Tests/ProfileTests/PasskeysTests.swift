import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Security and Login → Passkeys (#551, backend #808), end to end
/// over the mock: the list, adding behind a step-up, removing, and the
/// feature hidden when the server has none.
@MainActor
struct PasskeysTests {
    private actor Session: AuthTokenProviding, AccessTokenInstalling, AuthSessionProviding {
        var token: String?
        func set(_ value: String) { token = value }
        func validAccessToken() async throws -> String? { token }
        func installStepUpToken(_ accessToken: String, expiresIn: Int64) async { token = accessToken }
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
    }

    private func repository(passkeysUnavailable: Bool = false) async throws -> AccountSessionsRepository {
        let bff = MockBFF()
        let lifecycle = MockAccountLifecycle()
        MockAuthService(lifecycle: lifecycle, passkeysUnavailable: passkeysUnavailable).register(on: bff)
        MockAccountService(lifecycle: lifecycle).register(on: bff)
        let host = "https://mock.bff.local"
        let anonymous = Auth_V1_AuthServiceClient(client: ConnectClientFactory.makeUnauthenticated(host: host, httpClient: bff))
        let first = try #require(await MockCodeSignIn.login(anonymous))
        let session = Session()
        await session.set(first.tokens.accessToken)
        // The sign-in that minted it was long ago: a gated call needs a
        // fresh proof.
        lifecycle.forgetRecentProofs()
        let client = ConnectClientFactory.makeAuthenticated(host: host, tokenProvider: session, httpClient: bff)
        let account = AccountRepository(accountClient: Account_V1_AccountServiceClient(client: client), authSession: session)
        return AccountSessionsRepository(
            authClient: Auth_V1_AuthServiceClient(client: client), tokenInstaller: session,
            account: account, reauthenticator: CodeReauthenticator(anonymous: anonymous, session: session)
        )
    }

    /// Done when: the list shows each passkey's name, when it was added and
    /// last used, without a step-up.
    @Test func theListNeedsNoStepUp() async throws {
        let sessions = try await repository()
        let passkeys = try await sessions.listPasskeys()
        let seeded = try #require(passkeys.first)
        #expect(passkeys.count == 1)
        #expect(seeded.id == MockAuthService.seededPasskeyID)
        #expect(seeded.name == "iCloud Keychain")
        #expect(seeded.createdAt != nil && seeded.lastUsedAt != nil)
        #expect(seeded.synced)
        #expect(await sessions.passkeysAvailable())
    }

    /// Done when: adding one needs a recent proof, sends the authenticator
    /// the server's options decoded from base64url, and lists the new one.
    @Test func addingNeedsAStepUpThenTheAuthenticatorsAnswer() async throws {
        let sessions = try await repository()
        await #expect(throws: PasskeyError.stepUpRequired) { _ = try await sessions.startPasskeyRegistration() }

        try await sessions.reconfirmWithTheSentCode()
        let request = try await sessions.startPasskeyRegistration()
        #expect(request.relyingPartyID == MockAuthService.passkeyRelyingParty)
        #expect(request.userID == Data(MockAuthService.accountID.utf8))
        #expect(request.userName == MockAuthService.demoEmail)
        #expect(request.excludedCredentialIDs.count == 1)
        #expect(String(decoding: request.challengeData, as: UTF8.self).hasPrefix("passkey-challenge-"))

        let authorizer = SimulatedPasskeyAuthorizer()
        let attestation = try await authorizer.createPasskey(request)
        let added = try await sessions.finishPasskeyRegistration(request, attestation: attestation, name: "My iPhone")
        #expect(added.name == "My iPhone")
        #expect(added.lastUsedAt == nil)
        #expect(try await sessions.listPasskeys().map(\.id).contains(added.id))

        // A challenge is single use.
        await #expect(throws: PasskeyError.restart) {
            _ = try await sessions.finishPasskeyRegistration(request, attestation: attestation, name: "")
        }
        // The same authenticator twice.
        let again = try await sessions.startPasskeyRegistration()
        await #expect(throws: PasskeyError.alreadyRegistered) {
            _ = try await sessions.finishPasskeyRegistration(again, attestation: attestation, name: "")
        }
    }

    /// Done when: removing one needs a recent proof and leaves the others;
    /// removing it twice says it is gone.
    @Test func removingNeedsAStepUp() async throws {
        let sessions = try await repository()
        await #expect(throws: PasskeyError.stepUpRequired) {
            _ = try await sessions.removePasskey(id: MockAuthService.seededPasskeyID)
        }
        try await sessions.reconfirmWithTheSentCode()
        #expect(try await sessions.removePasskey(id: MockAuthService.seededPasskeyID).isEmpty)
        await #expect(throws: PasskeyError.notFound) {
            _ = try await sessions.removePasskey(id: MockAuthService.seededPasskeyID)
        }
    }

    /// Done when: a server without passkeys hides the feature.
    @Test func unavailableHidesTheFeature() async throws {
        let sessions = try await repository(passkeysUnavailable: true)
        await #expect(throws: PasskeyError.unavailable) { _ = try await sessions.listPasskeys() }
        #expect(await !sessions.passkeysAvailable())
    }

    @Test func base64URLRoundTrips() {
        let bytes = Data([0xFB, 0xFF, 0x00, 0x3E, 0x3F])
        #expect(bytes.base64URLString == "-_8APj8")
        #expect(Data(base64URL: "-_8APj8") == bytes)
        #expect(Data(base64URL: "not base64!") == nil)
    }

    // MARK: - The screen's model

    @Test func theScreenAddsAndRemovesOnceSteppedUp() async throws {
        let sessions = try await repository()
        let authorizer = SimulatedPasskeyAuthorizer()
        let model = PasskeysModel(manager: sessions, authorizer: authorizer)
        await model.load()
        #expect(model.phase.passkeys?.count == 1)

        #expect(await model.add() == .needsStepUp)
        #expect(authorizer.requests.isEmpty, "no sheet before the server agreed")
        try await sessions.reconfirmWithTheSentCode()

        authorizer.nextError = PasskeyCancelled()
        #expect(await model.add() == .cancelled)
        #expect(model.phase.passkeys?.count == 1)

        #expect(await model.add() == .done)
        let added = try #require(model.phase.passkeys?.last)
        #expect(added.name == PasskeysModel.newPasskeyName)

        #expect(await model.remove(added) == .done)
        #expect(model.phase.passkeys?.map(\.id) == [MockAuthService.seededPasskeyID])
        // Gone already: the list catches up and the screen says so.
        #expect(await model.remove(added) == .failed(PasskeysModel.failureMessage(PasskeyError.notFound)))
    }

    @Test func theScreenSaysWhenPasskeysAreUnavailable() async throws {
        let model = PasskeysModel(
            manager: try await repository(passkeysUnavailable: true), authorizer: SimulatedPasskeyAuthorizer()
        )
        await model.load()
        #expect(model.phase == .unavailable)
    }

    @Test func theSubtitleSaysWhenItWasAddedAndUsed() {
        let now = Date()
        let used = PasskeySummary(
            id: "a", name: "Key", createdAt: now.addingTimeInterval(-86_400 * 30),
            lastUsedAt: now.addingTimeInterval(-86_400), synced: true
        )
        let fresh = PasskeySummary(id: "b", name: "Key", createdAt: now, lastUsedAt: nil, synced: true)
        #expect(PasskeysViewController.subtitle(for: used, now: now).hasPrefix("Added "))
        #expect(PasskeysViewController.subtitle(for: used, now: now).contains("Last used "))
        #expect(PasskeysViewController.subtitle(for: fresh, now: now).hasSuffix("Never used"))
    }
}

private extension PasskeysModel.Phase {
    var passkeys: [PasskeySummary]? {
        if case .loaded(let passkeys) = self { passkeys } else { nil }
    }
}
