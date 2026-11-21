#if MOCK_BACKEND && DEBUG
import Auth
import CoreNetworkingMocks
import Foundation
import LaunchArguments

/// `-mock-apple-sign-in <email>`: "Continue with Apple" skips Apple's sheet
/// (a simulator rarely has an Apple Account) and signs in as `email`, with a
/// mock id_token minted for the server's nonce. `apple@example.com` has an
/// account; any other address goes through sign-up.
struct MockAppleSignIn: FederatedSignInProviding {
    let email: String

    static func fromLaunchArguments() -> MockAppleSignIn? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let email = LaunchArgument.mockAppleSignIn.value(in: arguments) else { return nil }
        return MockAppleSignIn(email: email)
    }

    func signIn(with provider: FederatedProvider, nonce: String) async throws -> FederatedSignInResult {
        FederatedSignInResult(
            idToken: MockIdToken.make(subject: "apple-\(email)", email: email, nonce: nonce),
            displayName: "Apple Tester"
        )
    }
}
#endif
