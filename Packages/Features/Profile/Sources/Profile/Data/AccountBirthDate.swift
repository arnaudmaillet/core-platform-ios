import CoreContracts
import CoreStorage
import Foundation

/// A calendar date of birth — a day, not an instant: no time zone can move
/// it. ISO 8601 `YYYY-MM-DD` on the wire (`account.v1`).
public struct BirthDate: Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD`; nil for anything else (an empty string included).
    public init?(iso: String) {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    /// The picked day in `calendar`.
    public init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 0, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Whole years old on `today`'s date in `calendar`.
    public func age(on today: Date, calendar: Calendar = .current) -> Int {
        let now = calendar.dateComponents([.year, .month, .day], from: today)
        var age = (now.year ?? 0) - year
        if (now.month ?? 0, now.day ?? 0) < (month, day) { age -= 1 }
        return age
    }

    /// Midday on the day, for showing it with a `DateFormatter`.
    public func date(calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }
}

/// The account's age bracket, from its date of birth (`account.v1.AgeBracket`):
/// what teen protections (#401) read.
public enum AgeBracket: Sendable, Equatable {
    /// No date of birth on file.
    case unknown
    case teen13to15
    case teen16to17
    case adult

    public var isTeen: Bool { self == .teen13to15 || self == .teen16to17 }

    init(_ bracket: Account_V1_AgeBracket) {
        switch bracket {
        case .ageBracket1315: self = .teen13to15
        case .ageBracket1617: self = .teen16to17
        case .adult: self = .adult
        default: self = .unknown
        }
    }
}

/// The client's side of the minimum age (decided 2026-10-03: 13). The
/// server applies it too (ACC-2004), and raises it where the country of
/// residence requires (16 in Australia); this only spares the viewer a round
/// trip for what is certain to be refused.
public enum BirthDatePolicy {
    public static let minimumAge = 13

    public enum Check: Equatable {
        case ok
        case inTheFuture
        case underMinimumAge
    }

    public static func check(_ birthDate: BirthDate, today: Date, calendar: Calendar = .current) -> Check {
        let age = birthDate.age(on: today, calendar: calendar)
        if age < 0 || (age == 0 && BirthDate(date: today, calendar: calendar).iso < birthDate.iso) { return .inTheFuture }
        return age < minimumAge ? .underMinimumAge : .ok
    }
}

/// Settings → Account → Date of Birth (#394, backend #652): recorded once,
/// when none is on file; afterwards only support can change it.
public protocol AccountBirthDateSetting: Sendable {
    func setDateOfBirth(_ birthDate: BirthDate) async throws -> AgeBracket
}

public enum BirthDateError: Error, Equatable {
    /// Under the minimum age for the account's country (ACC-2004). Nothing
    /// was stored.
    case underMinimumAge
    /// A date of birth is already on file; support changes it.
    case alreadySet
    case transport(message: String)
}

extension AccountRepository: AccountBirthDateSetting {
    public func setDateOfBirth(_ birthDate: BirthDate) async throws -> AgeBracket {
        var request = Account_V1_SetDateOfBirthRequest()
        request.accountID = try await accountID()
        request.dateOfBirth = birthDate.iso
        let response = await accountClient.setDateOfBirth(request: request, headers: [:])
        switch response.result {
        case .success(let view):
            let bracket = AgeBracket(view.ageBracket)
            // A date just given can make the account a teen (#401).
            teenProtections.record(account: request.accountID, isMinor: bracket.isTeen)
            return bracket
        case .failure(let error):
            let message = error.message ?? ""
            if message.contains("ACC-2004") { throw BirthDateError.underMinimumAge }
            if error.code == .failedPrecondition || error.code == .alreadyExists { throw BirthDateError.alreadySet }
            throw BirthDateError.transport(message: error.message ?? "code \(error.code)")
        }
    }
}
