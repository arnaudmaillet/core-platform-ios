import Connect
import CoreContracts
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
    case transport(message: String)
}

/// Settings → Security and Login → Change Password (#382), on
/// `auth.v1.ChangePassword`: the current password is proved with the IdP and
/// the new one set there; neither is stored by the app.
public protocol AccountPasswordChanging: Sendable {
    /// Returns how many OTHER sessions were signed out (0 unless asked).
    func changePassword(current: String, new: String, signOutOtherSessions: Bool) async throws -> Int
}

public enum PasswordChangeError: Error, Equatable {
    /// The current password didn't match (UNAUTHENTICATED, AUT-5002).
    case wrongCurrentPassword
    /// The new password was refused — too short or long, unchanged, or the
    /// IdP's policy (FAILED_PRECONDITION). `reason` is the server's rule,
    /// without its error code, ready to show.
    case rejected(reason: String)
    case transport(message: String)

    /// "AUT-VAL-024: the new password must be…" → "The new password must be…".
    static func readable(_ message: String?) -> String {
        guard var text = message?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            return "Choose a different password."
        }
        if let colon = text.firstIndex(of: ":"), text[..<colon].allSatisfy({ $0.isUppercase || $0.isNumber || $0 == "-" }) {
            text = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return text.prefix(1).uppercased() + text.dropFirst() + (text.hasSuffix(".") ? "" : ".")
    }
}

/// `auth.v1` session management on the AUTHENTICATED client: the RPCs act on
/// the calling principal's account (empty `account_id`), so the bearer token
/// is what says whose sessions these are.
public actor AccountSessionsRepository: AccountSessionsManaging, AccountPasswordChanging {
    private let authClient: any Auth_V1_AuthServiceClientInterface

    public init(authClient: any Auth_V1_AuthServiceClientInterface) {
        self.authClient = authClient
    }

    public func activeSessions() async throws -> [AccountSession] {
        let response = await authClient.listSessions(request: Auth_V1_ListSessionsRequest(), headers: [:])
        switch response.result {
        case .success(let body):
            return Self.sessions(from: body.sessions)
        case .failure(let error):
            throw AccountSessionsError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func revokeSession(id: String) async throws {
        var request = Auth_V1_LogoutRequest()
        request.sessionID = id
        let response = await authClient.logout(request: request, headers: [:])
        if case .failure(let error) = response.result {
            throw AccountSessionsError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func revokeAllSessions() async throws {
        let response = await authClient.logoutAllSessions(request: Auth_V1_LogoutAllSessionsRequest(), headers: [:])
        if case .failure(let error) = response.result {
            throw AccountSessionsError.transport(message: error.message ?? "code \(error.code)")
        }
    }

    public func changePassword(current: String, new: String, signOutOtherSessions: Bool) async throws -> Int {
        var request = Auth_V1_ChangePasswordRequest()
        request.currentPassword = current
        request.newPassword = new
        request.signOutOtherSessions = signOutOtherSessions
        let response = await authClient.changePassword(request: request, headers: [:])
        switch response.result {
        case .success(let body):
            return Int(body.sessionsRevoked)
        case .failure(let error):
            switch error.code {
            // AUT-5002 is the wrong current password; another AUT code under
            // UNAUTHENTICATED (an expired session) is not the viewer's typo.
            case .unauthenticated where (error.message ?? "").contains("AUT-5002") || !(error.message ?? "").contains("AUT-"):
                throw PasswordChangeError.wrongCurrentPassword
            case .failedPrecondition, .invalidArgument: throw PasswordChangeError.rejected(reason: PasswordChangeError.readable(error.message))
            default: throw PasswordChangeError.transport(message: error.message ?? "code \(error.code)")
            }
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
