import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import Foundation

// MARK: - Codes and sign-up (guest mode B4, #449)

/// Where a one-time code goes.
public enum VerificationChannel: Equatable, Sendable {
    case email
    case sms
}

/// A code on its way (`auth.v1.StartVerification`).
public struct VerificationChallenge: Equatable, Sendable {
    public let id: String
    public let channel: VerificationChannel
    /// What the code was sent to, as the person typed it — for "Sent to …".
    public let destination: String
    /// The code stops working after this many seconds (and 5 wrong tries).
    public let expiresIn: TimeInterval
    /// A new code for the same address can be asked for after this long.
    public let resendAfter: TimeInterval
}

/// What a code or an id_token proved, at sign-in.
public enum CodeSignIn: Equatable, Sendable {
    /// An account answered to that identity. It is not the app's session
    /// yet: `completeSignIn` makes it so — or, for an account a sign-up left
    /// without a profile, the profile comes first, then `completeSignUp`.
    case existing(PendingAccount)
    /// No account yet (AUT-6004): carry on with `signUp`.
    case needsSignUp
    /// The account has two-step sign-in on (#383): the identity is proven,
    /// and `completeSecondStep` takes the holder's code.
    case needsSecondStep(SecondStepChallenge)
}

/// A provider that signs people in natively and hands back an id_token.
public enum FederatedProvider: Equatable, Sendable {
    case apple, google
}

/// What proves who someone is, at sign-in and at sign-up.
public enum SignInCredential: Equatable, Sendable {
    /// The one-time code sent for a `VerificationChallenge`.
    case code(challengeID: String, code: String)
    /// A native Sign in with Apple / Google id_token, minted for the RAW
    /// `nonce` from `startFederatedSignIn` (single use, #507).
    case idToken(FederatedProvider, token: String, nonce: String)
    /// One of the account's passkeys (#551): a first factor that needs no
    /// second step. It signs in only — an account is never made with one.
    case passkey(PasskeyAssertion)
}

/// How an existing account signs in — SignUp's "you already have an account".
public enum ExistingSignInMethod: Equatable, Sendable {
    case apple, google, emailCode, phoneCode, unknown
}

/// The answers the sign-up steps collect.
public struct SignUpDetails: Equatable, Sendable {
    /// Year, month, day. Under the minimum age the server creates nothing.
    public var dateOfBirth: DateComponents
    /// The privacy-policy version the person agreed to.
    public var policyVersion: String
    public var marketing: Bool
    public var analytics: Bool
    /// The current country (guest country access), else the storefront's.
    /// Becomes the account's home country.
    public var homeCountry: String

    public init(
        dateOfBirth: DateComponents, policyVersion: String,
        marketing: Bool = false, analytics: Bool = false, homeCountry: String
    ) {
        self.dateOfBirth = dateOfBirth
        self.policyVersion = policyVersion
        self.marketing = marketing
        self.analytics = analytics
        self.homeCountry = homeCountry
    }
}

/// An account that exists but holds no profile yet. Its session is NOT the
/// app's until `completeSignUp`: the shell would otherwise switch to a
/// member with no profile to be. The access token is what creates the
/// profile (`profile.v1.CreateProfile`).
public struct PendingAccount: Equatable, Sendable {
    public let accountID: AccountID
    public let accessToken: String
    let session: AuthSession
    /// A self-deactivated account that signing in resumed (#650).
    var reactivated = false
}

public enum SignUpOutcome: Equatable, Sendable {
    case created(PendingAccount)
    /// The address already belongs to an account that signs in another way.
    case existingAccount(ExistingSignInMethod)
}

