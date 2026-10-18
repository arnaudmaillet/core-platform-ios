import Foundation
import Testing
import UIKit
@testable import Profile

/// A teen is told plainly, before linking, what their supervisor will see,
/// and can re-read it on the supervisor's page (#1116).
@MainActor
struct SupervisionConsentTests {
    private final class Manager: SupervisionManaging, @unchecked Sendable {
        func supervisions() async throws -> [Supervision] { [] }
        func createSupervisionInvite(as role: SupervisionRole) async throws -> SupervisionInvite { throw SupervisionError.notFound }
        func acceptSupervisionInvite(code: String) async throws -> Supervision { throw SupervisionError.invalidCode }
        func endSupervision(with otherAccountID: String) async throws -> [Supervision] { [] }
    }

    private func settle(looks: Int = 6_000, until condition: () -> Bool) async -> Bool {
        for _ in 0..<looks {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func acceptScreen(role: SupervisionRole?, resolveTeen: (() async throws -> Bool)? = nil) -> SupervisionAcceptViewController {
        let screen = SupervisionAcceptViewController(
            model: SupervisionAcceptModel(manager: Manager(), code: "K7M2Q9XRTD", viewerRole: role), resolveTeen: resolveTeen
        ) { _, _ in }
        screen.loadViewIfNeeded()
        return screen
    }

    /// Before the code and before Link, a teen reads what is shared: daily
    /// time in this app and the limits, from now on, and that they can end
    /// it (the other side is told).
    @Test func theAcceptScreenSaysWhatIsSharedBeforeLink() throws {
        let screen = acceptScreen(role: .teen)
        #expect(!screen.consentView.isHidden)
        let words = screen.consentView.texts.joined(separator: " ")
        #expect(screen.consentView.texts.first == "What your supervisor will see")
        #expect(words.contains("Your daily time in this app"))
        #expect(words.contains("The limits they set"))
        #expect(words.contains("shared from the moment you link"))
        #expect(words.contains("end the supervision at any time"))
        #expect(words.contains("They'll be told"))

        // Above the code field, so it is read before Link.
        let stack = try #require(screen.consentView.superview as? UIStackView)
        let consent = try #require(stack.arrangedSubviews.firstIndex(of: screen.consentView))
        let field = try #require(stack.arrangedSubviews.firstIndex(of: screen.codeField))
        #expect(consent < field)
    }

    /// A link opened cold still tells a teen; once the side is read, an
    /// adult (who shares nothing by accepting) doesn't see it.
    @Test func anUnreadSideIsToldAndAnAdultIsNot() async {
        let cold = acceptScreen(role: nil, resolveTeen: { false })
        #expect(cold.consentView.texts.first == SupervisionConsent.unknownTitle || cold.consentView.isHidden)
        #expect(await settle { cold.consentView.isHidden })

        let adult = acceptScreen(role: .supervisor)
        #expect(adult.consentView.isHidden)

        let unread = acceptScreen(role: nil)
        #expect(!unread.consentView.isHidden)
        #expect(unread.consentView.texts.first == "If you're the teen, your supervisor will see")
    }

    /// The teen's page repeats the summary; a supervisor's page of a teen
    /// doesn't carry it.
    @Test func theTeensDetailRepeatsTheSummary() {
        let list = SupervisionListModel(manager: Manager())
        let profile = SupervisionProfile(profileID: "prof-mum", handle: "mum", displayName: "Mum")
        let teenSide = SupervisionDetailViewController(
            supervision: Supervision(otherRole: .supervisor, otherAccountID: "mum", since: Date(), profiles: [profile]),
            list: list, imagePipeline: nil, router: nil
        ) { _, _, _ in }
        teenSide.loadViewIfNeeded()
        let snapshot = teenSide.dataSource.snapshot()
        #expect(snapshot.indexOfSection(.sharing) != nil)
        #expect(snapshot.itemIdentifiers(inSection: .sharing) == SupervisionConsent.lines(linked: true).map { .sharing($0) })
        #expect(SupervisionDetailViewController.header(.sharing) == "What They See")

        let parentSide = SupervisionDetailViewController(
            supervision: Supervision(otherRole: .teen, otherAccountID: "leo", since: Date(), profiles: [profile]),
            list: list, imagePipeline: nil, router: nil
        ) { _, _, _ in }
        parentSide.loadViewIfNeeded()
        #expect(parentSide.dataSource.snapshot().indexOfSection(.sharing) == nil)
    }

    /// The words match what the app shares — time and limits — and the
    /// same four points before and after linking.
    @Test func theSummaryClaimsOnlyWhatTheAppShares() {
        let before = SupervisionConsent.lines(linked: false)
        let after = SupervisionConsent.lines(linked: true)
        #expect(before.count == 4 && after.count == 4)
        #expect(before.map(\.symbol) == after.map(\.symbol))
        let words = before.map(\.text).joined(separator: " ").lowercased()
        for claim in ["follow", "report", "message history", "location", "posts"] {
            #expect(!words.contains(claim), "the app shares no \(claim)")
        }
        #expect(after[2].text == "Shared since you linked, not before.")
    }
}
