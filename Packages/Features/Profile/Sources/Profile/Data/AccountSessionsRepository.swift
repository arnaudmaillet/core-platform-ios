import Connect
import CoreContracts
import CoreNetworking
import Foundation

/// One signed-in session of the viewer's account, as "Where you're logged
/// in" lists it.
public struct AccountSession: Hashable, Sendable, Identifiable {
    public let id: String
    public let device: SessionDevice
    /// True for the session this app is signed in with.
    public let isCurrent: Bool
    public let signedInAt: Date?

    public init(id: String, device: SessionDevice, isCurrent: Bool, signedInAt: Date?) {
        self.id = id
        self.device = device
        self.isCurrent = isCurrent
        self.signedInAt = signedInAt
    }
}

/// What a session's user agent says about the device, reduced to what a
/// person recognises: "iPhone · iOS 27.0", "Mac · Web browser".
///
/// The contract carries only `DeviceContext.user_agent` (and an IP address the
/// screen deliberately does not show: an address is not a place, and a city
/// guessed from one is wrong often enough to alarm people for nothing).
public struct SessionDevice: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case iPhone, iPad, mac, windows, android, unknown
    }

    public let kind: Kind
    public let title: String
    /// "iOS 27.0", "Web browser"; nil when nothing more is known.
    public let detail: String?

    public init(kind: Kind, title: String, detail: String?) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    /// Parses this app's own user agent — `core-platform-ios/<version>
    /// (<model>; <os> <version>)`, see `AppContainer` — and the common
    /// browser shapes. Anything else is an unknown device rather than a guess.
    public init(userAgent: String) {
        let agent = userAgent.trimmingCharacters(in: .whitespaces)
        if agent.hasPrefix("core-platform-ios") {
            let inside = agent.split(separator: "(", maxSplits: 1).dropFirst().first
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ") ")) }
            let parts = inside?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } ?? []
            let model = parts.first ?? ""
            let kind: Kind = model.hasPrefix("iPad") ? .iPad : .iPhone
            self.init(
                kind: kind,
                title: model.isEmpty ? "iPhone" : model,
                detail: parts.count > 1 ? parts[1] : nil
            )
            return
        }
        let browser = "Web browser"
        if agent.contains("iPad") {
            self.init(kind: .iPad, title: "iPad", detail: browser)
        } else if agent.contains("iPhone") {
            self.init(kind: .iPhone, title: "iPhone", detail: browser)
        } else if agent.contains("Android") {
            self.init(kind: .android, title: "Android", detail: browser)
        } else if agent.contains("Macintosh") || agent.contains("Mac OS X") {
            self.init(kind: .mac, title: "Mac", detail: browser)
        } else if agent.contains("Windows") {
            self.init(kind: .windows, title: "Windows", detail: browser)
        } else {
            self.init(kind: .unknown, title: "Unknown device", detail: nil)
        }
    }
}

/// Lists and ends the viewer's sessions (Settings → Security and Login).
public protocol AccountSessionsManaging: Sendable {
    func activeSessions() async throws -> [AccountSession]
    /// Ends one session. The current one is ended by logging out instead.
    func revokeSession(id: String) async throws
    /// Ends every session, this one included.
    func revokeAllSessions() async throws
}

public enum AccountSessionsError: Error, Equatable {
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault; nil when it did
    /// not come from the network. Defaulted, so every `.transport(message:)`
    /// still builds and every `case .transport:` still matches.
    case transport(message: String, failure: NetworkFailure? = nil)
}

extension AccountSessionsError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
}

