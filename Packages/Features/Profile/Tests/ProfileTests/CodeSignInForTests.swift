import Connect
import CoreContracts
import CoreNetworking
import CoreNetworkingMocks
import Foundation
@testable import Profile

/// How a test signs the demo account in since passwords went (#840): a code
/// to its address, then `Login` with it.
enum MockCodeSignIn {
    static func login(_ anonymous: Auth_V1_AuthServiceClient) async -> Auth_V1_LoginResponse? {
        var start = Auth_V1_StartVerificationRequest()
        start.channel = .email
        start.destination = MockAuthService.demoEmail
        guard let challenge = try? await anonymous.startVerification(request: start, headers: [:]).result.get() else {
            return nil
        }
        var grant = Auth_V1_VerificationCodeGrant()
        grant.challengeID = challenge.challengeID
        grant.code = MockAuthService.verificationCode
        var request = Auth_V1_LoginRequest()
        request.grantType = .verificationCode
        request.credential = .verificationCode(grant)
        return try? await anonymous.login(request: request, headers: [:]).result.get()
    }
}

/// What the app's `SessionManager` does for a reconfirmation (#840), over
/// the raw client: signs in again with the code and hands the fresh access
/// token to the test's session.
actor CodeReauthenticator: SessionReauthenticating {
    private let anonymous: Auth_V1_AuthServiceClient
    private let session: any AccessTokenInstalling & AuthTokenProviding

    init(anonymous: Auth_V1_AuthServiceClient, session: any AccessTokenInstalling & AuthTokenProviding) {
        self.anonymous = anonymous
        self.session = session
    }

    func reauthenticate(challengeID: String, code: String) async throws -> ReauthenticationResult {
        var grant = Auth_V1_VerificationCodeGrant()
        grant.challengeID = challengeID
        grant.code = code
        var request = Auth_V1_LoginRequest()
        request.grantType = .verificationCode
        request.credential = .verificationCode(grant)
        switch await anonymous.login(request: request, headers: [:]).result {
        case .success(let body) where body.mfaRequired:
            return .needsSecondStep(token: body.mfaToken, expiresIn: TimeInterval(body.mfaExpiresIn))
        case .success(let body):
            await adopt(body.tokens)
            return .done
        case .failure:
            throw StepUpError.wrongCode
        }
    }

    func completeReauthentication(secondStepToken: String, expiresIn: TimeInterval, code: String) async throws {
        var request = Auth_V1_CompleteLoginRequest()
        request.mfaToken = secondStepToken
        request.code = code
        switch await anonymous.completeLogin(request: request, headers: [:]).result {
        case .success(let body):
            await adopt(body.tokens)
        case .failure:
            throw StepUpError.wrongCode
        }
    }

    /// As `SessionManager` does: the session the fresh one replaces ends.
    private func adopt(_ tokens: Auth_V1_TokenPair) async {
        if let previous = try? await session.validAccessToken() {
            _ = await anonymous.logout(request: Auth_V1_LogoutRequest(), headers: ["Authorization": ["Bearer \(previous)"]])
        }
        await session.installStepUpToken(tokens.accessToken, expiresIn: tokens.expiresIn)
    }
}

extension AccountSessionsRepository {
    /// The step-up a destructive action asks for when two-step is off: the
    /// code sent to the account's address (#840).
    func reconfirmWithTheSentCode(_ code: String = MockAuthService.verificationCode) async throws {
        let reconfirmation = try await sendReconfirmationCode()
        if try await reconfirm(reconfirmation, code: code) == .needsSecondStep {
            try await completeReconfirmation(secondStepCode: MockAuthService.verificationCode)
        }
    }
}
