import AuthInterface
import Connect
import CoreContracts
import CoreModels
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

/// What a code proved, at sign-in.
public enum CodeSignIn: Equatable, Sendable {
    /// An account answered to that address: the viewer is signed in.
    case signedIn
    /// No account yet (AUT-6004): carry on with `signUp`.
    case needsSignUp
}

/// How an existing account signs in — SignUp's "you already have an account".
public enum ExistingSignInMethod: Equatable, Sendable {
    case apple, google, password, emailCode, phoneCode, unknown
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

    /// Signs in with a code. An address with no account answers
    /// `.needsSignUp`; the same challenge and code then go to `signUp`.
    ///
    /// The device's guest session goes along (`guest_refresh_token`): the
    /// server ends it, and the guest becomes the member.
    public func signIn(challengeID: String, code: String) async throws -> CodeSignIn {
        bootstrapIfNeeded()
        var grant = Auth_V1_VerificationCodeGrant()
        grant.challengeID = challengeID
        grant.code = code
        var request = Auth_V1_LoginRequest()
        request.grantType = .verificationCode
        request.credential = .verificationCode(grant)
        request.device = deviceContext()
        request.guestRefreshToken = guestSession?.refreshToken ?? ""
        let response = await authClient.login(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            install(Self.makeSession(accountID: AccountID(body.accountID), tokens: body.tokens, now: now()))
            pendingReactivationNotice = body.reactivated
            return .signedIn
        case .failure(let error) where error.code == .notFound:
            return .needsSignUp
        case .failure(let error):
            throw Self.codeFailure(error)
        }
    }

    /// Creates the account the code proved an address for. It holds no
    /// profile yet: create one with `PendingAccount.accessToken`, then
    /// `completeSignUp`.
    public func signUp(challengeID: String, code: String, details: SignUpDetails) async throws -> SignUpOutcome {
        bootstrapIfNeeded()
        var grant = Auth_V1_VerificationCodeGrant()
        grant.challengeID = challengeID
        grant.code = code
        var request = Auth_V1_SignUpRequest()
        request.device = deviceContext()
        request.verificationCode = grant
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
            throw Self.codeFailure(error)
        }
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
            install(Self.makeSession(accountID: pending.accountID, tokens: body.tokens, now: now()))
        case .failure(let error):
            throw AuthError.transport(message: error.message ?? "code \(error.code)")
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

    private static func codeFailure(_ error: ConnectError) -> AuthError {
        switch error.code {
        case .invalidArgument, .unauthenticated, .permissionDenied, .notFound, .deadlineExceeded:
            .invalidCode
        default:
            .transport(message: error.message ?? "code \(error.code)")
        }
    }

    private static func method(_ method: Auth_V1_SignInMethod) -> ExistingSignInMethod {
        switch method {
        case .apple: .apple
        case .google: .google
        case .password: .password
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
