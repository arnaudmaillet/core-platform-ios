import CoreModels
import CoreNavigation
import CoreStorage
import DesignSystem
import LaunchArguments
import UIKit

/// Staking likes on posts, with an undo toast: the ONE implementation (#2532,
/// ADR 0017). The post detail's composer, the Snap page's rail and footer
/// like, and every post card spend through a session; each host owns one and
/// says what varies by the posts it binds, the `lands` check it passes and
/// when it calls `end()`.
///
/// The rule it holds, for every host:
/// - **Wallet first.** The debit lands, or is refused, before a pixel moves;
///   every receipt says what the wallet `spent`, never the request (a stake
///   near the post's cap is clamped).
/// - **A burst** is what the viewer staked on one post since it opened. It
///   opens with the first spend, holds the undoable likes and owns the post's
///   toast. It ends with exactly one of: its toast's end, which commits it
///   (`commitStakes`); an undo, from the menu or the toast; a silent
///   take-back, when the post turns unavailable.
/// - **A burst is undoable exactly while its toast is up** (#1375), through
///   the toast or the menu, wherever the viewer has gone. The next tap after
///   a burst ended opens a new one from 0.
/// - **A shot is final** (owner's decision on #2532): a ×100 shot is sealed
///   and sent at once by the outbox, so it never joins the undoable tally. A
///   shot alone shows its toast without Undo; in a mixed burst the Undo takes
///   back the taps.
/// - **An undo says what came back**: the "−N" and the total are the post's
///   total before the undo minus after it, not the tally that was asked.
///
/// The receipts play on the control that asked when it still shows the post,
/// else on one that does. Every toast of a burst rises from the screen of the
/// burst's first spend while that screen is on screen, so two controls on one
/// post share one toast (`StakeMenu.undoToast`'s id).
///
/// A toast outlives its session: its closures hold the burst strongly and the
/// session weakly, so an undo or a commit after the surface has gone goes
/// through the wallet directly.
@MainActor
public final class StakeSession {
    private let wallet: any WalletStaking
    /// The controls and readouts, keyed by the object, weakly: a cell is
    /// recycled onto another post and simply bound again.
    private let controls = NSMapTable<AnyObject, NSString>.weakToStrongObjects()
    private let readouts = NSMapTable<AnyObject, NSString>.weakToStrongObjects()
    /// The live burst on each post.
    private var bursts: [String: StakeBurst] = [:]
    private var walletObservation: StoreObservation?
    /// True while the session itself moves the wallet: it redraws after,
    /// with the receipts, rather than from the observation inside the call.
    private var isMovingWallet = false

    /// What a host redraws beyond the bound controls after every change (the
    /// Snap page's footer like).
    public var onChange: (@MainActor () -> Void)?

    public init(wallet: any WalletStaking) {
        self.wallet = wallet
        walletObservation = wallet.changes.observeOnMain { [weak self] in
            guard let self, !self.isMovingWallet else { return }
            self.redrawAll()
        }
    }

    // MARK: - Binding

    /// `control` wears `post`'s stake from now on, and is drawn at once.
    public func bind(_ control: any StakeControl, to post: PostID) {
        readouts.removeObject(forKey: control)
        controls.setObject(post.rawValue as NSString, forKey: control)
        control.showStake(total: total(on: post), state: menuState(for: post), animated: false)
    }

    /// `readout` wears `post`'s total from now on, and is drawn at once.
    public func bindReadout(_ readout: any StakeTotalShowing, to post: PostID) {
        controls.removeObject(forKey: readout)
        readouts.setObject(post.rawValue as NSString, forKey: readout)
        readout.showStakeTotal(total(on: post))
    }

    /// `object` wears no stake any more.
    public func unbind(_ object: AnyObject) {
        controls.removeObject(forKey: object)
        readouts.removeObject(forKey: object)
    }

    // MARK: - Reading

    /// What the viewer has staked on `post`, from the wallet's ledger.
    public func total(on post: PostID) -> Int {
        wallet.boostTotal(forTarget: post.rawValue)
    }