/// Step-up (`auth.v1.VerifyCredentials`, #648): re-prove the holder before
/// a destructive action (deactivation, deletion, contact changes). There is
/// no password any more (#840):
/// - two-step sign-in on: the authenticator's code or a backup code
///   (`stepUp(code:)`), whose fresh access token is installed for the session;
/// - otherwise — and for anyone, from the destructive actions — a code sent
///   to the account's address signs the holder in again
///   (`sendReconfirmationCode` → `reconfirm`), a sign-in's token being the
///   proof the server accepts; with two-step on, the authenticator's code
///   finishes it (`completeReconfirmation`).
public protocol CredentialStepUp: Sendable {
    func stepUp(code: String) async throws
    func sendReconfirmationCode() async throws -> Reconfirmation
    func reconfirm(_ reconfirmation: Reconfirmation, code: String) async throws -> ReconfirmationStep
    func completeReconfirmation(secondStepCode: String) async throws
}

/// A code on its way to the account's address, to prove the holder again.
public struct Reconfirmation: Equatable, Sendable {
    public let challengeID: String
    /// Where it went, as the prompt names it.
    public let destination: String

    public init(challengeID: String, destination: String) {
        self.challengeID = challengeID
        self.destination = destination
    }
}

public enum ReconfirmationStep: Equatable, Sendable {
    case done
    /// Two-step sign-in is on: the authenticator's code finishes it.
    case needsSecondStep
}

/// Whoever holds the session (the app's `SessionManager`): signs the holder
/// in again with a code and adopts the fresh session in place of the
/// current one (#840).
public protocol SessionReauthenticating: Sendable {
    /// `.needsSecondStep` hands back the second step's token.
    func reauthenticate(challengeID: String, code: String) async throws -> ReauthenticationResult
    func completeReauthentication(secondStepToken: String, expiresIn: TimeInterval, code: String) async throws
}

public enum ReauthenticationResult: Equatable, Sendable {
    case done
    case needsSecondStep(token: String, expiresIn: TimeInterval)
}

/// Whoever vends the session's access token (the app's `SessionManager`):
/// takes a step-up's fresh token in place of the current one.
public protocol AccessTokenInstalling: Sendable {
    func installStepUpToken(_ accessToken: String, expiresIn: Int64) async
}

public enum StepUpError: Error, Equatable {
    /// The code didn't match: the one sent to the address, or the two-step
    /// one (AUT-5017).
    case wrongCode
    /// The account has no address to send a code to.
    case noAddress
    /// The call failed on the way to or at the server. `failure` keeps WHY
    /// (#794): offline, a timeout, a refusal, a server fault; nil when it did
    /// not come from the network. Defaulted, so every `.transport(message:)`
    /// still builds and every `case .transport:` still matches.
    case transport(message: String, failure: NetworkFailure? = nil)
}

extension StepUpError: NetworkFailureCarrying {
    public var networkFailure: NetworkFailure? {
        if case .transport(_, let failure) = self { failure } else { nil }
    }
}

