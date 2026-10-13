import AuthInterface
import Connect
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import CoreStorage
import Foundation
import Testing
import UIKit
@testable import Profile

/// Settings → Family and Teens → Parental Supervision (#417, backend #670):
/// pairing over the contract, the refusals in its words, and the screens.
@MainActor
struct SupervisionTests {
    // MARK: - Over the mock

    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> { AsyncStream { $0.finish() } }
        func logout() async {}
    }

    /// The account and supervision mocks sharing one demo account, as in
    /// `MockBackend`. No auto-accept: these tests count links.
    private func repository(seed: MockSupervisionService.Seed? = nil) -> AccountRepository {
        let bff = MockBFF()
        let lifecycle = MockAccountLifecycle()
        MockAccountService(lifecycle: lifecycle).register(on: bff)
        MockSupervisionService(
            dataset: MockSocialDataset(), viewerAge: { lifecycle.viewerAge }, seed: seed, autoAcceptDelay: nil
        ).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let defaults = UserDefaults(suiteName: "supervision-\(UUID().uuidString)")!
        return AccountRepository(
            accountClient: Account_V1_AccountServiceClient(client: client), authSession: Session(),
            teenProtections: TeenProtections(defaults: defaults, screenTime: ScreenTimeStore(defaults: defaults))
        )
    }

    private func birthDate(yearsAgo years: Int) -> BirthDate {
        BirthDate(date: Calendar.current.date(byAdding: .year, value: -years, to: Date())!)
    }

    /// No date of birth fits neither side (ACC-3002), as on the server.
    @Test func noDateOfBirthCanInviteNeitherSide() async throws {
        let repository = repository()
        await #expect(throws: SupervisionError.ageDoesNotFit) {
            _ = try await repository.createSupervisionInvite(as: .supervisor)
        }
        await #expect(throws: SupervisionError.ageDoesNotFit) {
            _ = try await repository.createSupervisionInvite(as: .teen)
        }
    }

    /// An adult's code: 10 characters, 24 hours, shown in two halves; the
    /// adult can't take the teen's side, nor accept their own code.
    @Test func anAdultInvitesATeenAndCantAcceptTheirOwnCode() async throws {
        let repository = repository()
        _ = try await repository.setDateOfBirth(birthDate(yearsAgo: 40))
        let invite = try await repository.createSupervisionInvite(as: .supervisor)
        #expect(invite.code.count == 10)
        #expect(invite.displayCode.count == 11 && invite.displayCode.contains("-"))
        #expect(abs(invite.expiresAt.timeIntervalSinceNow - 86_400) < 120)
        #expect(invite.link?.absoluteString == "https://core-platform.click/family/\(invite.code)")
        await #expect(throws: SupervisionError.ageDoesNotFit) {
            _ = try await repository.createSupervisionInvite(as: .teen)
        }
        await #expect(throws: SupervisionError.ownCode) {
            _ = try await repository.acceptSupervisionInvite(code: invite.code)
        }
    }

    /// A teen accepts a parent's code and sees who supervises them; a third
    /// supervisor is refused (ACC-3003).
    @Test func aTeenAcceptsUpToTwoSupervisors() async throws {
        let repository = repository()
        _ = try await repository.setDateOfBirth(birthDate(yearsAgo: 15))
        let first = try await repository.acceptSupervisionInvite(code: "K7M2Q-9XRTD")
        #expect(first.otherRole == .supervisor)
        #expect(first.primary?.handle.isEmpty == false)
        _ = try await repository.acceptSupervisionInvite(code: "A1B2C3D4E5")
        let list = try await repository.supervisions()
        #expect(list.count == 2)
        #expect(list.allSatisfy { $0.otherRole == .supervisor })
        await #expect(throws: SupervisionError.teenHasTwoSupervisors) {
            _ = try await repository.acceptSupervisionInvite(code: "F6G7H8J9K0")
        }
    }

    /// An unknown code is ACC-3001; ten of them in an hour, ACC-3007.
    @Test func wrongCodesAreRefusedThenCapped() async throws {
        let repository = repository()
        _ = try await repository.setDateOfBirth(birthDate(yearsAgo: 40))
        for _ in 0..<10 {
            await #expect(throws: SupervisionError.invalidCode) {
                _ = try await repository.acceptSupervisionInvite(code: "ZZZZZZZZZZ")
            }
        }
        await #expect(throws: SupervisionError.tooManyAttempts) {
            _ = try await repository.acceptSupervisionInvite(code: "K7M2Q9XRTD")
        }
    }

    /// Either side ends a link and gets the rest back; a second end of the
    /// same link is ACC-3005.
    @Test func endingReturnsWhatIsLeftAndASecondEndIsNotFound() async throws {
        let repository = repository(seed: .supervisor)
        let links = try await repository.supervisions()
        #expect(links.count == 2)
        #expect(links.allSatisfy { $0.otherRole == .teen })
        #expect(links[0].since > links[1].since, "most recent first")
        let ended = try #require(links.first)
        let left = try await repository.endSupervision(with: ended.otherAccountID)
        #expect(left.map(\.otherAccountID) == [links[1].otherAccountID])
        await #expect(throws: SupervisionError.notFound) {
            _ = try await repository.endSupervision(with: ended.otherAccountID)
        }
    }

    /// The contract's codes pick the refusal; a dropped connection stays a
    /// transport failure that knows it was offline (#794).
    @Test func refusalsAreReadFromTheContractsCodes() {
        #expect(SupervisionError(ConnectError(code: .notFound, message: "ACC-3001: invalid")) == .invalidCode)
        #expect(SupervisionError(ConnectError(code: .alreadyExists, message: "ACC-3004: paired")) == .alreadyLinked)
        #expect(SupervisionError(ConnectError(code: .resourceExhausted, message: "ACC-3007: wait")) == .tooManyAttempts)
        let offline = SupervisionError(ConnectError(code: .unavailable, message: "The Internet connection appears to be offline."))
        guard case .transport = offline else {
            Issue.record("expected a transport failure, got \(offline)")
            return
        }
    }

    // MARK: - The list

    /// A fake whose answers the test sets.
    private final class FakeManager: SupervisionManaging, @unchecked Sendable {
        var list: [Supervision] = []
        var endError: SupervisionError?
        var acceptResult: Result<Supervision, SupervisionError> = .failure(.invalidCode)
        private(set) var ended: [String] = []
        private(set) var accepted: [String] = []

        func supervisions() async throws -> [Supervision] { list }
        func createSupervisionInvite(as role: SupervisionRole) async throws -> SupervisionInvite {
            if role == .teen { throw SupervisionError.ageDoesNotFit }
            return SupervisionInvite(code: "K7M2Q9XRTD", expiresAt: Date().addingTimeInterval(86_400))
        }
        func acceptSupervisionInvite(code: String) async throws -> Supervision {
            accepted.append(code)
            return try acceptResult.get()
        }
        func endSupervision(with otherAccountID: String) async throws -> [Supervision] {
            ended.append(otherAccountID)
            if let endError { throw endError }
            list.removeAll { $0.otherAccountID == otherAccountID }
            return list
        }
    }

    private nonisolated static func link(_ role: SupervisionRole, _ id: String, handle: String = "ava") -> Supervision {
        Supervision(
            otherRole: role, otherAccountID: id, since: Date(timeIntervalSince1970: 1_790_000_000),
            profiles: [SupervisionProfile(profileID: "prof-\(id)", handle: handle, displayName: handle.capitalized)]
        )
    }

    /// Ending is never optimistic: a refusal leaves the list as it was.
    @Test func aRefusedEndKeepsTheLink() async throws {
        let manager = FakeManager()
        manager.list = [Self.link(.supervisor, "a"), Self.link(.supervisor, "b")]
        manager.endError = .transport(message: "down", failure: .offline)
        let model = SupervisionListModel(manager: manager)
        await model.load()
        await #expect(throws: SupervisionError.self) { try await model.end(Self.link(.supervisor, "a")) }
        #expect(model.supervisions.map(\.otherAccountID) == ["a", "b"])
    }

    /// A link the server says is gone (ACC-3005) leaves the list: the
    /// server has just said it doesn't exist.
    @Test func anEndFoundGoneDropsTheLink() async throws {
        let manager = FakeManager()
        manager.list = [Self.link(.supervisor, "a"), Self.link(.supervisor, "b")]
        let model = SupervisionListModel(manager: manager)
        await model.load()
        manager.endError = .notFound
        await #expect(throws: SupervisionError.notFound) { try await model.end(Self.link(.supervisor, "a")) }
        #expect(model.supervisions.map(\.otherAccountID) == ["b"])
    }

    /// A failed reload keeps the rows (still true as far as anyone knows);
    /// a failed first read shows the failed row.
    @Test func aFailedReloadKeepsTheRows() async throws {
        final class Flaky: SupervisionManaging, @unchecked Sendable {
            var fail = false
            func supervisions() async throws -> [Supervision] {
                if fail { throw SupervisionError.transport(message: "down", failure: .offline) }
                return [SupervisionTests.link(.teen, "t")]
            }
            func createSupervisionInvite(as role: SupervisionRole) async throws -> SupervisionInvite { throw SupervisionError.notFound }
            func acceptSupervisionInvite(code: String) async throws -> Supervision { throw SupervisionError.notFound }
            func endSupervision(with otherAccountID: String) async throws -> [Supervision] { [] }
        }
        let flaky = Flaky()
        flaky.fail = true
        let model = SupervisionListModel(manager: flaky)
        await model.load()
        #expect(model.phase == .failed)
        #expect(model.failure == .offline)
        flaky.fail = false
        await model.load()
        #expect(model.supervisions.count == 1)
        flaky.fail = true
        await model.load()
        #expect(model.supervisions.count == 1)
    }

    // MARK: - Family and Teens

    /// Supervisors first; a teen with two is offered no invite (no one could
    /// accept it); an adult always is, with Enter an Invite Code.
    @Test func theSectionOffersOnlyWhatCanWork() {
        let teens = [Self.link(.teen, "t1"), Self.link(.teen, "t2")]
        let adult = FamilyAndTeensViewController.supervisionItems(.loaded(teens), teen: false)
        #expect(adult == teens.map(FamilyAndTeensViewController.Item.link) + [.invite, .enterCode])

        let one = [Self.link(.supervisor, "s1")]
        #expect(FamilyAndTeensViewController.supervisionItems(.loaded(one), teen: true) == [.link(one[0]), .invite, .enterCode])

        let two = [Self.link(.supervisor, "s1"), Self.link(.supervisor, "s2")]
        #expect(FamilyAndTeensViewController.supervisionItems(.loaded(two), teen: true) == two.map(FamilyAndTeensViewController.Item.link) + [.enterCode])
        #expect(FamilyAndTeensViewController.supervisionItems(.failed, teen: true) == [.supervisionFailed])
        #expect(FamilyAndTeensViewController.supervisionItems(.loading, teen: false) == [.supervisionLoading])
    }

    private func settle(looks: Int = 6_000, until condition: () -> Bool) async -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// The page lists the viewer's supervisions under the protections once
    /// the age is known; without a manager it keeps "Not Available Yet".
    @Test func thePageListsTheSupervisions() async throws {
        let manager = FakeManager()
        manager.list = [Self.link(.supervisor, "s1", handle: "mum")]
        let page = FamilyAndTeensViewController(
            isTeen: { true }, screenTime: ScreenTimeStore(defaults: UserDefaults(suiteName: "fam-\(UUID().uuidString)")!),
            supervision: manager
        )
        page.loadViewIfNeeded()
        #expect(await settle { supervisionItems(of: page).contains(.link(manager.list[0])) })
        #expect(supervisionItems(of: page).contains(.invite))
        #expect(page.dataSource.snapshot().sectionIdentifiers == [.supervision, .protections], "a link leads the page")

        let unserved = FamilyAndTeensViewController(
            isTeen: { false }, screenTime: ScreenTimeStore(defaults: UserDefaults(suiteName: "fam-\(UUID().uuidString)")!)
        )
        unserved.loadViewIfNeeded()
        #expect(await settle { !supervisionItems(of: unserved).isEmpty })
        #expect(supervisionItems(of: unserved) == [.supervision])
        #expect(unserved.dataSource.snapshot().sectionIdentifiers == [.protections, .supervision])
    }

    /// The supervision section's rows, none while it isn't drawn (asking a
    /// snapshot for a missing section throws).
    private func supervisionItems(of page: FamilyAndTeensViewController) -> [FamilyAndTeensViewController.Item] {
        let snapshot = page.dataSource.snapshot()
        guard snapshot.indexOfSection(.supervision) != nil else { return [] }
        return snapshot.itemIdentifiers(inSection: .supervision)
    }

    // MARK: - Copy

    /// Ending tells the other side (backend #848), and the confirmation says
    /// so from either side; a teen hears that limits may lift.
    @Test func theEndConfirmationSaysTheOtherSideIsTold() {
        let supervisor = Self.link(.supervisor, "s", handle: "mum")
        let teen = Self.link(.teen, "t", handle: "leo")
        #expect(SupervisionCopy.endTitle(supervisor) == "Stop supervision by @mum?")
        #expect(SupervisionCopy.endMessage(supervisor).contains("@mum will be told"))
        #expect(SupervisionCopy.endMessage(supervisor).contains("limits they set are lifted"))
        #expect(SupervisionCopy.endTitle(teen) == "Stop supervising @leo?")
        #expect(SupervisionCopy.endMessage(teen).contains("@leo will be told"))
        #expect(SupervisionDetailViewController.footer(.end, supervision: supervisor)?.contains("turn 18") == true)
    }

    /// A teen is told the truth on the page: who sees what, and that it ends.
    @Test func theTeenFooterSaysTheyAlwaysSeeWhoSupervisesThem() {
        let footer = SupervisionCopy.footer(teen: true, linked: true, full: false)
        #expect(footer.contains("You always see who supervises you"))
        #expect(footer.contains("turn 18"))
        #expect(SupervisionCopy.footer(teen: true, linked: true, full: true).contains("two supervisors"))
        #expect(SupervisionCopy.footer(teen: false, linked: false, full: false).contains("13 to 17"))
    }

    /// Each refusal in the person's words; an unread side never guesses.
    @Test func refusalsAreWordedForTheViewersSide() {
        #expect(SupervisionCopy.failureText(SupervisionError.teenHasTwoSupervisors, teen: true, fallback: "") == "You already have two supervisors")
        #expect(SupervisionCopy.failureText(SupervisionError.teenHasTwoSupervisors, teen: false, fallback: "") == "This teen already has two supervisors")
        #expect(SupervisionCopy.failureText(SupervisionError.ageDoesNotFit, teen: nil, fallback: "").contains("adult with a teen"))
        #expect(SupervisionCopy.failureText(SupervisionError.transport(message: "x", failure: .offline), teen: true, fallback: "Couldn't")
            == FailureCopy.offlineTitle)
        #expect(SupervisionCopy.failureText(SupervisionError.transport(message: "x", failure: nil), teen: true, fallback: "Couldn't") == "Couldn't")
    }

    /// The share sheet carries the code and the link that opens it.
    @Test func theShareTextCarriesTheCodeAndTheLink() {
        let invite = SupervisionInvite(code: "K7M2Q9XRTD", expiresAt: Date())
        let text = SupervisionCopy.shareText(invite, teen: true)
        #expect(text.contains("K7M2Q-9XRTD"))
        #expect(text.contains("https://core-platform.click/family/K7M2Q9XRTD"))
        #expect(text.contains("supervise my account"))
    }

    // MARK: - Screens

    /// Link is offered only for a code that can be one; a refusal keeps the
    /// typed code so it can be fixed, and nothing is linked.
    @Test func acceptingNeedsAWholeCodeAndARefusalKeepsIt() async throws {
        let manager = FakeManager()
        let model = SupervisionAcceptModel(manager: manager, code: "k7m2q-9xrt", viewerRole: .teen)
        #expect(!model.canLink)
        #expect(await model.link() == nil)
        model.code = "k7m2q-9xrtd"
        #expect(model.canLink)
        #expect(await model.link() == .failure(.invalidCode))
        #expect(manager.accepted == ["K7M2Q9XRTD"], "sent as the server reads it")
        #expect(model.code == "k7m2q-9xrtd")

        let link = Self.link(.supervisor, "s")
        manager.acceptResult = .success(link)
        #expect(await model.link() == .success(link))
    }

    /// A link opened cold fills the code in and links nothing by itself.
    @Test func aDeepLinkFillsTheCodeAndWaitsForLink() async throws {
        let manager = FakeManager()
        let screen = SupervisionAcceptViewController(
            model: SupervisionAcceptModel(manager: manager, code: "K7M2Q9XRTD"), resolveTeen: { false }
        ) { _, _ in }
        screen.loadViewIfNeeded()
        #expect(screen.codeField.text == "K7M2Q-9XRTD")
        #expect(screen.model.normalizedCode == "K7M2Q9XRTD")
        #expect(screen.navigationItem.rightBarButtonItem?.isEnabled == true)
        #expect(await settle { screen.model.viewerRole == .supervisor })
        #expect(manager.accepted.isEmpty)
    }

    /// The invite screen asks for a code on the viewer's side; a refusal
    /// says why, in the person's words.
    @Test func theInviteScreenShowsTheCodeOrWhyNot() async throws {
        let manager = FakeManager()
        let adult = SupervisionInviteModel(manager: manager, role: .supervisor)
        await adult.start()
        guard case .ready(let invite) = adult.state else {
            Issue.record("expected a code, got \(adult.state)")
            return
        }
        #expect(invite.displayCode == "K7M2Q-9XRTD")
        let teen = SupervisionInviteModel(manager: manager, role: .teen)
        await teen.start()
        #expect(teen.state == .failed("Supervision is for accounts aged 13 to 17. Check your date of birth in Account"))
    }

    /// Copy Code puts the bare code on the pasteboard.
    @Test func copyCodeCopiesTheBareCode() async throws {
        let screen = SupervisionInviteViewController(model: SupervisionInviteModel(manager: FakeManager(), role: .supervisor))
        var copied: [String] = []
        screen.copyToPasteboard = { copied.append($0) }
        screen.loadViewIfNeeded()
        #expect(await settle { if case .ready = screen.model.state { true } else { false } })
        screen.copyCode()
        #expect(copied == ["K7M2Q9XRTD"])
    }

    /// End Supervision asks first, then ends once the server agrees and
    /// hands back; a refusal keeps the screen.
    @Test func theDetailEndsOnlyAfterConfirmingAndTheServerAgreeing() async throws {
        let manager = FakeManager()
        let link = Self.link(.supervisor, "s", handle: "mum")
        manager.list = [link]
        let list = SupervisionListModel(manager: manager)
        await list.load()
        var endedWith: [Supervision] = []
        var foundGone: [Bool] = []
        let detail = SupervisionDetailViewController(supervision: link, list: list, imagePipeline: nil, router: nil) { _, ended, wasGone in
            endedWith.append(ended)
            foundGone.append(wasGone)
        }
        var confirmations = 0
        detail.confirmEnd = { proceed in
            confirmations += 1
            proceed()
        }
        detail.loadViewIfNeeded()
        let endPath = try #require(detail.dataSource.indexPath(for: .end))
        manager.endError = .transport(message: "down", failure: nil)
        detail.collectionView(UICollectionView(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout()), didSelectItemAt: endPath)
        #expect(confirmations == 1)
        #expect(await settle { !detail.isEnding })
        #expect(endedWith.isEmpty)
        #expect(list.supervisions == [link])

        manager.endError = nil
        detail.end()
        #expect(await settle { endedWith == [link] })
        #expect(foundGone == [false])
        #expect(list.supervisions.isEmpty)
        #expect(manager.ended == ["s", "s"])
    }
}