    /// What the stake menu offers on `post` now.
    public func menuState(for post: PostID) -> StakeMenu.State {
        StakeMenu.State(
            balance: wallet.stakeableBalance,
            stakedOnTarget: total(on: post),
            undoable: liveBurst(on: post.rawValue)?.undoable ?? 0,
            perTargetCap: WalletStore.Policy.perTargetBoostCap,
            tapAmount: WalletStore.Policy.defaultStakeAmount,
            shotsLeft: wallet.stakeShots,
            shotAmount: WalletStore.Policy.StakePack.likesPerShot
        )
    }

    /// The stake menu for `post`, raised from `source` (a card's chip, a
    /// post's "…" menu). Nil for a guest (#1146): no amounts, no way into the
    /// Shop; their tap on the like still asks them to sign up.
    public func menu(for post: PostID, from source: UIResponder) -> UIMenu? {
        guard !MemberGates.isGuest(source) else { return nil }
        return StakeMenu.menu(
            for: menuState(for: post),
            stake: { [weak self, weak source] amount in
                guard let self, let source else { return }
                stake(.likes(amount), on: post, from: source)
            },
            shoot: { [weak self, weak source] in
                guard let self, let source else { return }
                stake(.shot, on: post, from: source)
            },
            undo: { [weak self, weak source] in self?.undo(on: post, from: source) },
            // The empty pack's row opens the Shop, found up the source's
            // responder chain (`StakeShopOpening`).
            openShop: StakeShop.openAction(from: source)
        )
    }

    // MARK: - Spending

    /// One stake on `post`: the member gate, then `lands` (asked again after
    /// a guest's sign-up, which finishes later), the wallet, the haptic, the
    /// receipt on the control and the burst's toast.
    public func stake(
        _ spend: WalletStakeSpend,
        on post: PostID,
        from source: UIResponder,
        lands: @escaping @MainActor () -> Bool = { true }
    ) {
        if case .likes(let amount) = spend, amount <= 0 { return }
        MemberGates.perform(.like, from: source) { [weak self, weak source] in
            guard let self, let source, lands() else { return }
            land(spend, on: post.rawValue, from: source)
        }
    }

    /// Takes back the live burst on `post`: the menu's Undo.
    public func undo(on post: PostID, from source: UIResponder? = nil) {
        guard let burst = liveBurst(on: post.rawValue) else { return }
        undo(burst, receiptFrom: source, silently: false)
    }

    /// Takes back the live burst on `post` without a receipt: the post turned
    /// unavailable (#1409), and there is nothing left to stake on.
    public func takeBack(_ post: PostID) {
        guard let burst = liveBurst(on: post.rawValue) else { return }
        undo(burst, receiptFrom: nil, silently: true)
    }

    /// The surface left the screen. A burst whose toast is up stays undoable:
    /// the toast follows the screen on top and commits it when it ends
    /// (#1375). A burst with no toast (no screen was found to show one) is
    /// committed now (#676).
    public func end() {
        for (key, burst) in bursts where !burst.hasToast {
            burst.commit()
            bursts[key] = nil
        }
    }

    private func land(_ spend: WalletStakeSpend, on key: String, from source: UIResponder) {
        let outcome = movingWallet { wallet.stake(spend, on: key) }
        let control = receiptControl(on: key, preferring: source)
        switch outcome {
        case .boosted(_, let targetTotal, let spent):
            let burst = liveBurst(on: key) ?? openBurst(on: key)
            burst.staked += spent
            // A shot is sealed and sent at once: never undoable (#2532).
            if case .likes = spend { burst.undoable += spent }
            burst.receipt = control
            Haptics.play(.commit)
            // Receipt before theatre: the total first, then the "+N".
            redraw(key, animated: true)
            control?.playStakeSpend(spent)
            showToast(for: burst, from: source)
            log("boosted post=\(key) requested=\(spend) spent=\(spent) targetTotal=\(targetTotal)")
        case .insufficientBalance, .targetCapReached, .noShotsLeft, .shotDoesNotFit:
            // The refusal is drawn on the control: no toast to say it twice.
            Haptics.play(.error)
            control?.playStakeRefusal()
            log("stake REFUSED post=\(key) requested=\(spend) outcome=\(outcome)")
        }
        onChange?()
    }

