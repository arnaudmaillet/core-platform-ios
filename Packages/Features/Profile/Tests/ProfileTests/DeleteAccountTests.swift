import Foundation
import Testing
@testable import Profile

/// Settings → Account → Delete Account (#386): the 30-day window, what the
/// screen says before and after a request, and that a request goes out once.
@MainActor
struct DeleteAccountTests {
    private static let today = Date(timeIntervalSince1970: 1_790_000_000)
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func deletionIsPermanentThirtyDaysLater() {
        let permanent = AccountDeletionPolicy.permanentDate(requestedAt: Self.today, calendar: Self.utc)
        #expect(Self.utc.dateComponents([.day], from: Self.today, to: permanent).day == 30)
    }

    @Test func withNoRequestTheButtonIsOffered() async {
        let model = DeleteAccountViewModel(lifecycle: StubLifecycle(), now: { Self.today })
        await model.load()
        #expect(model.phase == .ready(permanentOn: AccountDeletionPolicy.permanentDate(requestedAt: Self.today)))
    }

    @Test func anEarlierRequestIsShownInsteadOfTheButton() async {
        let earlier = Self.today.addingTimeInterval(-5 * 86_400)
        let model = DeleteAccountViewModel(lifecycle: StubLifecycle(requestedAt: earlier), now: { Self.today })
        await model.load()
        #expect(model.phase == .requested(on: earlier, permanentOn: AccountDeletionPolicy.permanentDate(requestedAt: earlier)))
    }

    /// The GDPR record is restricted on some deployments; unreadable means
    /// "offer the button", never a dead screen.
    @Test func anUnreadableRecordStillOffersTheButton() async {
        let model = DeleteAccountViewModel(lifecycle: StubLifecycle(failsRead: true), now: { Self.today })
        await model.load()
        guard case .ready = model.phase else { Issue.record("expected ready, got \(model.phase)"); return }
    }

    /// What gets deleted names the account's profiles and what is left in the
    /// wallet (#402), and falls back to the general wording when unread.
    @Test func theChecklistNamesWhatWillBeLost() async {
        let checklist = DeletionChecklist(profileHandles: ["you", "you.work"], points: 1_250, gems: 3)
        let model = DeleteAccountViewModel(lifecycle: StubLifecycle(), checklist: { checklist }, now: { Self.today })
        await model.load()
        #expect(model.checklist == checklist)
        let lines = DeleteAccountViewController.consequences(for: checklist)
        #expect(lines.first == "All 2 profiles on this account: @you, @you.work")
        #expect(lines.last?.hasPrefix("Your \(1_250.formatted()) points and 3 gems.") == true, "grouped as the locale does")
        #expect(lines.last?.contains("can't be refunded") == true)

        #expect(DeleteAccountViewController.consequences(for: nil)
            == ["Every profile on this account", "Posts, comments and messages",
                "Followers, following and saved posts", "Points and gems in your wallet"])
    }

    @Test func theChecklistWordsEachCase() {
        #expect(DeleteAccountViewController.profilesLine(["you"]) == "Your profile @you")
        #expect(DeleteAccountViewController.profilesLine([]) == "Every profile on this account")
        #expect(DeleteAccountViewController.profilesLine(["a1", "b2", "c3", "d4", "e5"])
            == "All 5 profiles on this account: @a1, @b2, @c3 and 2 more")
        #expect(DeleteAccountViewController.walletLine(points: 0, gems: 1) == "Your 1 gem. They can't be refunded or moved to another account")
        #expect(DeleteAccountViewController.walletLine(points: 0, gems: 0) == "Points and gems in your wallet")
        #expect(DeleteAccountViewController.walletLine(points: nil, gems: nil) == "Points and gems in your wallet")
    }

    @Test func requestingSendsOnceAndReturnsThePermanentDate() async throws {
        let stub = StubLifecycle()
        let model = DeleteAccountViewModel(lifecycle: stub, now: { Self.today })
        await model.load()
        let permanent = try await model.requestDeletion()
        #expect(await stub.requests == 1)
        #expect(permanent == AccountDeletionPolicy.permanentDate(requestedAt: Self.today))
        #expect(model.phase == .requested(on: Self.today, permanentOn: permanent))
    }

    @Test func theFooterGivesTheDateAndTheWayBack() {
        let permanent = AccountDeletionPolicy.permanentDate(requestedAt: Self.today)
        let ready = DeleteAccountViewController.footer(for: .ready(permanentOn: permanent)) ?? ""
        #expect(ready.contains("30 days"))
        #expect(ready.contains("logging back in cancels it"))
        let requested = DeleteAccountViewController.footer(for: .requested(on: Self.today, permanentOn: permanent)) ?? ""
        #expect(requested.contains("You asked to delete this account"))
        #expect(DeleteAccountViewController.footer(for: .loading) == nil)
    }
}

private actor StubLifecycle: AccountLifecycleManaging {
    private let requestedAt: Date?
    private let failsRead: Bool
    private(set) var requests = 0

    init(requestedAt: Date? = nil, failsRead: Bool = false) {
        self.requestedAt = requestedAt
        self.failsRead = failsRead
    }

    func requestDeletion() async throws { requests += 1 }

    func requestDataExport() async throws {}

    func gdprStatus() async throws -> AccountGdprStatus {
        if failsRead { throw AccountError.transport(message: "restricted") }
        return AccountGdprStatus(deletionRequestedAt: requestedAt)
    }
}
