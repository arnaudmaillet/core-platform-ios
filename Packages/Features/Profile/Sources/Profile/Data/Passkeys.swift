import AuthInterface
import Connect
import CoreContracts
import CoreNetworking
import Foundation

/// One of the account's passkeys, as Settings → Security and Login →
/// Passkeys lists it (#551, backend #808).
public struct PasskeySummary: Hashable, Sendable, Identifiable {
    /// The credential id, base64url without padding — what removing it names.
    public let id: String
    public let name: String
    public let createdAt: Date?
    /// Nil until it first signs in.
    public let lastUsedAt: Date?
    /// Synced across the holder's devices (iCloud Keychain).
    public let synced: Bool

    public init(id: String, name: String, createdAt: Date?, lastUsedAt: Date?, synced: Bool) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.synced = synced
    }
}

public enum PasskeyError: Error, Equatable {
    /// The server has no relying party configured (UNAVAILABLE): the app
    /// hides the feature rather than offering what cannot work.
    case unavailable
    /// The action needs a fresh step-up first (PERMISSION_DENIED
    /// "step_up_required").
    case stepUpRequired
    /// The registration expired or was interrupted: start again (AUT-5023).
    case restart
    /// The authenticator's answer was not accepted (AUT-5024).
    case notAccepted
    /// Ten passkeys already (AUT-5025).
    case limitReached
    /// This authenticator already holds one for the account (AUT-5026).
    case alreadyRegistered
    /// Already removed, somewhere else (AUT-5027): the list is stale.
    case notFound
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794).
    case transport(message: String, failure: NetworkFailure? = nil)
}

extension PasskeyError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
}

/// Settings → Security and Login → Passkeys (#551). Starting a registration
/// and removing one need a recent step-up (`CredentialStepUp`).
public protocol PasskeysManaging: Sendable {
    func listPasskeys() async throws -> [PasskeySummary]
    func startPasskeyRegistration() async throws -> PasskeyCreationRequest
    /// `name` empty: the server names it "Passkey".
    func finishPasskeyRegistration(
        _ request: PasskeyCreationRequest, attestation: PasskeyAttestation, name: String
    ) async throws -> PasskeySummary
    /// The passkeys left.
    func removePasskey(id: String) async throws -> [PasskeySummary]
}

extension PasskeysManaging {
    /// False only when the server has no passkeys (UNAVAILABLE). Any other
    /// failure says yes: the screen it leads to says what went wrong.
    public func passkeysAvailable() async -> Bool {
        do {
            _ = try await listPasskeys()
            return true
        } catch PasskeyError.unavailable {
            return false
        } catch {
            return true
        }
    }
}

extension AccountSessionsRepository: PasskeysManaging {
    public func listPasskeys() async throws -> [PasskeySummary] {
        let response = await authClient.listPasskeys(request: Auth_V1_ListPasskeysRequest(), headers: [:])
        switch response.result {
        case .success(let body): return body.passkeys.map(Self.summary)
        case .failure(let error): throw Self.passkeyError(error)
        }
    }

    public func startPasskeyRegistration() async throws -> PasskeyCreationRequest {
        let response = await authClient.startPasskeyRegistration(
            request: Auth_V1_StartPasskeyRegistrationRequest(), headers: [:]
        )
        switch response.result {
        case .success(let body):
            guard let challenge = Data(base64URL: body.challenge), let user = Data(base64URL: body.userID) else {
                throw PasskeyError.transport(message: "unreadable registration options")
            }
            return PasskeyCreationRequest(
                challenge: body.challenge, challengeData: challenge, relyingPartyID: body.rpID,
                userID: user, userName: body.userName,
                excludedCredentialIDs: body.excludeCredentials.compactMap { Data(base64URL: $0) }
            )
        case .failure(let error):
            throw Self.passkeyError(error)
        }
    }

    public func finishPasskeyRegistration(
        _ request: PasskeyCreationRequest, attestation: PasskeyAttestation, name: String
    ) async throws -> PasskeySummary {
        var body = Auth_V1_FinishPasskeyRegistrationRequest()
        body.challenge = request.challenge
        body.clientDataJson = attestation.clientDataJSON
        body.attestationObject = attestation.attestationObject
        body.name = String(name.prefix(64))
        let response = await authClient.finishPasskeyRegistration(request: body, headers: [:])
        switch response.result {
        case .success(let passkey): return Self.summary(passkey)
        case .failure(let error): throw Self.passkeyError(error)
        }
    }

    public func removePasskey(id: String) async throws -> [PasskeySummary] {
        var request = Auth_V1_RemovePasskeyRequest()
        request.credentialID = id
        let response = await authClient.removePasskey(request: request, headers: [:])
        switch response.result {
        case .success(let body): return body.passkeys.map(Self.summary)
        case .failure(let error): throw Self.passkeyError(error)
        }
    }

    static func summary(_ passkey: Auth_V1_Passkey) -> PasskeySummary {
        PasskeySummary(
            id: passkey.credentialID,
            name: passkey.name.isEmpty ? "Passkey" : passkey.name,
            createdAt: passkey.hasCreatedAt ? passkey.createdAt.date : nil,
            lastUsedAt: passkey.hasLastUsedAt ? passkey.lastUsedAt.date : nil,
            synced: passkey.synced
        )
    }

    static func passkeyError(_ error: ConnectError) -> PasskeyError {
        let message = error.message ?? ""
        if error.code == .unavailable { return .unavailable }
        if error.code == .permissionDenied, message.contains("step_up_required") { return .stepUpRequired }
        if message.contains("AUT-5023") { return .restart }
        if message.contains("AUT-5024") { return .notAccepted }
        if message.contains("AUT-5025") { return .limitReached }
        if message.contains("AUT-5026") { return .alreadyRegistered }
        if message.contains("AUT-5027") { return .notFound }
        return .transport(message: message.isEmpty ? "code \(error.code)" : message, failure: NetworkFailure(error))
    }
}