    private func undo(_ burst: StakeBurst, receiptFrom source: UIResponder?, silently: Bool) {
        guard burst.undoable > 0 else { return }
        let key = burst.post
        let before = wallet.boostTotal(forTarget: key)
        _ = movingWallet { wallet.undoBoost(targetID: key, amount: burst.undoable) }
        // What came back, which the outbox decides: taps it already sealed
        // stay sent.
        let refunded = before - wallet.boostTotal(forTarget: key)
        burst.undoable = 0
        // Taken back: the toast closing must not send it.
        burst.invalidateToasts()
        StakeMenu.closeUndoToast(burst.toast)
        if bursts[key] === burst { bursts[key] = nil }
        // Turning off is silent (#1881): no haptic.
        redraw(key, animated: !silently)
        if !silently, refunded > 0 {
            let control = source.flatMap { receiptControl(on: key, preferring: $0) }
                ?? burst.receipt.flatMap { isBound($0, to: key) ? $0 : nil }
                ?? firstControl(on: key)
            control?.playStakeRefund(refunded)
        }
        log("stake UNDO post=\(key) refunded=\(refunded) targetTotal=\(wallet.boostTotal(forTarget: key))")
        onChange?()
    }

    /// The burst's toast ended without an undo and sent it.
    private func burstCommitted(_ burst: StakeBurst) {
        if bursts[burst.post] === burst { bursts[burst.post] = nil }
        redraw(burst.post, animated: false)
        onChange?()
    }

    // MARK: - Bursts and toasts

    /// The burst still open on `key`. A burst with nothing undoable whose
    /// toast has gone (a shot alone) has ended.
    private func liveBurst(on key: String) -> StakeBurst? {
        guard let burst = bursts[key] else { return nil }
        if burst.undoable == 0, !burst.hasToast {
            bursts[key] = nil
            return nil
        }
        return burst
    }

    private func openBurst(on key: String) -> StakeBurst {
        let burst = StakeBurst(post: key, wallet: wallet)
        bursts[key] = burst
        return burst
    }

    /// The burst so far, from the screen of its first spend while that screen
    /// is on screen (one toast for every control on the post), else from
    /// `source`'s. With Undo while it holds taps; a shot alone has none.
    private func showToast(for burst: StakeBurst, from source: UIResponder) {
        guard let screen = burst.screenOnScreen ?? Self.screen(of: source) else { return }
        burst.screen = screen
        // Numbered first: the toast this one updates or replaces is settled
        // during the call, and its commit must then do nothing.
        let generation = burst.nextToast()
        guard burst.undoable > 0 else {
            burst.toast = Feedback.info(
                StakeMenu.stakedToastMessage(burst.staked), symbol: LikesSymbol.glyph, from: screen,
                id: "stake-final-\(ObjectIdentifier(screen).hashValue)-\(burst.post)"
            )
            return
        }
        burst.toast = StakeMenu.undoToast(
            staked: burst.staked, on: burst.post, from: screen,
            commit: { [weak self] in
                guard burst.isCurrentToast(generation) else { return }
                burst.commit()
                self?.burstCommitted(burst)
            },
            undo: { [weak self] in
                if let self {
                    undo(burst, receiptFrom: nil, silently: false)
                } else {
                    // The surface is gone; the toast is not.
                    burst.takeBackFromWallet()
                }
            }
        )
    }

