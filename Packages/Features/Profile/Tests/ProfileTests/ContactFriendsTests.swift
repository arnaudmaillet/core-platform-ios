import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
import UIKit
@testable import Profile

/// Find Friends from Contacts (#412, `FindProfilesByContacts`, backend #806),
/// end to end over the mock BFF, whose matcher keeps the fleet's rules:
/// verified contacts of active accounts, the profile's by-email / by-phone
/// switch, never across a block, never the caller's own.
@MainActor
struct ContactFriendsTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    /// The address book, with the access iOS would answer.
    private final class Book: ContactBookReading, @unchecked Sendable {
        private let lock = NSLock()
        private var current: ContactBookAccess
        private let afterRequest: ContactBookAccess
        private let contacts: [ContactEntry]
        private(set) var requests = 0
        private(set) var reads = 0

        init(_ access: ContactBookAccess, afterRequest: ContactBookAccess = .authorized, contacts: [ContactEntry]) {
            current = access
            self.afterRequest = afterRequest
            self.contacts = contacts
        }

        func access() -> ContactBookAccess { lock.withLock { current } }
        func requestAccess() async -> ContactBookAccess {
            lock.withLock {
                requests += 1
                if current == .notDetermined { current = afterRequest }
                return current
            }
        }
        func entries() async throws -> [ContactEntry] {
            lock.withLock { reads += 1 }
            return contacts
        }
        func set(_ access: ContactBookAccess) { lock.withLock { current = access } }
    }

    /// Records what is sent before passing it on.
    private final class Recorder: ContactProfileFinding, @unchecked Sendable {
        private let lock = NSLock()
        private let next: any ContactProfileFinding
        private(set) var calls: [(emails: [Data], phones: [Data])] = []

        init(_ next: any ContactProfileFinding) { self.next = next }

        func findProfiles(emailHashes: [Data], phoneHashes: [Data]) async throws -> [ContactProfileMatch] {
            lock.withLock { calls.append((emailHashes, phoneHashes)) }
            return try await next.findProfiles(emailHashes: emailHashes, phoneHashes: phoneHashes)
        }
    }

    private struct Failing: ContactProfileFinding {
        let error: any Error
        func findProfiles(emailHashes: [Data], phoneHashes: [Data]) async throws -> [ContactProfileMatch] { throw error }
    }

    /// Follows nobody, and every write fails.
    private struct BrokenFollowing: ContactFollowing {
        struct Refused: Error {}
        func follow(_ profileID: ProfileID) async throws -> FollowOutcome { throw Refused() }
        func cancelFollowRequest(to profileID: ProfileID) async throws { throw Refused() }
        func followRelation(to profileID: ProfileID) async throws -> FollowRelation { .notFollowing }
        func setFollowing(_ following: Bool, for profileID: ProfileID) async throws { throw Refused() }
    }

    /// The simulator's sample contacts, as `Contacts` hands them over.
    static let sampleContacts: [ContactEntry] = [
        ContactEntry(name: "Kate Bell", emails: ["kate-bell@mac.com"], phones: ["(555) 564-8583", "(415) 555-3695"]),
        ContactEntry(name: "Daniel Higgins", emails: ["d-higgins@mac.com"], phones: ["555-478-7672", "(408) 555-5270"]),
        ContactEntry(name: "John Appleseed", emails: ["John-Appleseed@mac.com"], phones: ["888-555-5512"]),
        ContactEntry(name: "Anna Haro", emails: ["anna-haro@mac.com"], phones: ["555-522-8243"]),
        ContactEntry(name: "Hank Zakroff", emails: ["hank-zakroff@mac.com"], phones: ["(555) 766-4823"]),
        ContactEntry(name: "David Taylor", emails: [], phones: ["555-610-6679"]),
    ]

    private struct Fixture {
        let backend: MockBackend
        let profiles: Profile_V1_ProfileServiceClient
        let graph: SocialGraph_V1_SocialGraphServiceClient
        let account: AccountRepository
        let repository: ProfileRepository
        let events: FollowGraphEvents
        let recorder: Recorder
        let book: Book
        let viewModel: ContactFriendsViewModel

        /// The mock author behind a seeded contact account.
        func handle(_ profileID: String) -> String { backend.dataset.author(for: profileID)?.handle ?? "" }
    }

    private func makeFixture(
        access: ContactBookAccess = .authorized,
        afterRequest: ContactBookAccess = .authorized,
        contacts: [ContactEntry] = ContactFriendsTests.sampleContacts,
        region: String? = "FR",
        finder: (any ContactProfileFinding)? = nil,
        following: (any ContactFollowing)? = nil
    ) -> Fixture {
        let backend = MockBackend()
        let client = backend.makeRPCClient()
        let events = FollowGraphEvents()
        let account = AccountRepository(accountClient: Account_V1_AccountServiceClient(client: client), authSession: Session())
        let repository = ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session(),
            followEvents: events
        )
        let recorder = Recorder(finder ?? account)
        let book = Book(access, afterRequest: afterRequest, contacts: contacts)
        let viewModel = ContactFriendsViewModel(
            book: book, finder: recorder, following: following ?? repository, followEvents: events, region: region
        )
        return Fixture(
            backend: backend, profiles: Profile_V1_ProfileServiceClient(client: client),
            graph: SocialGraph_V1_SocialGraphServiceClient(client: client), account: account, repository: repository,
            events: events, recorder: recorder, book: book, viewModel: viewModel
        )
    }

    /// Waits on STATE, not time: a budget of looks, so a starved runner
    /// costs nothing (see `FollowRequestsTests.settle`).
    @discardableResult
    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<6_000 {
            await Task.yield()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func rows(_ viewModel: ContactFriendsViewModel) -> [ContactFriendsViewModel.Row]? {
        if case .loaded(let rows, _) = viewModel.phase { return rows }
        return nil
    }

    private func isLoaded(_ viewModel: ContactFriendsViewModel) -> Bool { rows(viewModel) != nil }

    private func loadedRows(_ fixture: Fixture) async throws -> [ContactFriendsViewModel.Row] {
        fixture.viewModel.start()
        #expect(await settle { isLoaded(fixture.viewModel) })
        return try #require(rows(fixture.viewModel))
    }

    // MARK: - Matching

    /// Verified emails of active accounts match (the mixed-case one too);
    /// an unverified email and a deactivated account don't. In France a
    /// number written without its country code that isn't French is
    /// skipped, so David Taylor's US number finds no one.
    @Test func verifiedContactsOfActiveAccountsMatchAndTheRestDont() async throws {
        let fixture = makeFixture()
        let rows = try await loadedRows(fixture)
        #expect(Set(rows.map(\.id.rawValue)) == ["prof-30", "prof-31", "prof-32"])
        let kate = try #require(rows.first { $0.id.rawValue == "prof-30" })
        #expect(kate.contactName == "Kate Bell")
        #expect(kate.handle == fixture.handle("prof-30"))
    }

    @Test func aPhoneNumberMatchesInItsOwnRegion() async throws {
        let fixture = makeFixture(region: "US")
        let rows = try await loadedRows(fixture)
        let david = try #require(rows.first { $0.id.rawValue == "prof-35" })
        #expect(david.contactName == "David Taylor")
        // Kate matched by email AND phone: still one row.
        #expect(rows.filter { $0.id.rawValue == "prof-30" }.count == 1)
    }

    /// The contract takes hashes, never contacts: every value sent is a
    /// 32-byte SHA-256 of a normalized identifier, and no name goes.
    @Test func onlyHashesOfNormalizedIdentifiersLeaveTheDevice() async throws {
        let fixture = makeFixture(region: "US")
        _ = try await loadedRows(fixture)
        let call = try #require(fixture.recorder.calls.first)
        #expect(fixture.recorder.calls.count == 1)
        #expect((call.emails + call.phones).allSatisfy { $0.count == 32 })
        #expect(call.emails.contains(ContactIdentifiers.hash("john-appleseed@mac.com")))
        #expect(call.phones.contains(ContactIdentifiers.hash("+15556106679")))
        let raw = Self.sampleContacts.flatMap { [$0.name] + $0.emails + $0.phones }.map { Data($0.utf8) }
        #expect((call.emails + call.phones).allSatisfy { !raw.contains($0) })
    }

    /// #412's acceptance: turning off phone lookup removes the profile from
    /// phone matches (and email lookup from email matches).
    @Test func turningOffPhoneLookupRemovesTheProfileFromPhoneMatches() async throws {
        let fixture = makeFixture(region: "US")
        let profiles = fixture.profiles
        var byPhone = Profile_V1_SetDiscoverySettingsRequest()
        byPhone.profileID = "prof-35"
        byPhone.byPhone = false
        _ = await profiles.setDiscoverySettings(request: byPhone, headers: [:])
        var byEmail = Profile_V1_SetDiscoverySettingsRequest()
        byEmail.profileID = "prof-31"
        byEmail.byEmail = false
        _ = await profiles.setDiscoverySettings(request: byEmail, headers: [:])

        let rows = try await loadedRows(fixture)
        let ids = Set(rows.map(\.id.rawValue))
        #expect(!ids.contains("prof-35"))
        #expect(!ids.contains("prof-31"))
        #expect(ids.contains("prof-32"))
    }

    @Test func aBlockEitherWayHidesTheMatch() async throws {
        let fixture = makeFixture()
        var block = SocialGraph_V1_BlockRequest()
        block.actorID = MockSocialDataset.viewerProfileID
        block.targetID = "prof-32"
        _ = await fixture.graph.block(request: block, headers: [:])
        var blockedBy = SocialGraph_V1_BlockRequest()
        blockedBy.actorID = "prof-31"
        blockedBy.targetID = MockSocialDataset.viewerProfileID
        _ = await fixture.graph.block(request: blockedBy, headers: [:])

        let rows = try await loadedRows(fixture)
        #expect(Set(rows.map(\.id.rawValue)) == ["prof-30"])
    }

    @Test func theCallersOwnAccountIsNeverFound() async throws {
        let fixture = makeFixture(contacts: [ContactEntry(name: "Me", emails: ["Demo@Example.com"], phones: [])])
        let rows = try await loadedRows(fixture)
        #expect(rows.isEmpty)
        #expect(fixture.recorder.calls.first?.emails == [ContactIdentifiers.hash("demo@example.com")])
    }

    /// The server refuses more than 1000 per call (ACC-9001), and past the
    /// day's 5000 lookups says ACC-7007, which the app tells apart.
    @Test func theContractsLimitsHold() async throws {
        let fixture = makeFixture()
        let tooMany = (0..<1_001).map { ContactIdentifiers.hash("c\($0)@example.com") }
        await #expect(throws: AccountError.self) {
            _ = try await fixture.account.findProfiles(emailHashes: tooMany, phoneHashes: [])
        }
        for page in 0..<5 {
            let hashes = (0..<1_000).map { ContactIdentifiers.hash("p\(page)-\($0)@example.com") }
            _ = try await fixture.account.findProfiles(emailHashes: hashes, phoneHashes: [])
        }
        await #expect(throws: ContactMatchError.dailyLimitReached) {
            _ = try await fixture.account.findProfiles(emailHashes: [ContactIdentifiers.hash("kate-bell@mac.com")], phoneHashes: [])
        }
    }

    @Test func aLargeBookIsAskedInPagesTheContractTakes() async throws {
        let many = (0..<1_500).map { ContactEntry(name: "C\($0)", emails: ["c\($0)@example.com"], phones: []) }
        let fixture = makeFixture(contacts: many + Self.sampleContacts)
        let rows = try await loadedRows(fixture)
        #expect(fixture.recorder.calls.count == 2)
        #expect(fixture.recorder.calls.allSatisfy { $0.emails.count + $0.phones.count <= ContactLookupLimits.maxHashesPerCall })
        #expect(rows.count == 3)
    }

    // MARK: - Permission and states

    /// The screen explains first; iOS asks only on Continue.
    @Test func neverAskedShowsThePrePromptBeforeTheSystemPrompt() async throws {
        let fixture = makeFixture(access: .notDetermined)
        fixture.viewModel.start()
        #expect(fixture.viewModel.phase == .needsPermission)
        #expect(fixture.book.requests == 0)
        #expect(fixture.book.reads == 0)
        fixture.viewModel.allowAccess()
        #expect(await settle { isLoaded(fixture.viewModel) })
        #expect(fixture.book.requests == 1)
    }

    @Test func refusedAccessShowsTheDeniedStateAndReadsNothing() async throws {
        let refused = makeFixture(access: .notDetermined, afterRequest: .denied)
        refused.viewModel.start()
        refused.viewModel.allowAccess()
        #expect(await settle { refused.viewModel.phase == .denied })

        let off = makeFixture(access: .denied)
        off.viewModel.start()
        #expect(off.viewModel.phase == .denied)
        #expect(off.book.reads == 0)
        #expect(off.recorder.calls.isEmpty)
        // Turned on in Settings, then back: the list loads.
        off.book.set(.authorized)
        off.viewModel.accessMayHaveChanged()
        #expect(await settle { isLoaded(off.viewModel) })
    }

    @Test func limitedAccessSaysOnlySomeContactsWereChecked() async throws {
        let fixture = makeFixture(access: .limited)
        fixture.viewModel.start()
        #expect(await settle { isLoaded(fixture.viewModel) })
        guard case .loaded(_, let isLimited) = fixture.viewModel.phase else { return }
        #expect(isLimited)
    }

    @Test func noMatchIsTheEmptyState() async throws {
        let fixture = makeFixture(contacts: [ContactEntry(name: "Nobody", emails: ["nobody@example.com"], phones: [])])
        let rows = try await loadedRows(fixture)
        #expect(rows.isEmpty)
    }

    @Test func offlineIsSaidAsOffline() async throws {
        let fixture = makeFixture(finder: Failing(error: AccountError.transport(message: "offline", failure: .offline)))
        fixture.viewModel.start()
        #expect(await settle { fixture.viewModel.phase == .failed(.network(.offline)) })
        #expect(ContactFriendsViewController.failureMessage(.network(.offline)) == FailureCopy.offline)
        #expect(ContactFriendsViewController.failureMessage(.network(.server(code: "internal"))) == "Couldn't check your contacts. Try again.")
    }

    @Test func theDailyLimitIsItsOwnState() async throws {
        let fixture = makeFixture(finder: Failing(error: ContactMatchError.dailyLimitReached))
        fixture.viewModel.start()
        #expect(await settle { fixture.viewModel.phase == .failed(.dailyLimit) })
        #expect(ContactFriendsViewController.failureMessage(.dailyLimit).contains("tomorrow"))
    }

    // MARK: - Following

    /// Follow goes through the app's follow writer, so the follow channel
    /// hears it, and the row turns into Following.
    @Test func followingFromARowIsHeardOnTheFollowChannel() async throws {
        let fixture = makeFixture()
        let heard = HeardChanges()
        let subscription = fixture.events.subscribe { heard.append($0) }
        let rows = try await loadedRows(fixture)
        let target = try #require(rows.first { $0.id.rawValue == "prof-32" })
        try #require(target.relation.offersFollow)

        fixture.viewModel.toggleFollow(target.id)
        #expect(await settle { self.rows(fixture.viewModel)?.first { $0.id == target.id }?.relation.isFollowing == true })
        #expect(heard.changes.contains(FollowChange(profileID: target.id, isFollowing: true, viewerID: ProfileID(MockSocialDataset.viewerProfileID))))
        withExtendedLifetime(subscription) {}

        // And back: Following unfollows at once.
        fixture.viewModel.toggleFollow(target.id)
        #expect(await settle { self.rows(fixture.viewModel)?.first { $0.id == target.id }?.relation.offersFollow == true })
    }

    /// prof-30 is private: Follow asks, and the request can be withdrawn.
    @Test func followingAPrivateProfileAsks() async throws {
        let fixture = makeFixture()
        let rows = try await loadedRows(fixture)
        let kate = try #require(rows.first { $0.id.rawValue == "prof-30" })
        fixture.viewModel.toggleFollow(kate.id)
        #expect(await settle { self.rows(fixture.viewModel)?.first { $0.id == kate.id }?.relation == .requested })
        #expect(ContactFriendsViewController.action(for: try #require(self.rows(fixture.viewModel)?.first { $0.id == kate.id })) == .requested)
        fixture.viewModel.toggleFollow(kate.id)
        #expect(await settle {
            self.rows(fixture.viewModel)?.first { $0.id == kate.id }?.relation == .notFollowing && !fixture.viewModel.isBusy(kate.id)
        })
    }

    @Test func aFailedFollowIsReportedAndTheRowStays() async throws {
        let fixture = makeFixture(following: BrokenFollowing())
        var failures: [String] = []
        fixture.viewModel.onActionFailed = { failures.append($0) }
        let rows = try await loadedRows(fixture)
        let target = try #require(rows.first)
        fixture.viewModel.toggleFollow(target.id)
        #expect(await settle { !failures.isEmpty && !fixture.viewModel.isBusy(target.id) })
        #expect(failures == ["Couldn't follow @\(target.handle)"])
        #expect(self.rows(fixture.viewModel)?.first { $0.id == target.id }?.relation == .notFollowing)
    }

    @Test func aFollowMadeElsewhereShowsOnTheRow() async throws {
        let fixture = makeFixture()
        let rows = try await loadedRows(fixture)
        let target = try #require(rows.first { $0.id.rawValue == "prof-31" })
        fixture.events.publish(FollowChange(profileID: target.id, isFollowing: true))
        #expect(await settle { self.rows(fixture.viewModel)?.first { $0.id == target.id }?.relation.isFollowing == true })
    }

    // MARK: - Screens

    @Test func theScreenExplainsBeforeAskingAndRendersRowsAfter() async throws {
        let fixture = makeFixture(access: .notDetermined)
        let screen = ContactFriendsViewController(viewModel: fixture.viewModel, imagePipeline: nil)
        screen.loadViewIfNeeded()
        screen.updateContentUnavailableConfiguration(using: UIContentUnavailableConfigurationState(traitCollection: screen.traitCollection))
        let prompt = try #require(screen.contentUnavailableConfiguration as? UIContentUnavailableConfiguration)
        #expect(prompt.text == ContactFriendsViewController.prePromptTitle)
        #expect(prompt.secondaryText?.contains("nothing from your contacts is stored") == true)
        #expect(prompt.button.title == "Continue")
        #expect(fixture.book.requests == 0)

        fixture.viewModel.allowAccess()
        #expect(await settle { isLoaded(fixture.viewModel) })
        screen.updateContentUnavailableConfiguration(using: UIContentUnavailableConfigurationState(traitCollection: screen.traitCollection))
        #expect(screen.contentUnavailableConfiguration == nil)
    }

    /// Your Data and Permissions lists the new permission beside the others.
    @Test func contactsIsListedAmongThePermissions() {
        #expect(DataTransparencyViewController.currentPermissions().contains { $0.title == "Contacts" })
    }

    @Test func activityAndDiscoveryOpensFindFriendsFromContacts() async throws {
        let fixture = makeFixture()
        let settings = ActivityDiscoveryViewController(
            manager: fixture.repository,
            makeContactFriends: { ContactFriendsViewController(viewModel: fixture.viewModel, imagePipeline: nil) }
        )
        let navigation = UINavigationController(rootViewController: settings)
        navigation.view.frame = CGRect(x: 0, y: 0, width: 402, height: 2_000)
        settings.loadViewIfNeeded()
        let list = try #require(settings.view.subviews.compactMap { $0 as? UICollectionView }.first)
        func contactsRow() -> IndexPath? {
            list.layoutIfNeeded()
            return list.indexPathsForVisibleItems.first { path in
                let cell = list.cellForItem(at: path) as? UICollectionViewListCell
                return (cell?.contentConfiguration as? UIListContentConfiguration)?.text == ActivityDiscoveryViewController.findContactsTitle
            }
        }
        #expect(await settle { contactsRow() != nil })
        let row = try #require(contactsRow())
        settings.collectionView(list, didSelectItemAt: row)
        #expect(await settle { navigation.viewControllers.last is ContactFriendsViewController })
    }
}

private final class HeardChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [FollowChange] = []
    var changes: [FollowChange] { lock.withLock { stored } }
    func append(_ change: FollowChange) { lock.withLock { stored.append(change) } }
}
