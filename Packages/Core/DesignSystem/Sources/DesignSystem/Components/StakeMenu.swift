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
        /// What a plain tap spends — the default amount, and the menu's only
        /// plain amount.
        public var tapAmount: Int
        /// Shots left in the viewer's ×100 cartridge pack; 0 = no pack.
        public var shotsLeft: Int
        /// What ONE shot stakes.
        public var shotAmount: Int

        public init(
            balance: Int, stakedOnTarget: Int, undoable: Int,
            perTargetCap: Int, tapAmount: Int, shotsLeft: Int, shotAmount: Int
        ) {
            self.balance = balance
            self.stakedOnTarget = stakedOnTarget
            self.undoable = undoable
            self.perTargetCap = perTargetCap
            self.tapAmount = tapAmount
            self.shotsLeft = shotsLeft
            self.shotAmount = shotAmount
        }

        /// Room left under the per-post cap.
        public var remaining: Int { max(0, perTargetCap - stakedOnTarget) }

        /// Whether a plain tap can spend anything: near the cap it costs only
        /// the remainder (the store clamps), so that is what is judged.
        public var canTap: Bool {
            let cost = min(tapAmount, remaining)
            return remaining > 0 && balance >= cost
        }

        /// Whether a shot can fire its WHOLE amount: a loaded pack, the
        /// points, and room for all of them on this post. A shot the cap
        /// would clamp is not offered — a pack's shot is worth its number.
        public var canShoot: Bool {
            shotsLeft > 0 && balance >= shotAmount && remaining >= shotAmount
        }
    }

    public nonisolated static let title = "Stake on this post"

    /// The menu, top to bottom: the ×100 SHOT (loaded: "×100 — N left"; no
    /// pack: "Get ×100 cartridges in the Shop", which OPENS the Shop on its
    /// Boosts through `openShop`), the default amount, and Undo while the
    /// surface holds a spend to take back.
    ///
    /// ⚠️ **NO MULTI-POINT AMOUNT IS FREE.** Staking several points in one
    /// gesture is what the shop's ×100 cartridge pack sells (2026-10-02): the
    /// menu used to offer Max and 100 to everyone, and now offers only the
    /// default amount unless a pack is loaded. Unavailable entries are drawn
    /// DISABLED rather than left out, with a subtitle saying why, so the menu
    /// always says what exists and how to get it. The one exception is the
    /// empty pack's row: it is the way TO the pack, so with an `openShop` it
    /// is enabled and opens the Shop (2026-10-02) — without one (no shop
    /// sells packs: the fleet, a test host) it stays a disabled signpost.
    public static func elements(
        for state: State,
        stake: @escaping @MainActor (Int) -> Void,
        shoot: @escaping @MainActor () -> Void,
        undo: (@MainActor () -> Void)?,
        openShop: (@MainActor () -> Void)? = nil
    ) -> [UIMenuElement] {
        var actions: [UIMenuElement] = [shotAction(for: state, shoot: shoot, openShop: openShop)]

        let tap = UIAction(
            title: points(state.tapAmount),
            image: UIImage(systemName: PointsSymbol.glyph)
        ) { _ in stake(state.tapAmount) }
        if !state.canTap { tap.attributes = .disabled }
        actions.append(tap)

        if state.undoable > 0, let undo {
            actions.append(UIAction(
                title: "Undo stakes (\(state.undoable))",
                image: UIImage(systemName: "arrow.uturn.backward"),
                attributes: .destructive
            ) { _ in undo() })
        }
        return actions
    }

    /// The pack's name, after what one shot stakes: "×100". The shop's row
    /// and the menu's entry both read it.
    public nonisolated static func shotName(_ shotAmount: Int) -> String { "×\(shotAmount)" }

    /// The shot glyph — the menu's entry and the shop's row.
    public nonisolated static let shotGlyph = "bolt.fill"

    /// "×100 — 2 left" with a pack. Without one, "×100 · Get ×100 cartridges
    /// in the Shop": the Shop's door when there is one, disabled when not.
    private static func shotAction(
        for state: State, shoot: @escaping @MainActor () -> Void, openShop: (@MainActor () -> Void)?
    ) -> UIAction {
        let name = shotName(state.shotAmount)
        guard state.shotsLeft > 0 else {
            let action = UIAction(title: name, image: UIImage(systemName: shotGlyph)) { _ in openShop?() }
            action.subtitle = shopSubtitle(state.shotAmount)
            if openShop == nil { action.attributes = .disabled }
            return action
        }
        let action = UIAction(
            title: "\(name) — \(state.shotsLeft) left",
            image: UIImage(systemName: shotGlyph)
        ) { _ in shoot() }
        if state.remaining < state.shotAmount {
            action.subtitle = state.remaining == 0
                ? "This post holds all it can take"
                : "Only \(points(state.remaining)) more fit on this post"
        } else if state.balance < state.shotAmount {
            action.subtitle = "Not enough points"
        } else {
            action.subtitle = "\(points(state.shotAmount)) in one tap"
        }
        if !state.canShoot { action.attributes = .disabled }
        return action
    }

    /// "Get ×100 cartridges in the Shop" — the empty pack's row.
    public nonisolated static func shopSubtitle(_ shotAmount: Int) -> String {
        "Get \(shotName(shotAmount)) cartridges in the Shop"
    }

    /// "1 point", "100 points".
    public nonisolated static func points(_ amount: Int) -> String {
        amount == 1 ? "1 point" : "\(amount) points"
    }

    /// The whole menu, titled.
    public static func menu(
        for state: State,
        stake: @escaping @MainActor (Int) -> Void,
        shoot: @escaping @MainActor () -> Void,
        undo: (@MainActor () -> Void)?,
        openShop: (@MainActor () -> Void)? = nil
    ) -> UIMenu {
        UIMenu(
            title: title,
            children: elements(for: state, stake: stake, shoot: shoot, undo: undo, openShop: openShop)
        )
    }
}
