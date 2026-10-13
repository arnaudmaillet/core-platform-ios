import Connect
import CoreContracts
import Foundation
import SwiftProtobuf

/// Fake of `account.v1`'s family supervision (#417, backend #670), for the
/// demo account. The rules the server applies, so the app's refusals can be
/// seen in mock mode:
///
/// - **age**: a supervisor is 18+, a teen 13–17, from the date of birth
///   `MockAccountService` keeps (`-mock-birthdate YYYY-MM-DD`, or Settings →
///   Account → Date of Birth); none on file is ACC-3002 either way;
/// - **invites**: 10 Crockford characters, 24 hours, single use. A code the
///   viewer made is accepted "by the other side" `autoAcceptDelay` seconds
///   later, the next time the list is read — the mock's stand-in for a second
///   device (`defaultAutoAcceptDelay`). Accepting one's own code is ACC-3006;
/// - **accepting**: any well-formed code names a demo person on the other
///   side, except one starting with "ZZ" (unknown or expired, ACC-3001).
///   Ten wrong codes are ACC-3007. A teen has at most two supervisors
///   (ACC-3003);
/// - **ending**: either side; ACC-3005 when there is no such link.
///
/// `-mock-supervision supervised` gives the viewer one supervisor,
/// `supervised-full` two, `supervisor` two teens they supervise. Launch
/// with a matching `-mock-birthdate`.
public final class MockSupervisionService: @unchecked Sendable {
    public enum Seed: String, Sendable {
        case supervised
        case supervisedFull = "supervised-full"
        case supervisor
    }

    /// How long a code the viewer made waits for "the other side" by default.
    public static let defaultAutoAcceptDelay: TimeInterval = 8
    static let maxSupervisors = 2
    static let maxFailedAccepts = 10

    /// A link, seen from the viewer.
    struct Link {
        /// The OTHER side's role.
        let otherRole: Account_V1_SupervisionRole
        let otherAccountID: String
        let profileIndex: Int
        let since: Date
    }

    private struct Invite {
        /// The VIEWER's side.
        let role: Account_V1_SupervisionRole
        let createdAt: Date
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let dataset: MockSocialDataset
    private let viewerAge: @Sendable () -> Int?
    private let autoAcceptDelay: TimeInterval?
    private var links: [Link] = []
    private var invites: [String: Invite] = [:]
    private var failedAccepts = 0

    /// Demo people on each side, from the dataset's authors: never prof-0 or
    /// prof-2 (the viewer's own account's), and parents apart from teens.
    private static let supervisorIndices = Array(40...50)
    private static let teenIndices = Array(12...24)

    /// - Parameters:
    ///   - viewerAge: the demo account's whole years, nil with no date of
    ///     birth (`MockAccountLifecycle.viewerAge`).
    ///   - autoAcceptDelay: how old a code the viewer made is when the other
    ///     side takes it up; nil never (tests that count links).
    public init(
        dataset: MockSocialDataset,
        viewerAge: @escaping @Sendable () -> Int?,
        seed: Seed? = nil,
        autoAcceptDelay: TimeInterval? = MockSupervisionService.defaultAutoAcceptDelay,
        now: Date = Date()
    ) {
        self.dataset = dataset
        self.viewerAge = viewerAge
        self.autoAcceptDelay = autoAcceptDelay
        switch seed {
        case .supervised:
            links = [Self.link(.supervisor, index: Self.supervisorIndices[0], since: now.addingTimeInterval(-86_400 * 21))]
        case .supervisedFull:
            links = [
                Self.link(.supervisor, index: Self.supervisorIndices[1], since: now.addingTimeInterval(-86_400 * 3)),
                Self.link(.supervisor, index: Self.supervisorIndices[0], since: now.addingTimeInterval(-86_400 * 21)),
            ]
        case .supervisor:
            links = [
                Self.link(.teen, index: Self.teenIndices[1], since: now.addingTimeInterval(-86_400 * 5)),
                Self.link(.teen, index: Self.teenIndices[0], since: now.addingTimeInterval(-86_400 * 40)),
            ]
        case nil:
            break
        }
    }

