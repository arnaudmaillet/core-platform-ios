import CoreModels
import Testing
import UIKit
@testable import CoreNavigation

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

/// A controller that holds the gate, as the shell's tab bar controller does.
private final class GateHolder: UIViewController, MemberGateProviding {
    let memberGate: any MemberGating
    init(gate: any MemberGating) {
        memberGate = gate
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
struct MemberGatesTests {
    /// A control inside the holder's view, so the lookup climbs the chain.
    private func control(in holder: GateHolder) -> UIButton {
        let button = UIButton()
        holder.view.addSubview(button)
        return button
    }

    @Test func aMemberRunsTheActionInTheSameTurn() {
        let holder = GateHolder(gate: MemberGate(isMember: true))
        var ran = false

        MemberGates.perform(.like, from: control(in: holder)) { ran = true }

        #expect(ran)
    }

    @Test func withNoGateUpTheChainTheActionRuns() {
        var ran = false

        MemberGates.perform(.like, from: UIButton()) { ran = true }

        #expect(ran)
    }

    @Test func aGuestRunsTheActionOnlyAfterSigningUp() async {
        let presenter = FakeSignUpPresenter()
        let gate = MemberGate()
        gate.presenter = presenter
        let holder = GateHolder(gate: gate)
        var ran = false

        MemberGates.perform(.save, from: control(in: holder)) { ran = true }
        #expect(!ran)
        while presenter.presented.isEmpty { await Task.yield() }
        presenter.finish(signedIn: true)
        for _ in 0..<10 where !ran { await Task.yield() }

        #expect(ran)
        #expect(presenter.presented == [.save])
    }

    @Test func aGuestWhoClosesTheSheetNeverRunsTheAction() async {
        let presenter = FakeSignUpPresenter()
        let gate = MemberGate()
        gate.presenter = presenter
        let holder = GateHolder(gate: gate)
        var ran = false

        MemberGates.perform(.create, from: control(in: holder)) { ran = true }
        while presenter.presented.isEmpty { await Task.yield() }
        presenter.finish(signedIn: false)
        for _ in 0..<10 { await Task.yield() }

        #expect(!ran)
    }
}
