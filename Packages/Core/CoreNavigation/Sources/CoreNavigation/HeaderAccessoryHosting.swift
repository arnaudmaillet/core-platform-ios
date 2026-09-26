import UIKit

/// A screen that will carry bar items it did not build: one inboard of its
/// trailing run, and one at the head of its leading run.
///
/// The viewer's point balance stands in almost every header — the four root
/// tabs, a pushed profile and the post screen — and it is the same number in
/// all of them: one wallet, one claim countdown, one sheet. Rather than teach
/// every screen what a wallet is, the shell owns that object and hands each
/// screen an item to wear.
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
///
/// **The leading slot** is the notifications bell's. Every root header leads
/// with it, and it is the shell's for the same reason the balance is: the
/// unread state is one fact shown in four places. A screen that adopts this
/// puts it FIRST in its leading run (`leftBarButtonItems[0]` is the screen
/// edge), ahead of its own leading control, and keeps it through every rebuild.
/// A pushed screen is never handed one — its leading edge is the back button.
@MainActor
public protocol HeaderAccessoryHosting: AnyObject {
    func setTrailingAccessoryItem(_ item: UIBarButtonItem?)
    func setLeadingAccessoryItem(_ item: UIBarButtonItem?)
}
