import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
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

    private func repository() -> AccountRepository {
        let bff = MockBFF()
        MockAccountService().register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return AccountRepository(accountClient: Account_V1_AccountServiceClient(client: client), authSession: Session())
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
