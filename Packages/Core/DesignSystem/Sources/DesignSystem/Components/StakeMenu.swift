import UIKit

/// The amounts a long press on a STAKE control offers — the feed rail's
/// boost button and every card's like chip, one menu, so the two doors to the
/// same spend can never offer different things.
///
/// Built from plain numbers rather than from the wallet: DesignSystem sits
/// below the store, and the hosts that own one (Feed, Profile) push its
/// answer in.
@MainActor
public enum StakeMenu {
    /// What the menu is built from, at the moment it is raised.
    public struct State: Equatable, Sendable {
        /// Points the viewer can spend.
        public var balance: Int
        /// What the viewer has ALREADY staked on this post.
        public var stakedOnTarget: Int
        /// What this surface can still take back (its session's spend).
        public var undoable: Int
        /// The most one viewer can stake on one post.
        public var perTargetCap: Int
        /// The fixed amounts offered besides Max.
        public var denominations: [Int]
        /// What a plain tap spends.
        public var tapAmount: Int

        public init(
            balance: Int, stakedOnTarget: Int, undoable: Int,
            perTargetCap: Int, denominations: [Int], tapAmount: Int
        ) {
            self.balance = balance
            self.stakedOnTarget = stakedOnTarget
            self.undoable = undoable
            self.perTargetCap = perTargetCap
            self.denominations = denominations
            self.tapAmount = tapAmount
        }

        /// Room left under the per-post cap.
        public var remaining: Int { max(0, perTargetCap - stakedOnTarget) }

        /// Whether a plain tap can spend anything: near the cap it costs only
        /// the remainder (the store clamps), so that is what is judged.
        public var canTap: Bool {
            let cost = min(tapAmount, remaining)
            return remaining > 0 && balance >= cost
        }

        /// What Max would actually spend.
        public var maxAmount: Int { min(remaining, balance) }
    }

    public nonisolated static let title = "Stake on this post"

    /// The menu, top to bottom: **Max** (what a fill-up would actually
    /// spend), the fixed denomination(s), and Undo while the surface holds a
    /// spend to take back. Unaffordable entries are drawn DISABLED rather than
    /// left out, so the menu always says what exists.
    public static func elements(
        for state: State,
        stake: @escaping @MainActor (Int) -> Void,
        undo: (@MainActor () -> Void)?
    ) -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        // The label names the REAL spend when one is possible; disabled it
        // still names the door (the remainder, or the cap on a full post).
        let maxAmount = state.maxAmount
        let shownMax = maxAmount > 0
            ? maxAmount
            : (state.remaining > 0 ? state.remaining : state.perTargetCap)
        let maxAction = UIAction(
            title: "Max (\(shownMax) points)",
            image: UIImage(systemName: PointsSymbol.glyph)
        ) { _ in stake(maxAmount) }
        if maxAmount <= 0 { maxAction.attributes = .disabled }
        actions.append(maxAction)

        for amount in state.denominations.reversed() {
            let action = UIAction(
                title: "\(amount) points",
                image: UIImage(systemName: PointsSymbol.glyph)
            ) { _ in stake(amount) }
            if amount > state.balance || amount > state.remaining { action.attributes = .disabled }
            actions.append(action)
        }
        if state.undoable > 0, let undo {
            actions.append(UIAction(
                title: "Undo stakes (\(state.undoable))",
                image: UIImage(systemName: "arrow.uturn.backward"),
                attributes: .destructive
            ) { _ in undo() })
        }
        return actions
    }

    /// The whole menu, titled.
    public static func menu(
        for state: State,
        stake: @escaping @MainActor (Int) -> Void,
        undo: (@MainActor () -> Void)?
    ) -> UIMenu {
        UIMenu(title: title, children: elements(for: state, stake: stake, undo: undo))
    }
}
