import UIKit

/// Which pages' media carousels the screen froze, so a thaw reaches every one
/// of them (#1738).
///
/// ⚠️ THE FREEZE AND THE THAW SAW DIFFERENT CELLS (the owner, 2026-10-25:
/// "au bout d'un moment les gestes vers la droite et la gauche sont
/// bloqués"). `setContentScrollEnabled` froze the carousels of the cells
/// visible when a side-list drag or a profile push began, and thawed the ones
/// visible when it ended. A page still settling when the drag began is TWO
/// visible cells; by the thaw only one is left, and the other kept its frozen
/// carousel — then was recycled for other posts, which could no longer be
/// paged. Every such moment froze one more cell of the pool, until most
/// carousels on the screen were stuck.
///
/// So the ledger keeps every cell it froze (weakly) and thaws them all, and a
/// cell coming on screen while the content is frozen is frozen with it.
@MainActor
final class CarouselFreezeLedger<Cell: AnyObject> {
    private let frozen = NSHashTable<Cell>.weakObjects()
    private(set) var isFrozen = false

    /// Freezes `cells`, remembering each.
    func freeze(_ cells: [Cell], apply: (Cell, Bool) -> Void) {
        isFrozen = true
        for cell in cells {
            apply(cell, false)
            frozen.add(cell)
        }
    }

    /// Thaws every cell this ledger froze, visible or not, and `cells` too.
    func thaw(_ cells: [Cell], apply: (Cell, Bool) -> Void) {
        isFrozen = false
        var thawed = Set<ObjectIdentifier>()
        for cell in frozen.allObjects + cells where thawed.insert(ObjectIdentifier(cell)).inserted {
            apply(cell, true)
        }
        frozen.removeAllObjects()
    }

    /// A cell coming on screen takes the content's current state.
    func display(_ cell: Cell, apply: (Cell, Bool) -> Void) {
        apply(cell, !isFrozen)
        if isFrozen { frozen.add(cell) }
    }
}
