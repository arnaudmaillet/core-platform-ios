import UIKit

/// A root screen that will carry ONE bar item it did not build.
///
/// The viewer's point balance stands in four headers — Maps, For You, Profile
/// and the post screen — and it is the same number in all of them: one wallet,
/// one claim countdown, one sheet. Rather than teach four screens what a wallet
/// is, the shell owns that object and hands each screen an item to wear.
///
/// The item cannot simply be written onto a `navigationItem` from outside,
/// which is why this exists: these screens COMPOSE their trailing run — For You
/// writes it at `viewDidLoad`, the profile recomposes it whenever its follow
/// state or identity moves — so anything assigned from out here is erased by
/// the next write. A screen that adopts this promises the opposite: it keeps
/// the item through every rebuild, and it puts it inboard of its own (`[0]` is
/// the screen edge, so the screen's action keeps the corner).
///
/// Setting it again REPLACES it: a badge whose count changes width hands over a
/// fresh `UIBarButtonItem`, because a bar measures a custom view once, at
/// install. `nil` clears it.
@MainActor
public protocol HeaderAccessoryHosting: AnyObject {
    func setTrailingAccessoryItem(_ item: UIBarButtonItem?)
}
