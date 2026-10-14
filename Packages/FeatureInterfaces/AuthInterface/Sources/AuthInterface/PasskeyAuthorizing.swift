import AuthenticationServices
import UIKit

/// What the server asks the platform authenticator to create (#551, backend
/// #808 — WebAuthn `PublicKeyCredentialCreationOptions`): ES256, a
/// discoverable credential, user verification required, no attestation.
/// Binary values already decoded from the contract's base64url.
public struct PasskeyCreationRequest: Equatable, Sendable {
    /// The challenge as the server sent it (base64url) — echoed back on finish.
    public let challenge: String
    public let challengeData: Data
    public let relyingPartyID: String
    public let userID: Data
    /// Shown by the authenticator: the account's email or phone.
    public let userName: String
    /// The account's passkeys, so the authenticator does not make a second one.
    public let excludedCredentialIDs: [Data]

    public init(
        challenge: String, challengeData: Data, relyingPartyID: String, userID: Data,
        userName: String, excludedCredentialIDs: [Data]
    ) {
        self.challenge = challenge
        self.challengeData = challengeData
        self.relyingPartyID = relyingPartyID
        self.userID = userID
        self.userName = userName
        self.excludedCredentialIDs = excludedCredentialIDs
    }
}

/// The authenticator's answer, raw, for `FinishPasskeyRegistration`.
public struct PasskeyAttestation: Equatable, Sendable {
    public let clientDataJSON: Data
    public let attestationObject: Data

    public init(clientDataJSON: Data, attestationObject: Data) {
        self.clientDataJSON = clientDataJSON
        self.attestationObject = attestationObject
    }
}

/// What the server asks the authenticator to sign, to sign in (#551 —
/// `PublicKeyCredentialRequestOptions`): any of the device's passkeys for
/// the relying party (discoverable, no allow list), user verification
/// required.
public struct PasskeyAssertionRequest: Equatable, Sendable {
    /// As the server sent it (base64url) — echoed back with the assertion.
    public let challenge: String
    public let challengeData: Data
    public let relyingPartyID: String

    public init(challenge: String, challengeData: Data, relyingPartyID: String) {
        self.challenge = challenge
        self.challengeData = challengeData
        self.relyingPartyID = relyingPartyID
    }
}

/// The authenticator's signature over a challenge, raw — what `Login`,
/// `CompleteLogin` and `VerifyCredentials` take as `passkey`.
public struct PasskeyAssertion: Equatable, Sendable {
    public let challenge: String
    public let credentialID: Data
    public let clientDataJSON: Data
    public let authenticatorData: Data
    public let signature: Data
    /// The account's WebAuthn user id the passkey was made with: it names
    /// the account at sign-in.
    public let userHandle: Data

    public init(
        challenge: String, credentialID: Data, clientDataJSON: Data, authenticatorData: Data,
        signature: Data, userHandle: Data
    ) {
        self.challenge = challenge
        self.credentialID = credentialID
        self.clientDataJSON = clientDataJSON
        self.authenticatorData = authenticatorData
        self.signature = signature
        self.userHandle = userHandle
    }
}

/// The person closed the system sheet: nothing to say.
public struct PasskeyCancelled: Error, Equatable {
    public init() {}
}

/// The platform authenticator behind a seam: the system's passkey sheet in
/// the app (`PlatformPasskeyAuthorizer`), a fake in tests — a simulator can
/// make a passkey only for a domain the app is associated with.
@MainActor
public protocol PasskeyAuthorizing: AnyObject {
    /// Asks the device to create a passkey; throws `PasskeyCancelled` when
    /// the person backs out.
    func createPasskey(_ request: PasskeyCreationRequest) async throws -> PasskeyAttestation
    /// Asks the device to sign in with one of its passkeys; throws
    /// `PasskeyCancelled` when the person backs out (or has none).
    func assertPasskey(_ request: PasskeyAssertionRequest) async throws -> PasskeyAssertion
}

/// The system's passkey sheet (`ASAuthorizationController`).
///
/// ⚠️ It only works for a relying party the app is associated with
/// (`webcredentials:<rp id>` in Associated Domains, and the domain's
/// apple-app-site-association naming the app). Without it the sheet fails
/// at once — reported as a failure, not a cancel.
@MainActor
public final class PlatformPasskeyAuthorizer: NSObject, PasskeyAuthorizing {
    private var pending: CheckedContinuation<ASAuthorization, Error>?
    /// Held while the sheet is up.
    private var controller: ASAuthorizationController?

