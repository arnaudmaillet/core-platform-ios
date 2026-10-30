import Foundation

/// The guest map's way to allow location (#1907): the shell draws it as a
/// bar item ("Allow location", the guest header's leading slot), never the
/// map. Adopted by the view controller `makeMapViewController()` returns.
@MainActor
public protocol GuestLocationOffering: AnyObject {
    /// Whether the map offers it now: a guest whose location is not allowed.
    var offersGuestLocation: Bool { get }
    /// Told whenever `offersGuestLocation` changes.
    var onGuestLocationOfferChange: ((Bool) -> Void)? { get set }
    /// What the item's tap does: the system prompt, or Settings once denied.
    func allowGuestLocation()
}
