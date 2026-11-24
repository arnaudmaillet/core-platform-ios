import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import Testing
import UIKit
@testable import PostGrid

/// The one stake session (#2532): a member's wallet with its outbox, so an
/// undo takes back only what the outbox still holds, as on a device.
///
/// Every test runs in one main-actor turn: no toast's clock can fire in the
/// middle of one.
@MainActor
@Suite(.serialized)
struct StakeSessionTests {
    private let post = PostID("post-1")
    private var key: String { post.rawValue }
    private let tap = WalletStore.Policy.defaultStakeAmount
    private let shot = WalletStore.Policy.StakePack.likesPerShot

    /// A member's wallet with a like outbox, and `balance` likes.
    private static func memberWallet(balance: Int? = nil) -> (WalletStore, LikeOutbox) {
        let name = "stake-session-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        if let balance {
            defaults.set(true, forKey: "wallet.seeded")
            defaults.set(balance, forKey: "wallet.balance")
        }
        let scope = StorageScope(owner: .member(account: "acct-1", profile: "prof-1"))
        let wallet = WalletStore(defaults: defaults, scope: scope)
        let outbox = LikeOutbox(defaults: defaults, scope: scope)
        wallet.likeOutbox = outbox
        return (wallet, outbox)
    }

    /// A window with one screen, whose toasts are drawn in its view (a test
    /// host has no scene overlay).
    @MainActor
    private final class Stage {
        let screen = UIViewController()
        func add(_ view: UIView) { screen.view.addSubview(view) }
        var toasts: [ToastView] { screen.view.subviews.compactMap { $0 as? ToastView }.filter { !$0.isDismissing } }
    }

    /// A stage in a visible window, taken down within the test (TEST_TRAPS):
    /// a window released visible in the turn that dirtied it is laid out
    /// after it is freed, and crashes the host in another suite.
    private func hosting(_ body: (Stage) throws -> Void) rethrows {
        let stage = Stage()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = stage.screen
        window.isHidden = false
        window.layoutIfNeeded()
        defer {
            window.rootViewController = nil
            window.subviews.forEach { $0.removeFromSuperview() }
            window.isHidden = true
            window.layoutIfNeeded()
        }
        try body(stage)
    }

    private static func undoAction(of toast: ToastView) -> UIAccessibilityCustomAction? {
        toast.accessibilityCustomActions?.first { $0.name == "Undo" }
    }

    // MARK: - Spending

    /// Wallet first, then the total, then the "+N" on the control that asked;
    /// a stake is a weighty action (`commit`).
    @Test func aStakeLandsInTheWalletThenDrawsTheTotalThenTheReceipt() {
        let (wallet, _) = Self.memberWallet()
        let before = wallet.balance
        hosting { stage in
            let control = RecordingControl()
            stage.add(control)
            let stakes = StakeSession(wallet: wallet)
            stakes.bind(control, to: post)
            control.calls.removeAll()

            let haptics = HapticRecorder.recording { stakes.stake(.likes(tap), on: post, from: control) }

            #expect(haptics == [.commit])
            #expect(wallet.balance == before - tap)
            #expect(control.calls == [.show(total: tap, undoable: tap, animated: true), .spend(tap)])
            #expect(stakes.menuState(for: post).undoable == tap)
        }
    }

    /// Near the post's cap the wallet clamps, and every receipt says what it
    /// spent, never the request.
    @Test func aStakeNearTheCapIsClampedAndTheReceiptSaysWhatWasSpent() {
        let (wallet, _) = Self.memberWallet(balance: 1_000)
        let control = RecordingControl()
        let stakes = StakeSession(wallet: wallet)
        stakes.bind(control, to: post)
        stakes.stake(.likes(WalletStore.Policy.perTargetBoostCap - 3), on: post, from: control)
        control.calls.removeAll()

        stakes.stake(.likes(10), on: post, from: control)

        #expect(wallet.boostTotal(forTarget: key) == WalletStore.Policy.perTargetBoostCap)
        #expect(control.calls.last == .spend(3))
    }

    /// A refusal changes nothing, shakes the control, errs, and raises no
    /// toast: the control already says it.
    @Test func aRefusalShakesTheControlAndRaisesNoToast() {
        let (wallet, _) = Self.memberWallet(balance: 0)
        hosting { stage in
            let control = RecordingControl()
            stage.add(control)
            let stakes = StakeSession(wallet: wallet)
            stakes.bind(control, to: post)
            control.calls.removeAll()

            let haptics = HapticRecorder.recording { stakes.stake(.likes(tap), on: post, from: control) }
            // No pack: a shot is refused too.
            stakes.stake(.shot, on: post, from: control)

            #expect(haptics == [.error])
            #expect(control.calls == [.refusal, .refusal])
            #expect(wallet.boostTotal(forTarget: key) == 0)
            #expect(stage.toasts.isEmpty)
        }
    }

    /// A stake that no longer lands (the post went unavailable while a guest
    /// signed up) spends nothing.
    @Test func aStakeThatNoLongerLandsSpendsNothing() {
        let (wallet, _) = Self.memberWallet()
        let before = wallet.balance
        let stakes = StakeSession(wallet: wallet)
        let control = RecordingControl()

        stakes.stake(.likes(tap), on: post, from: control, lands: { false })

        #expect(wallet.balance == before)
    }

    // MARK: - The burst and its toast

    /// A burst of taps shows ONE toast with the burst so far, and its Undo
    /// takes all of it back, silently (#957, #1881).
    @Test func aBurstShowsOneToastUpdatedInPlaceAndItsUndoTakesItAllBack() throws {
        let (wallet, _) = Self.memberWallet()
        let before = wallet.balance
        try hosting { stage in
            let control = RecordingControl()
            stage.add(control)
            let stakes = StakeSession(wallet: wallet)
            stakes.bind(control, to: post)

            stakes.stake(.likes(tap), on: post, from: control)
            stakes.stake(.likes(tap), on: post, from: control)

            let toast = try #require(stage.toasts.first)
            #expect(stage.toasts.count == 1)
            #expect(toast.message == StakeMenu.stakedToastMessage(2 * tap))
            let undo = try #require(Self.undoAction(of: toast))
            let haptics = HapticRecorder.recording { _ = undo.actionHandler?(undo) }
            #expect(haptics.isEmpty, "an undo played \(haptics)")
            #expect(wallet.balance == before)
            #expect(stakes.menuState(for: post).undoable == 0)
            #expect(control.calls.last == .refund(2 * tap))
        }
    }

    /// The toast's end sends the burst and ends it: no stale Undo after it,
    /// and the next tap opens a new burst from 0 (§ 3 row 1).
    @Test func theToastsEndSendsTheBurstAndTheNextTapStartsFromZero() throws {
        let (wallet, outbox) = Self.memberWallet()
        try hosting { stage in
            let control = RecordingControl()
            stage.add(control)
            let stakes = StakeSession(wallet: wallet)
            stakes.bind(control, to: post)
            stakes.stake(.likes(tap), on: post, from: control)
            stakes.stake(.likes(tap), on: post, from: control)

            StakeMenu.closeUndoToast(try #require(stage.toasts.first))

            #expect(outbox.batches.map(\.isSealed) == [true], "the toast ending sends the burst")
            #expect(stakes.menuState(for: post).undoable == 0, "an Undo outlived its toast")
            #expect(control.calls.last == .show(total: 2 * tap, undoable: 0, animated: false))
            stakes.stake(.likes(tap), on: post, from: control)
            let next = try #require(stage.toasts.first)
            #expect(next.message == StakeMenu.stakedToastMessage(tap))
            #expect(stakes.menuState(for: post).undoable == tap)
        }
    }

    /// The toast is the undo window (#1375): leaving keeps the burst
    /// undoable, through the toast and through the menu, while its toast is
    /// up (Q2).
    @Test func leavingKeepsTheToastsBurstUndoableThroughTheMenu() throws {
        let (wallet, outbox) = Self.memberWallet()
        let before = wallet.balance
        try hosting { stage in
            let control = RecordingControl()
            stage.add(control)
            let stakes = StakeSession(wallet: wallet)
            stakes.bind(control, to: post)
            stakes.stake(.likes(tap), on: post, from: control)

            stakes.end()

            #expect(outbox.batches.map(\.isSealed) == [false], "leaving sent a burst whose toast is up")
            #expect(stakes.menuState(for: post).undoable == tap)
            let undo = try #require(stakes.menu(for: post, from: control)?.children.last as? UIAction)
            #expect(undo.title == "Undo stakes (\(tap))")
            undo.performWithSender(nil, target: nil)
            #expect(wallet.balance == before)
            #expect(stage.toasts.isEmpty, "the menu's Undo left the toast up")
        }
    }

    /// The toast outlives its surface: its Undo still refunds the burst once
    /// the session has gone.
    @Test func theToastsUndoRefundsOnceTheSessionHasGone() throws {
        let (wallet, _) = Self.memberWallet()
        let before = wallet.balance
        try hosting { stage in
            let control = RecordingControl()
            stage.add(control)
            var stakes: StakeSession? = StakeSession(wallet: wallet)
            stakes?.bind(control, to: post)
            stakes?.stake(.likes(tap), on: post, from: control)
            weak var gone = stakes
            stakes = nil
            #expect(gone == nil)

            let toast = try #require(stage.toasts.first)
            let undo = try #require(Self.undoAction(of: toast))
            _ = undo.actionHandler?(undo)

            #expect(wallet.balance == before)
            #expect(wallet.boostTotal(forTarget: key) == 0)
        }
    }

    /// Leaving commits a burst that has no toast (no screen was found to
    /// show one) at once (#676).
    @Test func leavingSendsABurstThatHasNoToast() {
        let (wallet, outbox) = Self.memberWallet()
        let control = RecordingControl()
        let stakes = StakeSession(wallet: wallet)
        stakes.bind(control, to: post)
        stakes.stake(.likes(tap), on: post, from: control)
        #expect(outbox.batches.map(\.isSealed) == [false])

        stakes.end()

        #expect(outbox.batches.map(\.isSealed) == [true])
        #expect(stakes.menuState(for: post).undoable == 0)
    }

    // MARK: - Shots (Q1: a shot is final)

    /// Bug 1 of the design doc: a shot was offered an Undo that gave nothing
    /// back. A shot alone now shows its toast WITHOUT Undo, and the menu has
    /// no Undo either.
    @Test func aShotAloneShowsAToastWithoutUndo() throws {
        let (wallet, outbox) = Self.memberWallet()
        wallet.buyStakePack()
        try hosting { stage in
            let control = RecordingControl()
            stage.add(control)
            let stakes = StakeSession(wallet: wallet)
            stakes.bind(control, to: post)

            stakes.stake(.shot, on: post, from: control)

            let toast = try #require(stage.toasts.first)
            #expect(toast.message == StakeMenu.stakedToastMessage(shot))
            #expect(Self.undoAction(of: toast) == nil, "a shot's toast offers an Undo that cannot work")
            #expect(stakes.menuState(for: post).undoable == 0)
            let menu = try #require(stakes.menu(for: post, from: control))
            #expect(!menu.children.contains { ($0 as? UIAction)?.title.hasPrefix("Undo") == true })
            #expect(outbox.batches.map(\.isSealed) == [true], "a shot is sent at once")
            #expect(wallet.boostTotal(forTarget: key) == shot)
        }
    }

    /// Bug 2 of the design doc: the "−N" said the whole tally. In a burst of
    /// taps and a shot, Undo takes back the taps, and the receipt and the
    /// total say exactly what came back.
    @Test func anUndoAfterTapsAndAShotGivesBackTheTapsAndSaysSo() throws {
        let (wallet, _) = Self.memberWallet()
        wallet.buyStakePack()
        try hosting { stage in
            let control = RecordingControl()
            stage.add(control)
            let stakes = StakeSession(wallet: wallet)
            stakes.bind(control, to: post)
            stakes.stake(.likes(tap), on: post, from: control)
            stakes.stake(.likes(tap), on: post, from: control)
            stakes.stake(.shot, on: post, from: control)
            let balance = wallet.balance

            let toast = try #require(stage.toasts.first)
            #expect(stage.toasts.count == 1)
            #expect(toast.message == StakeMenu.stakedToastMessage(2 * tap + shot))
            #expect(stakes.menuState(for: post).undoable == 2 * tap)
            let undo = try #require(Self.undoAction(of: toast))
            _ = undo.actionHandler?(undo)

            #expect(wallet.balance == balance + 2 * tap)
            #expect(wallet.boostTotal(forTarget: key) == shot)
            #expect(control.calls.suffix(2) == [.show(total: shot, undoable: 0, animated: true), .refund(2 * tap)])
        }
    }

    // MARK: - Several controls, one session

    /// Two controls on one post (a text page's bar and its rail) share one
    /// burst and ONE toast; the receipt plays on the control that asked.
    @Test func twoControlsOnOnePostShareOneBurstAndOneToast() throws {
        let (wallet, _) = Self.memberWallet()
        try hosting { stage in
            let bar = RecordingControl()
            let rail = RecordingControl()
            let child = UIViewController()
            stage.screen.addChild(child)
            stage.add(child.view)
            child.didMove(toParent: stage.screen)
            child.view.addSubview(bar)
            stage.add(rail)
            let stakes = StakeSession(wallet: wallet)
            stakes.bind(bar, to: post)
            stakes.bind(rail, to: post)
            bar.calls.removeAll()
            rail.calls.removeAll()

            stakes.stake(.likes(tap), on: post, from: bar)
            stakes.stake(.likes(tap), on: post, from: rail)

            let toasts = (child.view.subviews + stage.screen.view.subviews).compactMap { $0 as? ToastView }
                .filter { !$0.isDismissing }
            #expect(toasts.count == 1)
            #expect(toasts.first?.message == StakeMenu.stakedToastMessage(2 * tap))
            #expect(bar.calls.contains(.spend(tap)) && rail.calls.contains(.spend(tap)))
            #expect(bar.calls.last == .show(total: 2 * tap, undoable: 2 * tap, animated: true), "the bar missed the rail's stake")
            #expect(stakes.menuState(for: post).undoable == 2 * tap)
        }
    }

    /// A post that turned unavailable takes its burst back silently: no
    /// receipt, no haptic, and its toast closes (#1409).
    @Test func aTakeBackIsSilentAndClosesTheToast() {
        let (wallet, _) = Self.memberWallet()
        let before = wallet.balance
        hosting { stage in
            let control = RecordingControl()
            stage.add(control)
            let stakes = StakeSession(wallet: wallet)
            stakes.bind(control, to: post)
            stakes.stake(.likes(tap), on: post, from: control)
            control.calls.removeAll()

            let haptics = HapticRecorder.recording { stakes.takeBack(post) }

            #expect(haptics.isEmpty)
            #expect(wallet.balance == before)
            #expect(control.calls == [.show(total: 0, undoable: 0, animated: false)])
            #expect(stage.toasts.isEmpty)
        }
    }

    /// A stake made elsewhere (another session on the same wallet) redraws
    /// every bound control and readout at once.
    @Test func aStakeElsewhereRedrawsTheBoundControlsAndReadouts() {
        let (wallet, _) = Self.memberWallet()
        let control = RecordingControl()
        let readout = RecordingReadout()
        let stakes = StakeSession(wallet: wallet)
        var changes = 0
        stakes.onChange = { changes += 1 }
        stakes.bind(control, to: post)
        stakes.bindReadout(readout, to: post)

        StakeSession(wallet: wallet).stake(.likes(tap), on: post, from: UIView())

        #expect(control.calls.last == .show(total: tap, undoable: 0, animated: false))
        #expect(readout.totals.last == tap)
        #expect(changes > 0)
    }

    /// The shell's gate, up a control's chain.
    private final class GateHolder: UIViewController, MemberGateProviding {
        let memberGate: any MemberGating = MemberGate(isMember: false)
    }

    /// A guest gets no stake menu (#1146).
    @Test func aGuestGetsNoStakeMenu() {
        let (wallet, _) = Self.memberWallet()
        let holder = GateHolder()
        let control = RecordingControl()
        holder.view.addSubview(control)
        #expect(StakeSession(wallet: wallet).menu(for: post, from: control) == nil)
    }
}

/// A stake control that records what the session asks of it.
@MainActor
final class RecordingControl: UIView, StakeControl {
    enum Call: Equatable {
        case show(total: Int, undoable: Int, animated: Bool)
        case spend(Int)
        case refund(Int)
        case refusal
    }

    var calls: [Call] = []

    func showStake(total: Int, state: StakeMenu.State, animated: Bool) {
        calls.append(.show(total: total, undoable: state.undoable, animated: animated))
    }

    func playStakeSpend(_ amount: Int) { calls.append(.spend(amount)) }
    func playStakeRefund(_ amount: Int) { calls.append(.refund(amount)) }
    func playStakeRefusal() { calls.append(.refusal) }
}

/// A readout that records the totals it is told.
@MainActor
final class RecordingReadout: StakeTotalShowing {
    var totals: [Int] = []
    func showStakeTotal(_ total: Int) { totals.append(total) }
}
