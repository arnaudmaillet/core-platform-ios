#if DEBUG
import UIKit

/// A screen that can drive its own interactive dismissal on request.
///
/// The stress harness pops programmatically, and a programmatic pop is a
/// different code path from a grab: it never asks for an interaction
/// controller, so it cannot notice that the stack's delegate was replaced with
/// something that no longer vends one. The bug this exists to catch — a
/// completed grab leaving the screen beneath unable to be grabbed — is
/// invisible to `popViewController`.
@MainActor
public protocol DebugInteractivelyDismissible: AnyObject {
    /// Runs a grab past the completion threshold, the way a finger would, and
    /// reports whether one could begin at all. `false` means the gesture was
    /// refused — which is itself the failure worth catching.
    func debugDismissInteractively() async -> Bool
}
#endif
