import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
@testable import Profile

/// Settings → Account → Date of Birth (#394, backend #652).
@MainActor
struct BirthDateTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    // MARK: - The date

    @Test func itParsesAndPrintsISO() {
        #expect(BirthDate(iso: "2001-03-12") == BirthDate(year: 2001, month: 3, day: 12))
        #expect(BirthDate(iso: "2001-03-12")?.iso == "2001-03-12")
        #expect(BirthDate(iso: "") == nil)
        #expect(BirthDate(iso: "2001-13-01") == nil)
    }

    /// A birthday counts on its day, not the day after.
    @Test func ageTurnsOnTheBirthday() {
        let birth = BirthDate(year: 2013, month: 10, day: 4)
        #expect(birth.age(on: day(2026, 10, 3), calendar: calendar) == 12)
        #expect(birth.age(on: day(2026, 10, 4), calendar: calendar) == 13)
    }

    @Test func theMinimumAgeIs13() {
        let today = day(2026, 10, 4)
        #expect(BirthDatePolicy.check(BirthDate(year: 2013, month: 10, day: 4), today: today, calendar: calendar) == .ok)
        #expect(BirthDatePolicy.check(BirthDate(year: 2013, month: 10, day: 5), today: today, calendar: calendar) == .underMinimumAge)
        #expect(BirthDatePolicy.check(BirthDate(year: 2027, month: 1, day: 1), today: today, calendar: calendar) == .inTheFuture)
    }

    @Test func theScreenSaysWhyItWontSave() {
        #expect(BirthDateViewController.noteText(for: .underMinimumAge).contains("13"))
        #expect(BirthDateViewController.noteText(for: .ok) == BirthDateViewController.explanation)
        #expect(AccountSettingsViewController.birthDateText(nil) == "Add")
    }

    // MARK: - Over the mock

    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
    }

    private func repository(teen: TeenProtections = Self.isolatedTeenProtections()) -> AccountRepository {
        let bff = MockBFF()
        MockAccountService().register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return AccountRepository(
            accountClient: Account_V1_AccountServiceClient(client: client), authSession: Session(), teenProtections: teen
        )
    }

    /// Never the app's own defaults: a test teen must not set this host's
    /// daily limit.
    private static func isolatedTeenProtections() -> TeenProtections {
        let defaults = UserDefaults(suiteName: "teen-\(UUID().uuidString)")!
        return TeenProtections(defaults: defaults, screenTime: ScreenTimeStore(defaults: defaults))
    }

    /// Teen protections (#401) on the device follow the account: a 15-year-old
    /// is recorded as a minor (no purchases) and starts with a 60-minute
    /// daily limit, once; a limit the teen changes is never put back.
    @Test func aTeenAccountTurnsTheDevicesProtectionsOn() async throws {
        let defaults = UserDefaults(suiteName: "teen-\(UUID().uuidString)")!
        let screenTime = ScreenTimeStore(defaults: defaults)
        let teen = TeenProtections(defaults: defaults, screenTime: screenTime)
        let repository = repository(teen: teen)

        _ = try await repository.currentAccount()
        #expect(!teen.isMinor, "no date of birth is not a teen")
        #expect(screenTime.settings.dailyLimitMinutes == nil)

        let fifteen = BirthDate(date: Calendar.current.date(byAdding: .year, value: -15, to: Date())!)
        _ = try await repository.setDateOfBirth(fifteen)
        #expect(teen.isMinor)
        #expect(teen.restrictsPurchases)
        #expect(screenTime.settings.dailyLimitMinutes == TeenProtections.defaultDailyLimitMinutes)

        screenTime.updateSettings { $0.dailyLimitMinutes = nil }
        _ = try await repository.currentAccount()
        #expect(screenTime.settings.dailyLimitMinutes == nil, "the teen turned it off; it stays off")

        teen.clear()
        #expect(!teen.isMinor)
    }

    /// A limit already chosen is kept; an adult gets none.
    @Test func theTeenLimitNeverReplacesAChoice() {
        let defaults = UserDefaults(suiteName: "teen-\(UUID().uuidString)")!
        let screenTime = ScreenTimeStore(defaults: defaults)
        let teen = TeenProtections(defaults: defaults, screenTime: screenTime)
        screenTime.updateSettings { $0.dailyLimitMinutes = 30 }
        teen.record(account: "acc-1", isMinor: true)
        #expect(screenTime.settings.dailyLimitMinutes == 30)

        let adultDefaults = UserDefaults(suiteName: "teen-\(UUID().uuidString)")!
        let adultScreenTime = ScreenTimeStore(defaults: adultDefaults)
        let adult = TeenProtections(defaults: adultDefaults, screenTime: adultScreenTime)
        adult.record(account: "acc-2", isMinor: false)
        #expect(!adult.restrictsPurchases)
        #expect(adultScreenTime.settings.dailyLimitMinutes == nil)
    }

    /// Settings → Family and Teens lists each protection, and where to change it.
    @Test func familyAndTeensNamesEachProtection() {
        let protections = FamilyAndTeensViewController.protections(dailyLimitMinutes: 60)
        #expect(protections.map(\.title) == [
            "Private Account", "Messages and Mentions", "Location", "Sensitive Content",
            "Daily Limit", "Quiet Hours", "Purchases",
        ])
        #expect(protections.first { $0.title == "Daily Limit" }?.detail.contains("60 minutes") == true)
        #expect(protections.first { $0.title == "Quiet Hours" }?.detail.contains("22:00 to 07:00") == true)
        #expect(protections.first { $0.title == "Purchases" }?.section == nil, "nothing to change before 18")
        #expect(FamilyAndTeensViewController.protections(dailyLimitMinutes: nil)
            .first { $0.title == "Daily Limit" }?.detail.contains("Off") == true)
        #expect(FamilyAndTeensViewController.header(.protections, teen: false) == "For Accounts Aged 13 to 17")
    }

    /// Under 13 is refused and nothing is stored; an adult date is stored
    /// once and comes back with its bracket; a second one is refused.
    @Test func theDateIsSetOnceAndNeverUnderTheMinimumAge() async throws {
        let repository = repository()
        #expect(try await repository.currentAccount().dateOfBirth == nil)
        #expect(try await repository.currentAccount().ageBracket == .unknown)

        let child = BirthDate(date: Calendar.current.date(byAdding: .year, value: -10, to: Date())!)
        await #expect(throws: BirthDateError.underMinimumAge) { _ = try await repository.setDateOfBirth(child) }
        #expect(try await repository.currentAccount().dateOfBirth == nil)

        let adult = BirthDate(year: 1995, month: 6, day: 15)
        #expect(try await repository.setDateOfBirth(adult) == .adult)
        let account = try await repository.currentAccount()
        #expect(account.dateOfBirth == adult)
        #expect(account.ageBracket == .adult)

        await #expect(throws: BirthDateError.alreadySet) { _ = try await repository.setDateOfBirth(adult) }
    }

    /// Teen mode (#401) reads the bracket: 13–15 and 16–17 are teens.
    @Test func teenBracketsAreTeens() async throws {
        let repository = repository()
        let fifteen = BirthDate(date: Calendar.current.date(byAdding: .year, value: -15, to: Date())!)
        let bracket = try await repository.setDateOfBirth(fifteen)
        #expect(bracket == .teen13to15)
        #expect(bracket.isTeen)
        #expect(!AgeBracket.adult.isTeen)
    }
}
