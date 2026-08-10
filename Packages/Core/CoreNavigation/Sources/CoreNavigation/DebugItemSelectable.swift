#if DEBUG
import UIKit

/// A surface that can tap one of its own items on request.
///
/// Exists for the navigation stress harness, which lives in the app shell and
/// can therefore see no feature's types. Without it the harness can only push
/// through the router — and a router push is a PLAIN push, so the whole hero
/// transition, the thing most likely to leave an overlay behind, would never
/// run in the test that exists to catch overlays left behind.
@MainActor
public protocol DebugItemSelectable: AnyObject {
    /// Selects the first item the way a finger would, returning whether there
    /// was one. Must go through the real selection path, not a shortcut to the
    /// destination.
    func debugSelectFirstItem() -> Bool
}
#endif
