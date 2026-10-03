import CoreModels
import Testing

/// Stands in for the app's sheet: records what it was asked to show and
/// answers when the test says so.
@MainActor
private final class FakeSignUpPresenter: SignUpPresenting {
    private(set) var presented: [GatedAction?] = []
    private var completion: (@MainActor (Bool) -> Void)?

    func presentSignUp(for action: GatedAction?, completion: @escaping @MainActor (Bool) -> Void) {
        presented.append(action)
        self.completion = completion
    }

    func finish(signedIn: Bool) {
        completion?(signedIn)
        completion = nil
    }
}

@MainActor
struct MemberGateTests {
    private func waitUntilPresented(_ presenter: FakeSignUpPresenter) async {
        while presenter.presented.isEmpty { await Task.yield() }
    }

    @Test func aMemberPassesWithoutASheet() async {
        let presenter = FakeSignUpPresenter()
        let gate = MemberGate(isMember: true)
        gate.presenter = presenter

        #expect(await gate.requireMember(for: .like))
        #expect(presenter.presented.isEmpty)
    }

    @Test func aGuestWhoClosesTheSheetDoesNotPass() async {
        let presenter = FakeSignUpPresenter()
        let gate = MemberGate()
        gate.presenter = presenter

        async let passed = gate.requireMember(for: .comment)
        await waitUntilPresented(presenter)
        presenter.finish(signedIn: false)

        #expect(await passed == false)
        #expect(presenter.presented == [.comment])
    }

    @Test func aGuestWhoSignsUpPassesAndTheActionCarriesOn() async {
        let presenter = FakeSignUpPresenter()
        let gate = MemberGate()
        gate.presenter = presenter

        async let passed = gate.requireMember(for: .follow(handle: "ava.moreau"))
        await waitUntilPresented(presenter)
        presenter.finish(signedIn: true)

        #expect(await passed)
    }

    /// A second gated tap while the sheet is up joins it: one sheet, and both
    /// callers hear the same answer.
    @Test func concurrentRequestsShareOneSheet() async {
        let presenter = FakeSignUpPresenter()
        let gate = MemberGate()
        gate.presenter = presenter

        async let first = gate.requireMember(for: .like)
        await waitUntilPresented(presenter)
        async let second = gate.requireMember(for: .save)
        // Let the second request reach the gate (it joins the waiters on its
        // first turn; a few turns cover a busy executor).
        for _ in 0..<10 { await Task.yield() }
        presenter.finish(signedIn: true)

        #expect(await first)
        #expect(await second)
        #expect(presenter.presented.count == 1)
    }

    @Test func withNothingToPresentTheSheetAGuestDoesNotPass() async {
        let gate = MemberGate()

        #expect(await gate.requireMember(for: .create) == false)
    }

    @Test func thePromptNamesTheReason() {
        #expect(GatedAction.follow(handle: "ava.moreau").signUpPrompt == "Sign up to follow @ava.moreau")
        #expect(GatedAction.follow(handle: nil).signUpPrompt == "Sign up to follow")
        #expect(GatedAction.like.signUpPrompt == "Sign up to like this post")
    }
}