    private static func screen(of source: UIResponder) -> UIViewController? {
        var responder: UIResponder? = source
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    // MARK: - Drawing

    /// The control that plays a receipt on `key`: `source` when it is a
    /// control still showing the post, else one that shows it.
    private func receiptControl(on key: String, preferring source: UIResponder) -> (any StakeControl)? {
        if let control = source as? any StakeControl, isBound(control, to: key) { return control }
        return firstControl(on: key)
    }

    private func isBound(_ object: AnyObject, to key: String) -> Bool {
        (controls.object(forKey: object) as String?) == key
    }

    private func firstControl(on key: String) -> (any StakeControl)? {
        boundControls().first { $0.key == key }?.control
    }

    private func boundControls() -> [(control: any StakeControl, key: String)] {
        var found: [(control: any StakeControl, key: String)] = []
        let enumerator = controls.keyEnumerator()
        while let control = enumerator.nextObject() as? any StakeControl {
            guard let key = controls.object(forKey: control) as String? else { continue }
            found.append((control, key))
        }
        return found
    }

    /// Every control and readout bound to `key` reads the wallet back.
    private func redraw(_ key: String, animated: Bool) {
        let post = PostID(key)
        let total = total(on: post)
        let state = menuState(for: post)
        for bound in boundControls() where bound.key == key {
            bound.control.showStake(total: total, state: state, animated: animated)
        }
        redrawReadouts { $0 == key }
    }

    /// The wallet moved (a stake elsewhere, a refund, a pack): everything
    /// bound reads it back.
    private func redrawAll() {
        for bound in boundControls() {
            let post = PostID(bound.key)
            bound.control.showStake(total: total(on: post), state: menuState(for: post), animated: false)
        }
        redrawReadouts { _ in true }
        onChange?()
    }

    private func redrawReadouts(where includes: (String) -> Bool) {
        let enumerator = readouts.keyEnumerator()
        while let readout = enumerator.nextObject() as? any StakeTotalShowing {
            guard let key = readouts.object(forKey: readout) as String?, includes(key) else { continue }
            readout.showStakeTotal(wallet.boostTotal(forTarget: key))
        }
    }

    private func movingWallet<Value>(_ body: () -> Value) -> Value {
        isMovingWallet = true
        defer { isMovingWallet = false }
        return body()
    }

    /// `-wallet-log`: one line per stake, refusal and undo, on every surface.
    private func log(_ line: @autoclosure () -> String) {
        #if DEBUG
        guard LaunchArgument.walletLog.isPassed() else { return }
        print("[wallet] \(line()) balance=\(wallet.balance) shots=\(wallet.stakeShots)")
        #endif
    }
}

/// One post's burst: what it staked, what can still be taken back, and its
/// toast. A class, so a toast's closures can still reach it once the session
/// that opened it is gone.
@MainActor
final class StakeBurst {
    let post: String
    private let wallet: any WalletStaking
    /// Everything the burst staked, shots included: the toast's words.
    var staked = 0
    /// The taps the outbox still holds: what an undo asks back.
    var undoable = 0
    /// The control the last "+N" played on: where an undo's "−N" plays.
    weak var receipt: (any StakeControl)?
    weak var toast: ToastView?
    weak var screen: UIViewController?
    /// Numbers the burst's toasts: an update settles the toast before it,
    /// whose commit must then do nothing.
    private let toasts = StakeMenu.Burst()

    init(post: String, wallet: any WalletStaking) {
        self.post = post
        self.wallet = wallet
    }

    var hasToast: Bool { toast.map { !$0.isDismissing } ?? false }

    /// The screen of the burst's first spend, while it is on screen.
    var screenOnScreen: UIViewController? {
        screen?.viewIfLoaded?.window == nil ? nil : screen
    }

    func nextToast() -> Int { toasts.next() }
    func isCurrentToast(_ generation: Int) -> Bool { toasts.isCurrent(generation) }
    func invalidateToasts() { _ = toasts.next() }

    /// Sends the burst: its taps are sealed now rather than 10 s after the
    /// last one (#676).
    func commit() {
        invalidateToasts()
        guard undoable > 0 else { return }
        undoable = 0
        wallet.commitStakes(on: post)
    }

    /// The toast's Undo once the session has gone: straight from the wallet.
    func takeBackFromWallet() {
        guard undoable > 0 else { return }
        _ = wallet.undoBoost(targetID: post, amount: undoable)
        undoable = 0
    }
}
