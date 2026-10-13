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

    /// One shared set per teen, keyed by the teen's account (the viewer's own
    /// when the viewer is the teen), with who set it and when.
    struct LimitsRecord {
        var limits: Account_V1_SupervisionLimits
        var setBy: String
        var setAt: Date
    }

    private var limitsByTeen: [String: LimitsRecord] = [:]
    /// Minutes per local day ("YYYY-MM-DD"), keyed by the teen's account.
    private var minutesByTeen: [String: [String: Int]] = [:]

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
        seedActivity(seed, now: now)
    }

    /// Limits and a few days of time, so the overview has something to show:
    /// a supervised viewer under a 60-minute limit; the first seeded teen
    /// under 90 minutes, the second with no limits (so no time counted).
    private func seedActivity(_ seed: Seed?, now: Date) {
        switch seed {
        case .supervised, .supervisedFull:
            var limits = Account_V1_SupervisionLimits()
            limits.dailyMinutes = 60
            limits.privateAccount = true
            limits.messages = .followers
            let setBy = "acct-mock-prof-\(Self.supervisorIndices[0])"
            limitsByTeen[MockAuthService.accountID] = LimitsRecord(limits: limits, setBy: setBy, setAt: now.addingTimeInterval(-86_400 * 2))
            // `-mock-screen-time-used <minutes>`: today starts there, so the
            // pause screen can be reached in a QA run.
            let today = Self.launchMinutesToday ?? 42
            minutesByTeen[MockAuthService.accountID] = Self.days([today, 65, 31, 58, 12], endingOn: now)
        case .supervisor:
            var limits = Account_V1_SupervisionLimits()
            limits.dailyMinutes = 90
            limits.comments = .mutuals
            let teen = "acct-mock-prof-\(Self.teenIndices[1])"
            limitsByTeen[teen] = LimitsRecord(limits: limits, setBy: MockAuthService.accountID, setAt: now.addingTimeInterval(-86_400 * 4))
            minutesByTeen[teen] = Self.days([25, 94, 77, 51, 88, 40, 66], endingOn: now)
        case nil:
            break
        }
    }

    /// `minutes[0]` today, then each day before.
    private static func days(_ minutes: [Int], endingOn now: Date) -> [String: Int] {
        var days: [String: Int] = [:]
        for (offset, value) in minutes.enumerated() {
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: now) else { continue }
            days[dayKey(day)] = value
        }
        return days
    }

    static func dayKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The seed `-mock-supervision <seed>` names, if any.
    public static var launchSeed: Seed? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-mock-supervision"), index + 1 < arguments.count else { return nil }
        return Seed(rawValue: arguments[index + 1])
    }

    private static var launchMinutesToday: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-mock-screen-time-used"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
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
        bff.register(path: "/account.v1.AccountService/SetSupervisionLimits") { [self] (request: Account_V1_SetSupervisionLimitsRequest) in
            setLimits(request)
        }
        bff.register(path: "/account.v1.AccountService/GetSupervisionLimits") { [self] (request: Account_V1_GetSupervisionLimitsRequest) in
            limits(request)
        }
        bff.register(path: "/account.v1.AccountService/GetSupervisionOverview") { [self] (request: Account_V1_GetSupervisionOverviewRequest) in
            overview(request)
        }
        bff.register(path: "/account.v1.AccountService/ReportScreenTime") { [self] (request: Account_V1_ReportScreenTimeRequest) in
            reportScreenTime(request)
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
            let ended = links.remove(at: index)
            // The teen's last supervision ending lifts their limits (the
            // settings keep their values, unlocked). A demo teen has only the
            // viewer as supervisor.
            if ended.otherRole == .teen {
                limitsByTeen[ended.otherAccountID] = nil
            } else if !links.contains(where: { $0.otherRole == .supervisor }) {
                limitsByTeen[MockAuthService.accountID] = nil
            }
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

    // MARK: - Limits and the overview (#670 parts 2 and 3)

    private static let notFound = ConnectError(code: .notFound, message: "ACC-3005: This supervision was not found.")

    /// The teen a request names (empty: the viewer), when the viewer is that
    /// teen or supervises them; nil otherwise (ACC-3005).
    private func viewableTeen(_ teen: String) -> String? {
        if teen.isEmpty || teen == MockAuthService.accountID { return MockAuthService.accountID }
        return links.contains { $0.otherRole == .teen && $0.otherAccountID == teen } ? teen : nil
    }

    private func setLimits(_ request: Account_V1_SetSupervisionLimitsRequest) -> Result<Account_V1_SupervisionLimitsView, ConnectError> {
        guard request.accountID == MockAuthService.accountID else { return .failure(Self.notTheViewer) }
        let daily = request.limits.dailyMinutes
        guard daily == 0 || (15...1440).contains(daily) else {
            return .failure(ConnectError(code: .invalidArgument, message: "ACC-9001: a daily limit is 15 to 1440 minutes"))
        }
        let record: LimitsRecord? = lock.withLock {
            guard links.contains(where: { $0.otherRole == .teen && $0.otherAccountID == request.teenAccountID }) else { return nil }
            let record = LimitsRecord(limits: request.limits, setBy: request.accountID, setAt: Date())
            limitsByTeen[request.teenAccountID] = record
            return record
        }
        guard let record else { return .failure(Self.notFound) }
        return .success(Self.view(of: record))
    }

    private func limits(_ request: Account_V1_GetSupervisionLimitsRequest) -> Result<Account_V1_SupervisionLimitsView, ConnectError> {
        guard request.accountID == MockAuthService.accountID else { return .failure(Self.notTheViewer) }
        let found: (teen: String, record: LimitsRecord?)? = lock.withLock {
            viewableTeen(request.teenAccountID).map { ($0, limitsByTeen[$0]) }
        }
        guard let found else { return .failure(Self.notFound) }
        return .success(found.record.map(Self.view(of:)) ?? Account_V1_SupervisionLimitsView())
    }

    private func overview(_ request: Account_V1_GetSupervisionOverviewRequest) -> Result<Account_V1_SupervisionOverview, ConnectError> {
        guard request.accountID == MockAuthService.accountID else { return .failure(Self.notTheViewer) }
        let found: (teen: String, record: LimitsRecord?, minutes: [String: Int], index: Int?)? = lock.withLock {
            viewableTeen(request.teenAccountID).map { teen in
                (teen, limitsByTeen[teen], minutesByTeen[teen] ?? [:], links.first { $0.otherAccountID == teen }?.profileIndex)
            }
        }
        guard let found else { return .failure(Self.notFound) }
        var overview = Account_V1_SupervisionOverview()
        overview.limits = found.record.map(Self.view(of:)) ?? Account_V1_SupervisionLimitsView()
        // The last 7 local days with time counted, most recent first.
        let recent = Set((0..<7).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }.map { Self.dayKey($0) })
        overview.screenTime = found.minutes.filter { recent.contains($0.key) && $0.value > 0 }
            .sorted { $0.key > $1.key }
            .map { entry in
                var day = Account_V1_ScreenTimeDay()
                day.day = entry.key
                day.minutes = UInt32(entry.value)
                return day
            }
        if let index = found.index, index < dataset.authors.count {
            overview.profiles = [Self.profile(dataset.authors[index])]
        } else if found.teen == MockAuthService.accountID {
            var profile = Account_V1_SupervisionProfile()
            profile.profileID = MockSocialDataset.viewerProfileID
            profile.handle = "you"
            profile.displayName = "You"
            overview.profiles = [profile]
        }
        return .success(overview)
    }

    /// The app's time, counted only under a daily limit, on the local day of
    /// the zone it names (UTC when the zone is unknown). At most 15 minutes a
    /// report (ACC-9001 past that).
    private func reportScreenTime(_ request: Account_V1_ReportScreenTimeRequest) -> Result<Account_V1_ScreenTimeView, ConnectError> {
        guard request.accountID == MockAuthService.accountID else { return .failure(Self.notTheViewer) }
        guard request.minutes <= 15 else {
            return .failure(ConnectError(code: .invalidArgument, message: "ACC-9001: a report adds at most 15 minutes"))
        }
        let day = Self.dayKey(Date(), timeZone: TimeZone(identifier: request.timezone) ?? TimeZone(identifier: "UTC")!)
        let view: Account_V1_ScreenTimeView = lock.withLock {
            var view = Account_V1_ScreenTimeView()
            guard let limit = limitsByTeen[MockAuthService.accountID]?.limits.dailyMinutes, limit > 0 else { return view }
            var days = minutesByTeen[MockAuthService.accountID] ?? [:]
            days[day, default: 0] += Int(request.minutes)
            minutesByTeen[MockAuthService.accountID] = days
            view.usedMinutes = UInt32(days[day] ?? 0)
            view.limitMinutes = limit
            view.reached = view.usedMinutes >= limit
            return view
        }
        return .success(view)
    }

    /// Today's minutes for the demo account, for tests.
    public var viewerMinutesToday: Int {
        lock.withLock { minutesByTeen[MockAuthService.accountID]?[Self.dayKey(Date())] ?? 0 }
    }

    private static func view(of record: LimitsRecord) -> Account_V1_SupervisionLimitsView {
        var view = Account_V1_SupervisionLimitsView()
        view.set = true
        view.limits = record.limits
        view.setByAccountID = record.setBy
        view.setAt = Google_Protobuf_Timestamp(date: record.setAt)
        return view
    }

    private static func profile(_ author: MockSocialDataset.Author) -> Account_V1_SupervisionProfile {
        var profile = Account_V1_SupervisionProfile()
        profile.profileID = author.profileID
        profile.handle = author.handle
        profile.displayName = author.displayName
        profile.avatarURL = author.avatarURL
        return profile
    }

    /// The viewer's links, for tests: the other side's account ids.
    public var linkedAccountIDs: [String] { lock.withLock { links.map(\.otherAccountID) } }
}