extension SessionManager {
    /// Sends a one-time code to an email address or a phone number.
    public func startVerification(
        _ channel: VerificationChannel, to destination: String, locale: String = Locale.current.identifier(.bcp47)
    ) async throws -> VerificationChallenge {
        var request = Auth_V1_StartVerificationRequest()
        request.channel = channel == .email ? .email : .sms
        request.destination = destination
        request.locale = locale
        request.device = deviceContext()
        let response = await authClient.startVerification(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return VerificationChallenge(
                id: body.challengeID, channel: channel, destination: destination,
                expiresIn: TimeInterval(body.expiresInSecs), resendAfter: TimeInterval(body.resendAfterSecs)
            )
        case .failure(let error):
            throw Self.codeFailure(error)
        }
    }

    /// A nonce for one native Sign in with Apple / Google (#507): Apple gets
    /// its SHA-256 hex, Google the raw value, and the raw value goes back
    /// with the id_token. Single use: a retry starts here again.
    public func startFederatedSignIn() async throws -> String {
        let response = await authClient.startFederatedSignIn(request: Auth_V1_StartFederatedSignInRequest(), headers: [:])
        switch response.result {
        case .success(let body): return body.nonce
        case .failure(let error): throw AuthError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    /// The options for one passkey sign-in (#551): a challenge (single use,
    /// five minutes) for the device's authenticator to sign. UNAVAILABLE:
    /// the server has no passkeys, and the sign-in screen says so.
    public func startPasskeySignIn() async throws -> PasskeyAssertionRequest {
        bootstrapIfNeeded()
        let response = await authClient.startPasskeySignIn(request: Auth_V1_StartPasskeySignInRequest(), headers: [:])
        switch response.result {
        case .success(let body):
            guard let challenge = Data(base64URL: body.challenge) else {
                throw AuthError.transport(message: "unreadable passkey sign-in options")
            }
            return PasskeyAssertionRequest(challenge: body.challenge, challengeData: challenge, relyingPartyID: body.rpID)
        case .failure(let error) where error.code == .unavailable:
            throw AuthError.passkeysUnavailable
        case .failure(let error):
            throw AuthError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    /// Signs in with a code.
    public func signIn(challengeID: String, code: String) async throws -> CodeSignIn {
        try await signIn(.code(challengeID: challengeID, code: code))
    }

    /// Proves an identity with a code or an id_token. An identity with an
    /// account answers `.existing` — not yet the app's session, see
    /// `completeSignIn`; one with none answers `.needsSignUp`, and the same
    /// credential then goes to `signUp`.
    ///
    /// The device's guest session goes along (`guest_refresh_token`): the
    /// server ends it, and the guest becomes the member.
    public func signIn(_ credential: SignInCredential) async throws -> CodeSignIn {
        bootstrapIfNeeded()
        var request = Auth_V1_LoginRequest()
        switch credential {
        case .code(let challengeID, let code):
            var grant = Auth_V1_VerificationCodeGrant()
            grant.challengeID = challengeID
            grant.code = code
            request.grantType = .verificationCode
            request.credential = .verificationCode(grant)
        case .idToken:
            request.grantType = .idToken
            request.credential = .idToken(Self.idTokenGrant(credential))
        case .passkey(let assertion):
            request.grantType = .passkey
            request.credential = .passkey(Self.passkeyAssertion(assertion))
        }
        request.device = deviceContext()
        request.guestRefreshToken = guestSession?.refreshToken ?? ""
        let response = await authClient.login(request: request, headers: [:])
        switch response.result {
        case .success(let body) where body.mfaRequired:
            return .needsSecondStep(Self.secondStepChallenge(body))
        case .success(let body):
            return .existing(pendingAccount(body))
        case .failure(let error) where error.code == .notFound:
            // A passkey names its account: none means it is no one's any more.
            if case .passkey = credential { throw AuthError.passkeyRejected }
            return .needsSignUp
        case .failure(let error):
            throw Self.failure(error, for: credential)
        }
    }

    /// Creates the account a code proved an address for.
    public func signUp(challengeID: String, code: String, details: SignUpDetails) async throws -> SignUpOutcome {
        try await signUp(.code(challengeID: challengeID, code: code), details: details)
    }

    /// Creates the account `credential` proves an identity for. It holds no
    /// profile yet: create one with `PendingAccount.accessToken`, then
    /// `completeSignUp`.
    public func signUp(_ credential: SignInCredential, details: SignUpDetails) async throws -> SignUpOutcome {
        bootstrapIfNeeded()
        var request = Auth_V1_SignUpRequest()
        request.device = deviceContext()
        switch credential {
        case .code(let challengeID, let code):
            var grant = Auth_V1_VerificationCodeGrant()
            grant.challengeID = challengeID
            grant.code = code
            request.verificationCode = grant
        case .idToken:
            request.idToken = Self.idTokenGrant(credential)
        case .passkey:
            // A passkey belongs to an account already: nothing to sign up.
            throw AuthError.passkeyRejected
        }
        request.dateOfBirth = Self.isoDate(details.dateOfBirth)
        request.consent.policyVersion = details.policyVersion
        request.consent.dataProcessing = true
        request.consent.marketing = details.marketing
        request.consent.analytics = details.analytics
        request.homeCountry = details.homeCountry
        request.guestRefreshToken = guestSession?.refreshToken ?? ""
        let response = await authClient.signUp(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            switch body.outcome {
            case .signedUp(let created):
                let session = Self.makeSession(accountID: AccountID(created.accountID), tokens: created.tokens, now: now())
                return .created(PendingAccount(accountID: session.accountID, accessToken: session.accessToken, session: session))
            case .existingAccount(let existing):
                return .existingAccount(Self.method(existing.method))
            case nil:
                throw AuthError.transport(message: "sign-up answered nothing")
            }
        case .failure(let error) where error.code == .failedPrecondition:
            throw AuthError.underMinimumAge
        case .failure(let error):
            throw Self.failure(error, for: credential)
        }
    }

    /// The second step of a code or Apple sign-in (#383): the account, not yet
    /// the app's session — `completeSignIn` (or the profile first) follows,
    /// as for `.existing`.
    public func completeSecondStep(_ challenge: SecondStepChallenge, code: String) async throws -> PendingAccount {
        pendingAccount(try await secondStep(challenge, code: code))
    }

    private func pendingAccount(_ body: Auth_V1_LoginResponse) -> PendingAccount {
        let session = Self.makeSession(accountID: AccountID(body.accountID), tokens: body.tokens, now: now())
        return PendingAccount(
            accountID: session.accountID, accessToken: session.accessToken, session: session,
            reactivated: body.reactivated
        )
    }

    /// An account that has its profile becomes the app's session.
    public func completeSignIn(_ account: PendingAccount) {
        pendingSignUpNotice = false
        install(account.session)
        pendingReactivationNotice = account.reactivated
    }

    /// The account now has its profile: a `Refresh` mints the token whose
    /// `pids` carry it, and the session becomes the app's. The guest session
    /// ended server-side at sign-up; it goes here too.
    public func completeSignUp(_ pending: PendingAccount) async throws {
        var request = Auth_V1_RefreshRequest()
        request.refreshToken = pending.session.refreshToken
        request.device = deviceContext()
        let response = await authClient.refresh(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            // Before the broadcast: the shell reads it on `.authenticated`.
            pendingSignUpNotice = true
            install(Self.makeSession(accountID: pending.accountID, tokens: body.tokens, now: now()))
        case .failure(let error):
            throw AuthError.transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    /// A member session becomes the app's, and the guest's ends: the server
    /// ended it when it took the guest refresh token.
    private func install(_ member: AuthSession) {
        session = member
        try? store.save(member)
        guestSession = nil
        try? guest?.store.clear()
        broadcast(.authenticated(member.accountID))
    }

    private static func idTokenGrant(_ credential: SignInCredential) -> Auth_V1_IdTokenGrant {
        var grant = Auth_V1_IdTokenGrant()
        if case .idToken(let provider, let token, let nonce) = credential {
            grant.provider = provider == .apple ? .apple : .google
            grant.idToken = token
            grant.nonce = nonce
        }
        return grant
    }

    static func passkeyAssertion(_ assertion: PasskeyAssertion) -> Auth_V1_PasskeyAssertion {
        var message = Auth_V1_PasskeyAssertion()
        message.challenge = assertion.challenge
        message.credentialID = assertion.credentialID
        message.clientDataJson = assertion.clientDataJSON
        message.authenticatorData = assertion.authenticatorData
        message.signature = assertion.signature
        message.userHandle = assertion.userHandle
        return message
    }

    private static func failure(_ error: ConnectError, for credential: SignInCredential) -> AuthError {
        if case .passkey = credential {
            switch error.code {
            case .unavailable: return .passkeysUnavailable
            // AUT-5028: it did not verify (removed, or an old challenge).
            case .invalidArgument, .unauthenticated, .permissionDenied, .failedPrecondition: return .passkeyRejected
            default: return .transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
            }
        }
        guard case .idToken = credential else { return codeFailure(error) }
        switch error.code {
        case .invalidArgument, .unauthenticated, .permissionDenied:
            return .identityRejected
        default:
            return .transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    private static func codeFailure(_ error: ConnectError) -> AuthError {
        switch error.code {
        case .invalidArgument, .unauthenticated, .permissionDenied, .notFound, .deadlineExceeded:
            .invalidCode
        default:
            .transport(message: error.message ?? "code \(error.code)", failure: NetworkFailure(error))
        }
    }

    private static func method(_ method: Auth_V1_SignInMethod) -> ExistingSignInMethod {
        switch method {
        case .apple: .apple
        case .google: .google
        case .emailCode: .emailCode
        case .phoneCode: .phoneCode
        default: .unknown
        }
    }

    /// ISO 8601, `YYYY-MM-DD`.
    static func isoDate(_ components: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

// MARK: - Proving the holder again (#840)

/// How a re-authentication ended.
public enum Reauthentication: Equatable, Sendable {
    /// The session is fresh: step-up-gated calls go through.
    case done
    /// Two-step sign-in is on: the holder's code finishes it
    /// (`completeReauthentication`).
    case needsSecondStep(SecondStepChallenge)
}

extension SessionManager {
    /// Proves the signed-in holder again with a code sent to their address.
    /// This is what replaced the password before a destructive action (#840):
    /// a sign-in's token carries `auth_time` = now, which every step-up-gated
    /// RPC accepts for a few minutes. An account with two-step sign-in on
    /// answers `.needsSecondStep`.
    ///
    /// The new session replaces the current one SILENTLY: same account, so
    /// the auth state does not change and the app is not rebuilt. The
    /// session it replaces is ended on the server.
    public func reauthenticate(challengeID: String, code: String) async throws -> Reauthentication {
        switch try await signIn(.code(challengeID: challengeID, code: code)) {
        case .existing(let account):
            try await adoptReauthentication(account)
            return .done
        case .needsSecondStep(let challenge):
            return .needsSecondStep(challenge)
        case .needsSignUp:
            // The address proves no account: not the holder's.
            throw AuthError.identityRejected
        }
    }

    /// The second step of `reauthenticate`.
    public func completeReauthentication(_ challenge: SecondStepChallenge, code: String) async throws {
        try await adoptReauthentication(completeSecondStep(challenge, code: code))
    }

    private func adoptReauthentication(_ account: PendingAccount) async throws {
        guard let previous = session, previous.accountID == account.accountID else {
            throw AuthError.identityRejected
        }
        session = account.session
        try? store.save(account.session)
        // Best effort, with the ended session's own bearer (#486), as
        // `logout` does: otherwise every re-proof leaves a session behind.
        guard previous.sessionID != account.session.sessionID,
              previous.accessTokenExpiry > now() else { return }
        var request = Auth_V1_LogoutRequest()
        request.sessionID = previous.sessionID.rawValue
        _ = await authClient.logout(request: request, headers: ["Authorization": ["Bearer \(previous.accessToken)"]])
    }
}