/// `auth.v1` session management on the AUTHENTICATED client: the RPCs act on
/// the calling principal's account (empty `account_id`), so the bearer token
/// is what says whose sessions these are.
public actor AccountSessionsRepository: AccountSessionsManaging, CredentialStepUp {
    let authClient: any Auth_V1_AuthServiceClientInterface
    /// Hands a step-up's fresh access token to whoever vends tokens (the
    /// app's `SessionManager`), so the next authenticated call carries it.
    let tokenInstaller: (any AccessTokenInstalling)?

    /// The account's address, for the code that proves the holder again.
    private let account: (any AccountProviding)?
    /// Signs the holder in again with that code (#840).
    private let reauthenticator: (any SessionReauthenticating)?
    /// The second step of a reconfirmation in progress.
    private var pendingSecondStep: (token: String, expiresIn: TimeInterval)?

    /// `tokenInstaller` nil: a step-up proves the holder but its token goes
    /// nowhere (tests that don't exercise gated calls). `account` and
    /// `reauthenticator` nil: no reconfirmation by code.
    public init(
        authClient: any Auth_V1_AuthServiceClientInterface,
        tokenInstaller: (any AccessTokenInstalling)? = nil,
        account: (any AccountProviding)? = nil,
        reauthenticator: (any SessionReauthenticating)? = nil
    ) {
        self.authClient = authClient
        self.tokenInstaller = tokenInstaller
        self.account = account
        self.reauthenticator = reauthenticator
    }

    public func stepUp(code: String) async throws {
        var request = Auth_V1_VerifyCredentialsRequest()
        request.credential = .mfaCode(code.trimmingCharacters(in: .whitespacesAndNewlines))
        let response = await authClient.verifyCredentials(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            await tokenInstaller?.installStepUpToken(body.accessToken, expiresIn: body.expiresIn)
        case .failure(let error):
            if error.code == .unauthenticated { throw StepUpError.wrongCode }
            throw StepUpError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    /// Sends a code to the account's email — its phone when it has none.
    public func sendReconfirmationCode() async throws -> Reconfirmation {
        guard let account else { throw StepUpError.noAddress }
        let details: AccountDetails
        do {
            details = try await account.currentAccount()
        } catch {
            throw StepUpError.transport(message: "\(error)", failure: (error as? any NetworkFailureCarrying)?.networkFailure)
        }
        var request = Auth_V1_StartVerificationRequest()
        if !details.email.isEmpty {
            request.channel = .email
            request.destination = details.email
        } else if !details.phone.isEmpty {
            request.channel = .sms
            request.destination = details.phone
        } else {
            throw StepUpError.noAddress
        }
        request.locale = Locale.current.identifier(.bcp47)
        let response = await authClient.startVerification(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            pendingSecondStep = nil
            return Reconfirmation(challengeID: body.challengeID, destination: request.destination)
        case .failure(let error):
            throw StepUpError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    public func reconfirm(_ reconfirmation: Reconfirmation, code: String) async throws -> ReconfirmationStep {
        guard let reauthenticator else { throw StepUpError.noAddress }
        switch try await reauthenticator.reauthenticate(
            challengeID: reconfirmation.challengeID, code: code.trimmingCharacters(in: .whitespacesAndNewlines)
        ) {
        case .done:
            return .done
        case .needsSecondStep(let token, let expiresIn):
            pendingSecondStep = (token, expiresIn)
            return .needsSecondStep
        }
    }

    public func completeReconfirmation(secondStepCode: String) async throws {
        guard let reauthenticator, let step = pendingSecondStep else { throw StepUpError.noAddress }
        try await reauthenticator.completeReauthentication(
            secondStepToken: step.token, expiresIn: step.expiresIn,
            code: secondStepCode.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        pendingSecondStep = nil
    }

    public func activeSessions() async throws -> [AccountSession] {
        let response = await authClient.listSessions(request: Auth_V1_ListSessionsRequest(), headers: [:])
        switch response.result {
        case .success(let body):
            return Self.sessions(from: body.sessions)
        case .failure(let error):
            throw AccountSessionsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    public func revokeSession(id: String) async throws {
        var request = Auth_V1_LogoutRequest()
        request.sessionID = id
        let response = await authClient.logout(request: request, headers: [:])
        if case .failure(let error) = response.result {
            throw AccountSessionsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    public func revokeAllSessions() async throws {
        let response = await authClient.logoutAllSessions(request: Auth_V1_LogoutAllSessionsRequest(), headers: [:])
        if case .failure(let error) = response.result {
            throw AccountSessionsError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    /// Active sessions only, the current one first, then newest sign-in first.
    static func sessions(from views: [Auth_V1_SessionView]) -> [AccountSession] {
        views
            .filter { $0.status == .active || $0.status == .unspecified }
            .map { view in
                AccountSession(
                    id: view.sessionID,
                    device: SessionDevice(userAgent: view.device.userAgent),
                    isCurrent: view.current,
                    signedInAt: view.hasIssuedAt
                        ? Date(timeIntervalSince1970: TimeInterval(view.issuedAt.seconds) + TimeInterval(view.issuedAt.nanos) / 1e9)
                        : nil
                )
            }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                return (lhs.signedInAt ?? .distantPast) > (rhs.signedInAt ?? .distantPast)
            }
    }
}
