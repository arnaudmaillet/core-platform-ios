import CoreModels
import UIKit

/// Whoever holds the app's `MemberGating`, found up the responder chain.
///
/// Adopted by the shell's tab bar controller. A control drawn deep inside a
/// screen — a card's like chip, a rail button, a comment field — finds the
/// gate from itself, without a dependency threaded through every screen that
/// draws it: a view's chain climbs its view controllers, then each presented
/// controller's presenter, to the window's root. The same shape as
/// `StakeShopOpening`.
@MainActor
public protocol MemberGateProviding: AnyObject {
    var memberGate: any MemberGating { get }
}

@MainActor
public enum MemberGates {
    /// The gate up `source`'s responder chain, or nil off-screen (a control not
    /// in a window has no chain to the shell).
    public static func gate(from source: UIResponder) -> (any MemberGating)? {
        sequence(first: source, next: \.next).lazy
            .compactMap { ($0 as? any MemberGateProviding)?.memberGate }
            .first
    }

    /// `requireMember` from `source`. With no gate up the chain the answer is
    /// yes: outside the shell (tests, previews) nothing is gated, and the write
    /// is still refused server-side for a guest.
    public static func requireMember(for action: GatedAction, from source: UIResponder) async -> Bool {
        guard let gate = gate(from: source) else { return true }
        return await gate.requireMember(for: action)
    }
}