    /// The seed `-mock-supervision <seed>` names, if any.
    public static var launchSeed: Seed? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-mock-supervision"), index + 1 < arguments.count else { return nil }
        return Seed(rawValue: arguments[index + 1])
    }

    private static func link(_ role: Account_V1_SupervisionRole, index: Int, since: Date) -> Link {
        Link(otherRole: role, otherAccountID: "acct-mock-prof-\(index)", profileIndex: index, since: since)
    }

    public func register(on bff: MockBFF) {
        bff.register(path: "/account.v1.AccountService/CreateSupervisionInvite") { [self] (request: Account_V1_CreateSupervisionInviteRequest) in
            createInvite(request)
        }
        bff.register(path: "/account.v1.AccountService/AcceptSupervisionInvite") { [self] (request: Account_V1_AcceptSupervisionInviteRequest) in
            accept(request)
        }
        bff.register(path: "/account.v1.AccountService/ListSupervisions") { [self] (request: Account_V1_ListSupervisionsRequest) in
            list(request)
        }
        bff.register(path: "/account.v1.AccountService/EndSupervision") { [self] (request: Account_V1_EndSupervisionRequest) in
            end(request)
        }
    }

    // MARK: - Pairing

    /// The viewer's side by age: nil when none fits (no date of birth, or
    /// under 13).
    private var viewerSide: Account_V1_SupervisionRole? {
        guard let age = viewerAge() else { return nil }
        if age >= 18 { return .supervisor }
        return age >= 13 ? .teen : nil
    }

    private static let notTheViewer = ConnectError(code: .notFound, message: "account not found")

    private func createInvite(_ request: Account_V1_CreateSupervisionInviteRequest) -> Result<Account_V1_SupervisionInviteView, ConnectError> {
        guard request.accountID == MockAuthService.accountID else { return .failure(Self.notTheViewer) }
        guard request.role != .unspecified else {
            return .failure(ConnectError(code: .invalidArgument, message: "ACC-9001: role is required"))
        }
        guard viewerSide == request.role else {
            return .failure(ConnectError(code: .failedPrecondition, message: "ACC-3002: Supervision pairs an adult with a teen aged 13 to 17."))
        }
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        let code = String((0..<10).map { _ in alphabet.randomElement()! })
        let now = Date()
        let invite = Invite(role: request.role, createdAt: now, expiresAt: now.addingTimeInterval(86_400))
        lock.withLock { invites[code] = invite }
        var view = Account_V1_SupervisionInviteView()
        view.code = code
        view.expiresAt = Google_Protobuf_Timestamp(date: invite.expiresAt)
        return .success(view)
    }

    private func accept(_ request: Account_V1_AcceptSupervisionInviteRequest) -> Result<Account_V1_SupervisionView, ConnectError> {
        guard request.accountID == MockAuthService.accountID else { return .failure(Self.notTheViewer) }
        let code = request.code.uppercased().filter { $0 != " " && $0 != "-" }
        let side = viewerSide
        let result: Result<Link, ConnectError> = lock.withLock {
            if failedAccepts >= Self.maxFailedAccepts {
                return .failure(ConnectError(code: .resourceExhausted, message: "ACC-3007: Too many invalid codes. Please try again in an hour."))
            }
            guard code.count == 10, !code.hasPrefix("ZZ") else {
                failedAccepts += 1
                return .failure(ConnectError(code: .notFound, message: "ACC-3001: This code is not valid or has expired."))
            }
            if invites[code] != nil {
                return .failure(ConnectError(code: .failedPrecondition, message: "ACC-3006: You cannot supervise your own account."))
            }
            guard let side else {
                return .failure(ConnectError(code: .failedPrecondition, message: "ACC-3002: Supervision pairs an adult with a teen aged 13 to 17."))
            }
            // The viewer takes their age's side; the code's maker the other.
            let other: Account_V1_SupervisionRole = side == .teen ? .supervisor : .teen
            if other == .supervisor, links.filter({ $0.otherRole == .supervisor }).count >= Self.maxSupervisors {
                return .failure(ConnectError(code: .alreadyExists, message: "ACC-3003: This teen already has two supervisors."))
            }
            guard let link = nextLink(other: other) else {
                return .failure(ConnectError(code: .notFound, message: "ACC-3001: This code is not valid or has expired."))
            }
            links.insert(link, at: 0)
            return .success(link)
        }
        return result.map(view(of:))
    }

