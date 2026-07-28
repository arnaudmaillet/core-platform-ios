import UIKit

/// A screen that exists only to CHOOSE a destination, and has no reason to
/// survive reaching one.
///
/// The compose picker is the archetype: you open it to answer "who?", it emits
/// a route, and the thread arrives. Pushed plainly, it stays wedged between the
/// inbox and the thread — so backing out of a conversation you just opened
/// returns you to a list of contacts rather than to Messages, and every such
/// round trip leaves another copy behind it.
///
/// Conforming is a statement about the SCREEN, not about any one route, which
/// is what keeps the rule from rotting: a picker that later learns to open a
/// profile as well as a thread is handled without the navigation layer being
/// told about the new destination. `RouteResolver` drops conformers from the
/// stack as it pushes past them.
///
/// This is deliberately not "dismiss yourself on selection". A picker that
/// popped itself would be navigating — the thing every feature screen here is
/// built not to do — and it would also have to guess whether the push it
/// triggered actually happened.
@MainActor
public protocol TransientDestinationPicking: UIViewController {}
