import CoreGraphics

/// Pure page math: which item is snapped to the viewport for a given scroll
/// position. Kept free of UIKit so the paging logic is unit-tested without a
/// live scroll view.
enum SnapActiveItemTracker {
    /// The index of the page whose top is nearest the viewport top. `nil` when
    /// there is nothing to show or the layout has no height yet.
    static func activeIndex(contentOffsetY: CGFloat, pageHeight: CGFloat, itemCount: Int) -> Int? {
        guard pageHeight > 0, itemCount > 0 else { return nil }
        let page = Int((contentOffsetY / pageHeight).rounded())
        return min(max(page, 0), itemCount - 1)
    }
}

/// The activation state machine that drives `SnapCellLifecycle`.
///
/// The *effective* active item is the snapped page — but only while the surface
/// is visible; otherwise nothing is active. Every mutation returns the single
/// transition (resign one page, activate another) the view controller should
/// apply, so the UIKit side stays a thin dispatcher and this stays trivially
/// testable.
struct SnapLifecycleDispatcher: Equatable {
    private(set) var pageIndex: Int?
    private(set) var isVisible: Bool

    init(pageIndex: Int? = nil, isVisible: Bool = false) {
        self.pageIndex = pageIndex
        self.isVisible = isVisible
    }

    /// The page/surface change the caller should enact: at most one resign and
    /// one activate. Either may be `nil`.
    struct Transition: Equatable {
        var resign: Int?
        var activate: Int?
        static let none = Transition(resign: nil, activate: nil)
    }

    /// The item that should currently be active: the snapped page, but only
    /// while the surface is visible.
    var activeIndex: Int? { effectiveActive }

    private var effectiveActive: Int? { isVisible ? pageIndex : nil }

    /// The snapped page changed (a scroll settled, or content reloaded).
    mutating func setPageIndex(_ index: Int?) -> Transition {
        let before = effectiveActive
        pageIndex = index
        return diff(from: before)
    }

    /// The surface appeared or went away (tab switch, or app background/
    /// foreground — the view controller ANDs those two facts before calling).
    mutating func setVisible(_ visible: Bool) -> Transition {
        let before = effectiveActive
        isVisible = visible
        return diff(from: before)
    }

    private func diff(from before: Int?) -> Transition {
        let after = effectiveActive
        guard before != after else { return .none }
        return Transition(resign: before, activate: after)
    }
}
