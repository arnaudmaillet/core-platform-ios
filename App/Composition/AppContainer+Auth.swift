import Auth
import AuthInterface
import Connect
import CoreContracts
#if MOCK_BACKEND
import CoreNetworkingMocks
#endif
import Foundation
import Maps
import ProfileData
import SettingsInterface
import UIKit

// Auth (#2375): the sign-in feature, its passkeys and federated sign-in, and
// the session manager's step-up conformances. Its properties are declared in
// `AppContainer.swift`, since an extension holds no stored property; they are
// built here.
extension AppContainer {
    func makeAuthFeature() -> any AuthFeatureBuilding {
        AuthFeatureBuilder(dependencies: .init(
            sessionManager: sessionManager,
            // Sign-up by code (guest mode B4): the new account's profile, and its
            // home country — the country location opened, else the storefront's.
            profileSetup: AccountProfileSetupService(
                profileClient: Profile_V1_ProfileServiceClient(client: authenticatedRPCClient)
            ),
            homeCountry: { [weak self] in
                await self?.currentCountry.currentCountry ?? Locale.current.region?.identifier ?? ""
            },
            federated: federatedSignIn(),
            passkeys: { [environment] in Self.makePasskeyAuthorizer(for: environment) },
            // The sign-in sheet's legal line (#1811): Settings → Support and
            // Legal's own pages, nil (plain text) while they have no address.
            legalLinks: AuthLegalLinks(
                termsOfService: SettingsLinks.current.termsOfService,
                privacyPolicy: SettingsLinks.current.privacyPolicy
            )
        ))
    }

    /// The device's passkeys (#551): the system sheet on the fleet. The mock's
    /// relying party is made up and no device is associated with it — the
    /// system sheet would fail at once — so mock mode simulates the
    /// authenticator, signing in with the mock's seeded passkey.
    @MainActor
    static func makePasskeyAuthorizer(for environment: AppEnvironment) -> any PasskeyAuthorizing {
        switch environment {
        #if MOCK_BACKEND
        case .mock:
            SimulatedPasskeyAuthorizer(
                signInCredentialID: Data(base64URL: MockAuthService.seededPasskeyID) ?? Data(),
                signInUserHandle: Data(MockAuthService.accountID.utf8)
            )
        #endif
        case .remote:
            PlatformPasskeyAuthorizer()
        }
    }

    /// The session as the shell reads it: its states, its sign-out and the
    /// notices it gives once after a sign-in (#2375). The shell names no
    /// type of the auth feature's.
    var authSession: any AuthSessionProviding & AuthSessionNotices { sessionManager }

    /// Signs in the way a member does since passwords went (#840): a code to
    /// `email`, then `code`. Two-step on (`-mock-two-step`): the same code
    /// finishes it — the mock answers every code with one. An address with
    /// no account does nothing. The app coordinator's QA sign-ins
    /// (`-mock-auto-login`, `-guest-sign-in-after`).
    func signInWithCode(email: String, code: String) async {
        let sessionManager = sessionManager
        guard let challenge = try? await sessionManager.startVerification(.email, to: email),
              let outcome = try? await sessionManager.signIn(challengeID: challenge.id, code: code) else { return }
        switch outcome {
        case .existing(let account):
            await sessionManager.completeSignIn(account)
        case .needsSecondStep(let step):
            if let account = try? await sessionManager.completeSecondStep(step, code: code) {
                await sessionManager.completeSignIn(account)
            }
        case .needsSignUp:
            break
        }
    }

    /// Sign in with Apple's sheet (#507); `-mock-apple-sign-in <email>` skips
    /// it in DEBUG.
    private func federatedSignIn() -> any FederatedSignInProviding {
        #if MOCK_BACKEND && DEBUG
        if let mock = MockAppleSignIn.fromLaunchArguments() { return mock }
        #endif
        return AppleSignInProvider()
    }
}

/// Step-up (#648): the session manager takes a step-up's fresh access token
/// for the session it vends (Settings → deactivate, delete…).
extension SessionManager: @retroactive AccessTokenInstalling {}

/// Proving the holder again with a code (#840): the session manager signs
/// in again and adopts the fresh session.
extension SessionManager: @retroactive SessionReauthenticating {
    public func reauthenticate(challengeID: String, code: String) async throws -> ReauthenticationResult {
        do {
            switch try await reauthenticate(challengeID: challengeID, code: code) as Reauthentication {
            case .done: return .done
            case .needsSecondStep(let step): return .needsSecondStep(token: step.token, expiresIn: step.expiresIn)
            }
        } catch AuthError.invalidCode {
            throw StepUpError.wrongCode
        }
    }

    public func completeReauthentication(secondStepToken: String, expiresIn: TimeInterval, code: String) async throws {
        do {
            try await completeReauthentication(SecondStepChallenge(token: secondStepToken, expiresIn: expiresIn), code: code)
        } catch AuthError.wrongSecondStepCode {
            throw StepUpError.wrongCode
        }
    }
}