    override public init() {}

    public func createPasskey(_ request: PasskeyCreationRequest) async throws -> PasskeyAttestation {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: request.relyingPartyID)
        let registration = provider.createCredentialRegistrationRequest(
            challenge: request.challengeData, name: request.userName, userID: request.userID
        )
        registration.userVerificationPreference = .required
        registration.excludedCredentials = request.excludedCredentialIDs.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }
        let authorization = try await perform(registration)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = credential.rawAttestationObject
        else { throw ASAuthorizationError(.failed) }
        return PasskeyAttestation(clientDataJSON: credential.rawClientDataJSON, attestationObject: attestation)
    }

    public func assertPasskey(_ request: PasskeyAssertionRequest) async throws -> PasskeyAssertion {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: request.relyingPartyID)
        let assertion = provider.createCredentialAssertionRequest(challenge: request.challengeData)
        assertion.userVerificationPreference = .required
        let authorization = try await perform(assertion)
        guard let credential = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion,
              let userHandle = credential.userID
        else { throw ASAuthorizationError(.failed) }
        return PasskeyAssertion(
            challenge: request.challenge, credentialID: credential.credentialID,
            clientDataJSON: credential.rawClientDataJSON, authenticatorData: credential.rawAuthenticatorData,
            signature: credential.signature, userHandle: userHandle
        )
    }

    private func perform(_ request: ASAuthorizationRequest) async throws -> ASAuthorization {
        // One sheet at a time: a second tap while one is up is dropped.
        guard pending == nil else { throw PasskeyCancelled() }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            controller.performRequests()
        }
    }

    private func finish(_ result: Result<ASAuthorization, Error>) {
        let continuation = pending
        pending = nil
        controller = nil
        continuation?.resume(with: result)
    }
}

extension PlatformPasskeyAuthorizer: ASAuthorizationControllerDelegate {
    public nonisolated func authorizationController(
        controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        MainActor.assumeIsolated { finish(.success(authorization)) }
    }

    public nonisolated func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        // Cancelled, or no passkey on this device for the relying party
        // (the sheet then has nothing to offer): both say nothing.
        let code = (error as? ASAuthorizationError)?.code
        let cancelled = code == .canceled || code == .notInteractive
        MainActor.assumeIsolated { finish(.failure(cancelled ? PasskeyCancelled() : error)) }
    }
}

extension PlatformPasskeyAuthorizer: ASAuthorizationControllerPresentationContextProviding {
    public nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }
}

/// A stand-in for the system sheet where it cannot work — the mock
/// backend's made-up relying party, the simulator without an associated
/// domain, tests: answers at once with bytes of its own, a new
/// "authenticator" each time.
@MainActor
public final class SimulatedPasskeyAuthorizer: PasskeyAuthorizing {
    /// What the next answer is: nil makes one; `PasskeyCancelled` acts out
    /// the person backing out.
    public var nextError: Error?
    public private(set) var requests: [PasskeyCreationRequest] = []
    /// What a sign-in signs with: the passkey the server knows (the mock's
    /// seeded one) and its account's user id.
    public var signInCredentialID: Data
    public var signInUserHandle: Data

    public init(signInCredentialID: Data = Data(), signInUserHandle: Data = Data()) {
        self.signInCredentialID = signInCredentialID
        self.signInUserHandle = signInUserHandle
    }

    public func createPasskey(_ request: PasskeyCreationRequest) async throws -> PasskeyAttestation {
        requests.append(request)
        if let error = nextError {
            nextError = nil
            throw error
        }
        let client = Data(#"{"type":"webauthn.create","challenge":"\#(request.challenge)"}"#.utf8)
        return PasskeyAttestation(clientDataJSON: client, attestationObject: Data(UUID().uuidString.utf8))
    }

    public func assertPasskey(_ request: PasskeyAssertionRequest) async throws -> PasskeyAssertion {
        if let error = nextError {
            nextError = nil
            throw error
        }
        let client = Data(#"{"type":"webauthn.get","challenge":"\#(request.challenge)"}"#.utf8)
        return PasskeyAssertion(
            challenge: request.challenge, credentialID: signInCredentialID, clientDataJSON: client,
            authenticatorData: Data(repeating: 0, count: 37), signature: Data(UUID().uuidString.utf8),
            userHandle: signInUserHandle
        )
    }
}

extension Data {
    /// base64url, padding optional — how auth.v1 carries a passkey's binary
    /// values (none padded).
    public init?(base64URL text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }

    /// base64url without padding.
    public var base64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
