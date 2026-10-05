import AuthenticationServices
import CryptoKit
import UIKit

/// Native Sign in with Apple (#507). Apple signs the SHA-256 hex of the
/// server's nonce into the id_token; the raw nonce goes back to the server
/// with it. Asks for the email (the account needs one) and the name (it
/// seeds the profile — Apple shares it only at the first sign-in).
@MainActor
public final class AppleSignInProvider: NSObject, FederatedSignInProviding {
    private var pending: CheckedContinuation<FederatedSignInResult, Error>?
    /// Held while Apple's sheet is up.
    private var controller: ASAuthorizationController?

    override public init() {}

    public func signIn(with provider: FederatedProvider, nonce: String) async throws -> FederatedSignInResult {
        guard provider == .apple else { throw FederatedSignInCancelled() }
        // One sheet at a time: a second tap while one is up is dropped.
        guard pending == nil else { throw FederatedSignInCancelled() }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.email, .fullName]
        request.nonce = Self.sha256Hex(nonce)
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            controller.performRequests()
        }
    }

    /// What Apple expects in `nonce`: the SHA-256 of the raw value, as
    /// lowercase hex.
    static func sha256Hex(_ raw: String) -> String {
        SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func finish(_ result: Result<FederatedSignInResult, Error>) {
        let continuation = pending
        pending = nil
        controller = nil
        continuation?.resume(with: result)
    }
}

extension AppleSignInProvider: ASAuthorizationControllerDelegate {
    public nonisolated func authorizationController(
        controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        let credential = authorization.credential as? ASAuthorizationAppleIDCredential
        let token = credential?.identityToken.flatMap { String(data: $0, encoding: .utf8) }
        let name = credential?.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
        MainActor.assumeIsolated {
            guard let token else {
                finish(.failure(AuthError.identityRejected))
                return
            }
            finish(.success(FederatedSignInResult(idToken: token, displayName: name?.isEmpty == false ? name : nil)))
        }
    }

    public nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        let cancelled = (error as? ASAuthorizationError)?.code == .canceled
        MainActor.assumeIsolated {
            finish(.failure(cancelled ? FederatedSignInCancelled() : error))
        }
    }
}

extension AppleSignInProvider: ASAuthorizationControllerPresentationContextProviding {
    public nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // The window the sign-in flow is up in: the active scene's key one.
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}
