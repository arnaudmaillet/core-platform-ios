import Auth
import Connect
import CoreContracts
import CoreModels
import Foundation

/// The profile a new account needs before it is the app's member (guest mode
/// B4, #449), over `profile.v1` — the Auth feature asks it through
/// `AccountProfileSetup` and never imports the profile contract.
struct AccountProfileSetupService: AccountProfileSetup {
    /// The app's authenticated client: a guest checks a handle with their
    /// guest token.
    let profileClient: any Profile_V1_ProfileServiceClientInterface

    func checkHandle(_ handle: String) async -> HandleCheck {
        var request = Profile_V1_CheckHandleAvailabilityRequest()
        request.handle = handle
        guard let answer = await profileClient.checkHandleAvailability(request: request, headers: [:]).message else {
            return .unknown
        }
        switch answer.availability {
        case .available: return .available(normalized: answer.handle)
        case .taken: return .taken
        case .invalid: return .invalid(reason: answer.invalidReason.isEmpty
            ? "3–30 letters, numbers, dots or underscores." : answer.invalidReason)
        default: return .unknown
        }
    }

    /// With the PENDING account's own token, sent explicitly: the app's
    /// interceptor still vends the guest's until `completeSignUp`.
    func createProfile(for account: PendingAccount, handle: String, displayName: String) async throws {
        var request = Profile_V1_CreateProfileRequest()
        request.accountID = account.accountID.rawValue
        request.handle = handle
        request.displayName = displayName.isEmpty ? handle : displayName
        request.locale = Locale.current.identifier(.bcp47)
        let response = await profileClient.createProfile(
            request: request, headers: ["Authorization": ["Bearer \(account.accessToken)"]]
        )
        if let error = response.error {
            throw AuthError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
