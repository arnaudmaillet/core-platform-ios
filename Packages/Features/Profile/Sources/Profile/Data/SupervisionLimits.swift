import CoreContracts
import CoreNetworking
import Foundation

// Family supervision, parts 2 and 3 (#417, backend #670): the limits a
// supervisor sets, and the overview a supervisor sees of a teen — exactly
// what the teen sees of themselves.

/// The loosest audience a supervisor allows for a teen's messages or
/// comments; the teen may pick it or anything stricter.
public enum AudienceFloor: Sendable, Hashable, CaseIterable {
    case followers
    case mutuals
    case noOne

    init?(_ proto: Account_V1_AudienceFloor) {
        switch proto {
        case .followers: self = .followers
        case .mutuals: self = .mutuals
        case .noOne: self = .noOne
        default: return nil
        }
    }

    static func proto(_ floor: AudienceFloor?) -> Account_V1_AudienceFloor {
        switch floor {
        case .followers: .followers
        case .mutuals: .mutuals
        case .noOne: .noOne
        case nil: .unspecified
        }
    }
}

/// One shared set per teen: either supervisor sets it, the last change
/// applies, and the teen's settings are locked to these floors (PRF-5006).
public struct SupervisionLimits: Hashable, Sendable {
    /// A daily limit the server takes: 15 to 1440 minutes.
    public static let dailyMinutesRange = 15...1440
    /// The daily limits offered, in minutes.
    public static let dailyMinuteChoices = [15, 30, 45, 60, 90, 120, 180, 240]

    public var privateAccount: Bool
    /// Nil: no floor.
    public var messages: AudienceFloor?
    public var comments: AudienceFloor?
    /// Hidden from handle search, suggestions and contact matching.
    public var hiddenFromSearch: Bool
    /// Nil: no daily limit.
    public var dailyMinutes: Int?

    public init(
        privateAccount: Bool = false, messages: AudienceFloor? = nil, comments: AudienceFloor? = nil,
        hiddenFromSearch: Bool = false, dailyMinutes: Int? = nil
    ) {
        self.privateAccount = privateAccount
        self.messages = messages
        self.comments = comments
        self.hiddenFromSearch = hiddenFromSearch
        self.dailyMinutes = dailyMinutes
    }

    init(_ proto: Account_V1_SupervisionLimits) {
        self.init(
            privateAccount: proto.privateAccount,
            messages: AudienceFloor(proto.messages),
            comments: AudienceFloor(proto.comments),
            hiddenFromSearch: proto.hiddenFromSearch,
            dailyMinutes: proto.dailyMinutes == 0 ? nil : Int(proto.dailyMinutes)
        )
    }

    var proto: Account_V1_SupervisionLimits {
        var proto = Account_V1_SupervisionLimits()
        proto.privateAccount = privateAccount
        proto.messages = AudienceFloor.proto(messages)
        proto.comments = AudienceFloor.proto(comments)
        proto.hiddenFromSearch = hiddenFromSearch
        proto.dailyMinutes = UInt32(max(0, dailyMinutes ?? 0))
        return proto
    }
}

/// A teen's limits as the server holds them.
public struct SupervisionLimitsState: Hashable, Sendable {
    /// Nil: no limits set.
    public let limits: SupervisionLimits?
    /// The supervisor who made the last change.
    public let setByAccountID: String?
    public let setAt: Date?

    public init(limits: SupervisionLimits?, setByAccountID: String? = nil, setAt: Date? = nil) {
        self.limits = limits
        self.setByAccountID = setByAccountID
        self.setAt = setAt
    }

    init(_ proto: Account_V1_SupervisionLimitsView) {
        guard proto.set else {
            self.init(limits: nil)
            return
        }
        self.init(
            limits: SupervisionLimits(proto.limits),
            setByAccountID: proto.setByAccountID.isEmpty ? nil : proto.setByAccountID,
            setAt: proto.hasSetAt ? proto.setAt.date : nil
        )
    }
}

/// One local day of the teen's time on the app.
public struct ScreenTimeDay: Hashable, Sendable {
    /// The teen's local day, "YYYY-MM-DD".
    public let day: String
    public let minutes: Int

    public init(day: String, minutes: Int) {
        self.day = day
        self.minutes = minutes
    }
}

/// What a supervisor sees of a teen, and what the teen sees of themselves.
public struct SupervisionOverview: Hashable, Sendable {
    public let limits: SupervisionLimitsState
    /// The last 7 days with time counted, most recent first. Time is counted
    /// only under a daily limit; a day without use is absent.
    public let screenTime: [ScreenTimeDay]
    public let profiles: [SupervisionProfile]

    public init(limits: SupervisionLimitsState, screenTime: [ScreenTimeDay], profiles: [SupervisionProfile]) {
        self.limits = limits
        self.screenTime = screenTime
        self.profiles = profiles
    }

    init(_ proto: Account_V1_SupervisionOverview) {
        self.init(
            limits: SupervisionLimitsState(proto.limits),
            screenTime: proto.screenTime.map { ScreenTimeDay(day: $0.day, minutes: Int($0.minutes)) },
            profiles: proto.profiles.map(SupervisionProfile.init)
        )
    }
}

/// A supervisor's view of a teen and the limits they set; a teen's view of
/// themselves (`teenAccountID` nil).
public protocol SupervisionOverviewing: Sendable {
    /// Refused with `.notFound` (ACC-3005) unless the viewer is that teen or
    /// one of their supervisors.
    func supervisionOverview(teenAccountID: String?) async throws -> SupervisionOverview
    /// A supervisor sets its teen's limits: `.notFound` (ACC-3005) when the
    /// viewer doesn't supervise them, `.invalidLimit` (ACC-9001) for a daily
    /// limit outside 15–1440 minutes.
    func setSupervisionLimits(_ limits: SupervisionLimits, teenAccountID: String) async throws -> SupervisionLimitsState
}

extension AccountRepository: SupervisionOverviewing {
    public func supervisionOverview(teenAccountID: String?) async throws -> SupervisionOverview {
        var request = Account_V1_GetSupervisionOverviewRequest()
        request.accountID = try await accountID()
        request.teenAccountID = teenAccountID ?? ""
        let response = await accountClient.getSupervisionOverview(request: request, headers: [:])
        switch response.result {
        case .success(let overview): return SupervisionOverview(overview)
        case .failure(let error): throw SupervisionError(error)
        }
    }

    public func setSupervisionLimits(_ limits: SupervisionLimits, teenAccountID: String) async throws -> SupervisionLimitsState {
        var request = Account_V1_SetSupervisionLimitsRequest()
        request.accountID = try await accountID()
        request.teenAccountID = teenAccountID
        request.limits = limits.proto
        let response = await accountClient.setSupervisionLimits(request: request, headers: [:])
        switch response.result {
        case .success(let view): return SupervisionLimitsState(view)
        case .failure(let error): throw SupervisionError(error)
        }
    }
}

/// A teen's settings change refused because a supervisor's floor holds it
/// (PRF-5006, backend #850). Read from whatever error a profile write threw:
/// the code travels in its message.
public enum SupervisionLock {
    public static let message = "Set by your supervisor. They can change it in Family and Teens."

    public static func isLocked(_ error: any Error) -> Bool {
        String(describing: error).contains("PRF-5006")
    }

    /// The supervisor's message when `error` is that refusal, else `fallback`.
    public static func message(for error: any Error, fallback: String) -> String {
        isLocked(error) ? message : fallback
    }
}