    /// A demo person not linked yet, on the `other` side.
    private func nextLink(other: Account_V1_SupervisionRole, since: Date = Date()) -> Link? {
        let pool = other == .supervisor ? Self.supervisorIndices : Self.teenIndices
        let taken = Set(links.map(\.profileIndex))
        guard let index = pool.first(where: { !taken.contains($0) && $0 < dataset.authors.count }) else { return nil }
        return Self.link(other, index: index, since: since)
    }

    private func list(_ request: Account_V1_ListSupervisionsRequest) -> Result<Account_V1_ListSupervisionsResponse, ConnectError> {
        guard request.accountID == MockAuthService.accountID else { return .failure(Self.notTheViewer) }
        if let autoAcceptDelay { takeUpInvites(olderThan: autoAcceptDelay) }
        return .success(listResponse())
    }

    /// The other side "accepts" each code the viewer made once it is old
    /// enough — unless the viewer's age no longer fits the side, or a teen
    /// already has two supervisors (the acceptor would be refused).
    private func takeUpInvites(olderThan delay: TimeInterval, now: Date = Date()) {
        let side = viewerSide
        lock.withLock {
            for (code, invite) in invites where now.timeIntervalSince(invite.createdAt) >= delay {
                invites[code] = nil
                guard invite.expiresAt > now, invite.role == side else { continue }
                let other: Account_V1_SupervisionRole = invite.role == .teen ? .supervisor : .teen
                if other == .supervisor, links.filter({ $0.otherRole == .supervisor }).count >= Self.maxSupervisors { continue }
                if let link = nextLink(other: other, since: now) { links.insert(link, at: 0) }
            }
        }
    }

    private func end(_ request: Account_V1_EndSupervisionRequest) -> Result<Account_V1_ListSupervisionsResponse, ConnectError> {
        guard request.accountID == MockAuthService.accountID else { return .failure(Self.notTheViewer) }
        let removed: Bool = lock.withLock {
            guard let index = links.firstIndex(where: { $0.otherAccountID == request.otherAccountID }) else { return false }
            links.remove(at: index)
            return true
        }
        guard removed else {
            return .failure(ConnectError(code: .notFound, message: "ACC-3005: This supervision was not found."))
        }
        return .success(listResponse())
    }

    private func listResponse() -> Account_V1_ListSupervisionsResponse {
        var response = Account_V1_ListSupervisionsResponse()
        response.supervisions = lock.withLock { links }.sorted { $0.since > $1.since }.map(view(of:))
        return response
    }

    private func view(of link: Link) -> Account_V1_SupervisionView {
        var view = Account_V1_SupervisionView()
        view.otherRole = link.otherRole
        view.otherAccountID = link.otherAccountID
        view.since = Google_Protobuf_Timestamp(date: link.since)
        if link.profileIndex < dataset.authors.count {
            let author = dataset.authors[link.profileIndex]
            var profile = Account_V1_SupervisionProfile()
            profile.profileID = author.profileID
            profile.handle = author.handle
            profile.displayName = author.displayName
            profile.avatarURL = author.avatarURL
            view.profiles = [profile]
        }
        return view
    }

    /// The viewer's links, for tests: the other side's account ids.
    public var linkedAccountIDs: [String] { lock.withLock { links.map(\.otherAccountID) } }
}
