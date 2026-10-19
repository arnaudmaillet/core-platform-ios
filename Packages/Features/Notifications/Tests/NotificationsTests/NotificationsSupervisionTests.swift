import AuthInterface
import CoreContracts
import CoreModels
import CoreNavigation
import CoreNetworking
import CoreNetworkingMocks
import DesignSystem
import Foundation
import Testing
@testable import Notifications

/// Family supervision notices (#1106, backend #848): their own words and
/// icons, and a tap that opens Family and Teens on that link.
struct NotificationsSupervisionTests {
    private func item(_ action: NotificationItem.Action, account: String? = "acct-mum") -> NotificationItem {
        NotificationItem(
            id: "n1", action: action, senderID: ProfileID("prof-40"), senderName: "Mum",
            otherSenderCount: 0, postSubjectID: nil, subjectAccountID: account, isRead: false,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
    }

    /// Each kind says what happened, never "interacted with you".
    @Test func eachSupervisionKindHasItsOwnWords() {
        let now = Date(timeIntervalSince1970: 1000)
        #expect(NotificationDisplayModel(item: item(.supervisionStarted), now: now).text
            == "Mum is now linked with you for parental supervision")
        #expect(NotificationDisplayModel(item: item(.supervisionEnded), now: now).text
            == "Mum ended your parental supervision link")
        #expect(NotificationDisplayModel(item: item(.supervisionCameOfAge), now: now).text
            == "Mum is no longer linked with you: supervision ends at 18")
        for action in [NotificationItem.Action.supervisionStarted, .supervisionEnded, .supervisionCameOfAge] {
            #expect(!NotificationDisplayModel(item: item(action), now: now).text.contains("interacted"))
        }
    }

    /// Each kind wears its own glyph, none of them the generic bell.
    @MainActor
    @Test func eachSupervisionKindHasItsOwnIcon() {
        let symbols = [NotificationItem.Action.supervisionStarted, .supervisionEnded, .supervisionCameOfAge]
            .map { KindBadgeView.style(for: $0).0 }
        #expect(Set(symbols).count == 3)
        #expect(!symbols.contains(KindBadgeView.style(for: .other).0))
    }

    /// Kinds 10–12 map to their actions; a kind this build doesn't know
    /// still reads as generic activity.
    @Test func kindsMapAndAnUnknownOneFallsBack() {
        #expect(NotificationsRepository.action(from: .supervisionStarted) == .supervisionStarted)
        #expect(NotificationsRepository.action(from: .supervisionEnded) == .supervisionEnded)
        #expect(NotificationsRepository.action(from: .supervisionCameOfAge) == .supervisionCameOfAge)
        #expect(NotificationsRepository.action(from: .UNRECOGNIZED(99)) == .other)
    }

    /// A stored supervision row comes back whole at a cold start, and a row
    /// stored before the account id existed still reads.
    @Test func aStoredSupervisionRowSurvivesAColdStart() throws {
        let row = item(.supervisionEnded)
        let data = try JSONEncoder().encode(NotificationsLocalCache.Record(row))
        let back = try JSONDecoder().decode(NotificationsLocalCache.Record.self, from: data).item
        #expect(back == row)
        #expect(back.subjectAccountID == "acct-mum")

        let older = #"{"id":"n2","action":"reaction","sender":{"id":"prof-1","name":"Ava"},"otherSenderCount":0,"sampleSenders":[],"postSubjectID":"post-1","hasPreview":false,"isRead":true,"createdAt":0}"#
        let decoded = try JSONDecoder().decode(NotificationsLocalCache.Record.self, from: Data(older.utf8)).item
        #expect(decoded.action == .reaction)
        #expect(decoded.subjectAccountID == nil)
    }

    private final class SpyRouter: Router {
        private(set) var routes: [AppRoute] = []
        func route(to route: AppRoute) { routes.append(route) }
    }

    private struct Stub: NotificationsProviding {
        let items: [NotificationItem]
        func loadNotifications(limit: Int32, after pageToken: String?) async throws -> NotificationsPage {
            NotificationsPage(items: items, nextPageToken: nil)
        }
        func markAllRead() async throws {}
        func unreadCount() async throws -> Int { 0 }
    }

    /// A tap opens Family and Teens on the link with the other side, not the
    /// sender's profile.
    @MainActor
    @Test func aTapOpensTheSupervision() async {
        let router = SpyRouter()
        let viewModel = NotificationsViewModel(repository: Stub(items: [item(.supervisionStarted)]), router: router)
        var loaded = false
        viewModel.onPhaseChange = { phase in loaded = loaded || !(phase.content ?? []).isEmpty }
        viewModel.viewDidLoad()
        for _ in 0..<6_000 where !loaded {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(loaded)
        viewModel.didSelect("n1")
        #expect(router.routes == [.supervision(otherAccountID: "acct-mum")])
    }

    // MARK: - Over the mock

    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    /// The mock sends the seeded link's notice with the other side's account
    /// as its subject, as backend #848 does.
    @Test func theMockSendsSupervisionNoticesWithTheirAccount() async throws {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset).register(on: bff)
        MockNotificationService(dataset: dataset, supervisionSeed: .supervised).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        let repository = NotificationsRepository(
            notificationClient: Notification_V1_NotificationServiceClient(client: client),
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            postClient: Post_V1_PostServiceClient(client: client),
            authSession: Session()
        )
        let items = try await repository.loadNotifications(limit: 50)
        let started = try #require(items.first { $0.action == .supervisionStarted })
        #expect(started.subjectAccountID == "acct-mock-prof-40")
        #expect(started.postSubjectID == nil)
        #expect(items.contains { $0.action == .supervisionEnded })
    }
}

/// The kind badges are neutral but the heart (#1124, decision 4).
@MainActor
struct KindBadgeHueTests {
    @Test func everyKindButALikeWearsTheNeutralDisc() {
        let kinds: [NotificationItem.Action] = [
            .comment, .reply, .mention, .supervisionStarted, .supervisionEnded, .supervisionCameOfAge, .other,
        ]
        for kind in kinds {
            #expect(KindBadgeView.style(for: kind).1 == KindBadgeView.neutral, "\(kind)")
        }
        #expect(KindBadgeView.style(for: .reaction).1 == LikesSymbol.tint)
    }
}
