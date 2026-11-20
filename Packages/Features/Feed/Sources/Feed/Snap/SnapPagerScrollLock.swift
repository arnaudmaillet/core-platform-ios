import UIKit

/// The one owner of the full-screen feed's pager `isScrollEnabled` (#2387).
///
/// Three things hold the pager still, each for a reason of its own:
/// - **the comments sheet**, for as long as it is up (#2087);
/// - **a text page's resting panel**, once its page has settled: its own
///   stream would chain with the pager (see `ScrollLock`);
/// - **a dismissal grab**, for the length of the gesture.
///
/// The pager scrolls only while nobody holds it. A release lets go of its
/// own hold and of nothing else, so a sheet that ends during a grab, or an
/// engagement torn down under one, no longer hands the pager back scrollable
/// in the middle of the gesture, and a grab's release no longer puts back a
/// value another holder has changed since (a sheet that ended meanwhile left
/// the pager locked on a media page with nothing holding it).
///
/// ⚠️ THE SETTLED PAGE HAS THE LAST WORD (`followSettledPage`), as the
/// reconcile always had: it says, at every settle, what is true now — held by
/// the resting panel on a text page, by nobody otherwise — and every hold is
/// re-stated from that. A hold whose release was missed costs one settle,
/// not the rest of the session.
@MainActor
final class SnapPagerScrollLock {
    enum Holder: Hashable {
        case sheet
        case restingPanel
        case dismissal
    }

    /// Asked at every write, never kept: the lock can be built before the
    /// screen's view loads, and the pager it writes is the one there then.
    private let pager: @MainActor () -> UIScrollView?
    private(set) var holders: Set<Holder> = []

    init(pager: @escaping @MainActor () -> UIScrollView?) {
        self.pager = pager
    }

    /// Whether anybody holds the pager.
    var isLocked: Bool { !holders.isEmpty }

    /// Takes `holder`'s hold.
    ///
    /// ⚠️ A dismissal's hold is re-entrant and changes nothing the second time,
    /// as `ScrollLock.freeze` was: a gesture that reports its start twice
    /// must not write anything.
    func hold(_ holder: Holder) {
        if holder == .dismissal, holders.contains(.dismissal) { return }
        holders.insert(holder)
        apply()
    }

    /// Lets go of `holder`'s hold, and only of it.
    ///
    /// ⚠️ A dismissal's release with no hold outstanding writes nothing, as
    /// `ScrollLock.thaw` did: it must never be a way to enable scrolling.
    func release(_ holder: Holder) {
        if holder == .dismissal, !holders.contains(.dismissal) { return }
        holders.remove(holder)
        apply()
    }

    /// The settled page's answer, which every hold is re-stated from: the
    /// resting panel holds a text page's pager, and nothing else survives.
    func followSettledPage(isText: Bool) {
        holders = isText ? [.restingPanel] : []
        apply()
    }

    private func apply() {
        pager()?.isScrollEnabled = holders.isEmpty
    }
}
