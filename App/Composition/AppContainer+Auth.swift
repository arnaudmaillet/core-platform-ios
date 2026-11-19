import Auth
import AuthInterface
import Connect
import CoreContracts
import CoreNetworkingMocks
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
        AuthFeatureBuilder(
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
        )
    }

    /// The device's passkeys (#551): the system sheet on the fleet. The mock's
    /// relying party is made up and no device is associated with it — the
    /// system sheet would fail at once — so mock mode simulates the
    /// authenticator, signing in with the mock's seeded passkey.
    @MainActor
    static func makePasskeyAuthorizer(for environment: AppEnvironment) -> any PasskeyAuthorizing {
        switch environment {
        case .mock:
            SimulatedPasskeyAuthorizer(
                signInCredentialID: Data(base64URL: MockAuthService.seededPasskeyID) ?? Data(),
                signInUserHandle: Data(MockAuthService.accountID.utf8)
            )
        case .localFleet:
            PlatformPasskeyAuthorizer()
        }
    }

    /// Sign in with Apple's sheet (#507); `-mock-apple-sign-in <email>` skips
    /// it in DEBUG.
    private func federatedSignIn() -> any FederatedSignInProviding {
        #if DEBUG
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
