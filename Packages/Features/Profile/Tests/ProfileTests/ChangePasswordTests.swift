import CoreContracts
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Settings → Security and Login → Change Password (#382).
@MainActor
struct ChangePasswordTests {
    typealias Check = ChangePasswordViewController.Check

    // MARK: - The form

    @Test func theFormSaysWhatIsMissing() {
        #expect(Check(current: "", new: "longenough", confirmation: "longenough") == .incomplete)
        #expect(Check(current: "old-secret", new: "short", confirmation: "short") == .tooShort)
        #expect(Check(current: "old-secret", new: String(repeating: "a", count: 129), confirmation: "") == .tooLong)
        #expect(Check(current: "old-secret", new: "old-secret", confirmation: "old-secret") == .unchanged)
        #expect(Check(current: "old-secret", new: "new-secret-1", confirmation: "") == .incomplete)
        #expect(Check(current: "old-secret", new: "new-secret-1", confirmation: "new-secret-2") == .mismatch)
        #expect(Check(current: "old-secret", new: "new-secret-1", confirmation: "new-secret-1") == .ready)
    }

    /// Nothing is said while the viewer is still typing; a problem is said
    /// plainly.
    @Test func onlyRealProblemsGetAMessage() {
        #expect(Check.incomplete.message == nil)
        #expect(Check.ready.message == nil)
        #expect(Check.mismatch.message == "The two new passwords don't match.")
        #expect(Check.tooShort.message?.contains("8") == true)
    }

    @Test func theConfirmationCountsTheDevicesLoggedOut() {
        #expect(ChangePasswordViewController.doneMessage(revokedSessions: 0).hasPrefix("Use your new password"))
        #expect(ChangePasswordViewController.doneMessage(revokedSessions: 1).hasPrefix("1 other device was"))
        #expect(ChangePasswordViewController.doneMessage(revokedSessions: 2).hasPrefix("2 other devices were"))
    }

    /// The server's rule, without its error code, as a sentence.
    @Test func aRefusalReadsAsASentence() {
        #expect(PasswordChangeError.readable("AUT-VAL-024: the new password must be 8 to 128 characters")
            == "The new password must be 8 to 128 characters.")
        #expect(PasswordChangeError.readable("AUT-5006: Password policy not met: uppercase.") == "Password policy not met: uppercase.")
        #expect(PasswordChangeError.readable(nil) == "Choose a different password.")
    }

    // MARK: - Over the mock

    private actor Token: AuthTokenProviding {
        var value: String?
        func set(_ token: String) { value = token }
        func validAccessToken() async throws -> String? { value }
    }

    /// Signs in through the mock and returns a repository on a client that
    /// carries that session's token, plus a way to try a login.
    private func signedIn() async throws -> (AccountSessionsRepository, (String) async -> Bool) {
        let bff = MockBFF()
        MockAuthService().register(on: bff)
        let host = "https://mock.bff.local"
        let anonymous = Auth_V1_AuthServiceClient(client: ConnectClientFactory.makeUnauthenticated(host: host, httpClient: bff))
        func login(_ password: String) async -> String? {
            var grant = Auth_V1_PasswordGrant()
            grant.username = MockAuthService.defaultCredentials.username
            grant.password = password
            var request = Auth_V1_LoginRequest()
            request.grantType = .password
            request.credential = .password(grant)
            return try? await anonymous.login(request: request, headers: [:]).result.get().tokens.accessToken
        }
        let token = Token()
        let access = try #require(await login(MockAuthService.defaultCredentials.password))
        await token.set(access)
        let client = ConnectClientFactory.makeAuthenticated(host: host, tokenProvider: token, httpClient: bff)
        let repository = AccountSessionsRepository(authClient: Auth_V1_AuthServiceClient(client: client))
        return (repository, { await login($0) != nil })
    }

    @Test func aWrongCurrentPasswordIsSaidAsSuch() async throws {
        let (repository, _) = try await signedIn()
        await #expect(throws: PasswordChangeError.wrongCurrentPassword) {
            _ = try await repository.changePassword(current: "nope", new: "brand-new-secret", signOutOtherSessions: false)
        }
    }

    @Test func aRefusedNewPasswordCarriesTheRule() async throws {
        let (repository, _) = try await signedIn()
        do {
            _ = try await repository.changePassword(
                current: MockAuthService.defaultCredentials.password, new: "short", signOutOtherSessions: false
            )
            Issue.record("expected a refusal")
        } catch let PasswordChangeError.rejected(reason) {
            #expect(reason.contains("8 to 128"))
        }
    }

    /// The new password is the one that signs in afterwards, and the other
    /// devices (two seeded) are logged out when asked.
    @Test func theNewPasswordSignsInAndTheOthersAreLoggedOut() async throws {
        let (repository, canLogIn) = try await signedIn()
        let revoked = try await repository.changePassword(
            current: MockAuthService.defaultCredentials.password, new: "brand-new-secret", signOutOtherSessions: true
        )
        #expect(revoked == 2)
        // This device stays signed in; the seeded others are gone. (Checked
        // before logging in again, which opens a session of its own.)
        let sessions = try await repository.activeSessions()
        #expect(sessions.map(\.isCurrent) == [true])
        #expect(await canLogIn("brand-new-secret"))
        #expect(await !canLogIn(MockAuthService.defaultCredentials.password))
    }
}
