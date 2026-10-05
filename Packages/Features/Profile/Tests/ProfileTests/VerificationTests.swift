import AuthInterface
import CoreContracts
import CoreModels
import CoreNetworking
import CoreNetworkingMocks
import Foundation
import Testing
@testable import Profile

/// Account Type → Verification (#415, backend #668), end to end over the mock.
@MainActor
struct VerificationTests {
    private struct Session: AuthSessionProviding {
        func currentState() async -> AuthState { .authenticated(AccountID(MockAuthService.accountID)) }
        func stateUpdates() async -> AsyncStream<AuthState> {
            AsyncStream { $0.yield(.authenticated(AccountID(MockAuthService.accountID))); $0.finish() }
        }
        func logout() async {}
    }

    private func makeRepository(seed: String? = nil) -> ProfileRepository {
        let dataset = MockSocialDataset()
        let bff = MockBFF()
        MockSocialServices(dataset: dataset, verificationSeed: seed).register(on: bff)
        MockSocialGraphService(dataset: dataset).register(on: bff)
        MockCounterService(store: MockCounterStore(dataset: dataset)).register(on: bff)
        let client = ConnectClientFactory.makeUnauthenticated(host: "https://mock.bff.local", httpClient: bff)
        return ProfileRepository(
            profileClient: Profile_V1_ProfileServiceClient(client: client),
            counterClient: Counter_V1_CounterServiceClient(client: client),
            socialGraphClient: SocialGraph_V1_SocialGraphServiceClient(client: client),
            authSession: Session()
        )
    }

    /// Done when: a profile that never asked can ask, and then waits.
    @Test func askingLeavesTheRequestPending() async throws {
        let repository = makeRepository()
        #expect(try await repository.verificationStatus() == .notRequested)

        try await repository.requestVerification(.notable, links: ["https://example.com/press"])
        guard case .pending(let category, _) = try await repository.verificationStatus() else {
            Issue.record("the request isn't pending")
            return
        }
        #expect(category == .notable)
    }

    @Test func aSecondRequestWaitsForTheFirst() async throws {
        let repository = makeRepository(seed: "pending")
        await #expect(throws: VerificationError.alreadyPending) {
            try await repository.requestVerification(.official, links: ["https://example.com"])
        }
    }

    @Test func aVerifiedProfileCannotAskAgain() async throws {
        let repository = makeRepository(seed: "approved")
        #expect(try await repository.verificationStatus() == .verified(.notable))
        await #expect(throws: VerificationError.alreadyVerified) {
            try await repository.requestVerification(.official, links: ["https://example.com"])
        }
    }

    /// Turned down: the reason shows, and the profile may ask again.
    @Test func aRejectedRequestSaysWhyAndAllowsAnother() async throws {
        let repository = makeRepository(seed: "rejected")
        guard case .rejected(let reason, let decidedAt) = try await repository.verificationStatus() else {
            Issue.record("the request isn't rejected")
            return
        }
        #expect(!reason.isEmpty)
        #expect(decidedAt != nil)
        #expect(VerificationStatus.rejected(reason: reason, decidedAt: decidedAt).canRequest)

        try await repository.requestVerification(.business, links: ["https://example.com/registry"])
        guard case .pending(.business, _) = try await repository.verificationStatus() else {
            Issue.record("the new request isn't pending")
            return
        }
    }

    @Test func moreThanFiveLinksAreRefused() async throws {
        let repository = makeRepository()
        let links = (0..<6).map { "https://example.com/\($0)" }
        await #expect(throws: VerificationError.invalid(message: "PRF-9001: 1–5 supporting documents")) {
            try await repository.requestVerification(.notable, links: links)
        }
    }

    /// An approved record on a profile that no longer has the badge doesn't
    /// stand in the way of asking again.
    @Test func anApprovedRecordWithoutTheBadgeCanAskAgain() {
        var response = Profile_V1_GetVerificationRequestResponse()
        response.request.status = .approved
        #expect(ProfileRepository.status(of: response) == .notRequested)
        #expect(ProfileRepository.status(of: Profile_V1_GetVerificationRequestResponse()) == .notRequested)
    }

    @Test func linksAreNormalized() {
        #expect(VerificationLink.normalized("  example.com/about ") == "https://example.com/about")
        #expect(VerificationLink.normalized("http://news.example.org/a?b=c") == "http://news.example.org/a?b=c")
        #expect(VerificationLink.normalized("") == nil)
        #expect(VerificationLink.normalized("not a link") == nil)
        #expect(VerificationLink.normalized("localhost") == nil)
        #expect(VerificationLink.normalized("ftp://example.com") == nil)
        #expect(VerificationLink.normalized("https://example.com/" + String(repeating: "a", count: 600)) == nil)
    }

    @Test func submittingNeedsACategoryAndALink() {
        typealias Form = VerificationRequestViewController
        #expect(!Form.canSubmit(category: nil, links: ["https://a.com"], isSubmitting: false))
        #expect(!Form.canSubmit(category: .notable, links: [], isSubmitting: false))
        #expect(!Form.canSubmit(category: .notable, links: ["https://a.com"], isSubmitting: true))
        #expect(Form.canSubmit(category: .notable, links: ["https://a.com"], isSubmitting: false))
    }

    @Test func theRowSaysWhereTheProfileStands() {
        typealias Screen = AccountTypeViewController
        #expect(Screen.verificationRow(.loaded(.notRequested)).title == "Request Verification")
        #expect(Screen.verificationRow(.loaded(.pending(.notable, submittedAt: Date()))).detail?.contains("Notable Person") == true)
        #expect(Screen.verificationRow(.loaded(.rejected(reason: "Not enough coverage.", decidedAt: nil))).detail
            == "Not enough coverage.\nYou can ask again.")
        #expect(Screen.verificationRow(.loaded(.verified(.business))).title == "Verified")
        #expect(VerificationRequestViewController.failureMessage(VerificationError.alreadyPending).contains("already"))
    }
}
