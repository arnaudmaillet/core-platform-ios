import UIKit

/// The host a `PagedTabBar` lives in when it rides the navigation bar's LEADING
/// item group.
///
/// ⚠️ **It exists to CAP the bar's width, and that is the whole reason.** UIKit
/// silently declines to host a leading custom view that does not fit the room
/// left by the other items: no compression, no `•••` overflow, no warning — the
/// item stays in `leftBarButtonItems`, its custom view is never added to any
/// window, and the capsule is simply absent. Measured three times before the
/// cause was clear: the inbox at 280pt (three long titles), the viewer's own
/// profile at five tabs, and both reading as "the selector vanished" while every
/// other piece of state — item present, not hidden, alpha 1, docked — was right.
///
/// So the bar is given a width it can always have, and it SCROLLS the rest. It
/// already owns a horizontal scroller for exactly this, which is why no title
/// has to be shortened to fit.
final class LeadingSelectorHost: UIView {
    /// Room to leave for everything else in the bar: a leading icon, one or two
    /// trailing items, and the bar's own margins.
    ///
    /// Deliberately generous. Being 20pt narrower than necessary costs a little
    /// scrolling in a bar that scrolls anyway; being 1pt too wide costs the whole
    /// selector, with nothing said about why.
    private static let roomForOtherItems: CGFloat = 170

    private let bar: PagedTabBar
    private var maximumWidth: NSLayoutConstraint!

    init(bar: PagedTabBar) {
        self.bar = bar
        super.init(frame: .zero)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        // ⚠️ A CEILING, not a width. The first cut stated the width outright —
        // `min(bar.intrinsicContentSize.width, available)` recomputed on layout —
        // and read the bar before its segments had pinned themselves, when the
        // fitted width is just the capsule's own padding. It latched ~32pt and
        // the profile's five-tab selector came out a 36pt stub. Nothing was wrong
        // with the arithmetic; the mistake was owning a number Auto Layout will
        // maintain for free.
        //
        // As an inequality, the bar takes its intrinsic width whenever that fits
        // and the ceiling whenever it does not — re-resolved every time the bar
        // invalidates its own size, with no observation of ours.
        maximumWidth = bar.widthAnchor.constraint(lessThanOrEqualToConstant: 1_000)
        maximumWidth.priority = .required
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
            maximumWidth
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateCeiling()
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        updateCeiling()
        super.layoutSubviews()
        // The bar re-measures itself when a badge appears or a text size changes,
        // and this host's size is derived from that — so it has to re-state it
        // rather than keep the number it was first laid out at.
        if abs(lastStatedWidth - intrinsicContentSize.width) > 0.5 {
            lastStatedWidth = intrinsicContentSize.width
            invalidateIntrinsicContentSize()
        }
    }

    private var lastStatedWidth: CGFloat = 0

    /// ⚠️ **STATED, not inherited.** The bar's own intrinsic width used to reach
    /// the item through the pinned edges, and that worked only while the bar fit:
    /// once the ceiling bound it, the width had an upper limit and no lower one,
    /// nothing REQUIRED it to be positive, and Auto Layout was free to settle the
    /// host at zero — which is what the profile's five-tab selector did
    /// (`intrinsicW=325`, `hostFrame=(0,0,0,0)`, and UIKit declining to host a
    /// view with no size). Saying the number here gives the item something to
    /// measure and Auto Layout a preference to honour.
    override var intrinsicContentSize: CGSize {
        let wanted = bar.intrinsicContentSize
        let width = wanted.width > 1 ? min(wanted.width, ceiling) : UIView.noIntrinsicMetric
        return CGSize(width: width, height: wanted.height)
    }

    /// The widest the bar may be here — what the rest of the bar needs, taken off
    /// the width available to it.
    private var ceiling: CGFloat {
        #if DEBUG
        // `-leading-ceiling <points>`: forces the cap, to tell a width failure
        // from a structural one when a surface's selector is not hosted.
        let arguments = ProcessInfo.processInfo.arguments
        if let position = arguments.firstIndex(of: "-leading-ceiling"),
           position + 1 < arguments.count, let forced = Double(arguments[position + 1]) {
            return CGFloat(forced)
        }
        #endif
        let width = window?.bounds.width ?? UIScreen.main.bounds.width
        return max(80, width - Self.roomForOtherItems)
    }

    private func updateCeiling() {
        guard abs(maximumWidth.constant - ceiling) > 0.5 else { return }
        maximumWidth.constant = ceiling
    }
}

/// Hosting a `PagedTabBar` in the navigation bar's LEADING item group instead of
/// its centre title slot.
///
/// The layout every host gets:
///
/// ```
/// [ back / leading icon ] [ selector capsule ]  ——— flexible ———  [ actions ]
/// ```
///
/// One implementation, four hosts. The pattern is five things that all have to be
/// right together — bare rendering, a sized host, a capped width, a cleared title
/// slot, and a leading group that supplements rather than replaces — and a host
/// that gets four of them looks correct while behaving wrongly.
public extension UINavigationItem {
    /// Moves `bar` out of the title slot and into the leading group.
    ///
    /// Returns the item, because a host that hides its selector (the profile,
    /// whose header owns the un-scrolled state) needs it: hiding the BAR leaves
    /// UIKit's capsule behind as an empty pill, and only
    /// `UIBarButtonItem.isHidden` takes the capsule with it.
    @discardableResult
    func installLeadingSelector(_ bar: PagedTabBar) -> UIBarButtonItem {
        // ⚠️ BARE. UIKit wraps a bar item's custom view in the system's glass
        // capsule — "bar items get a capsule, the title slot gets nothing" — so a
        // bar carrying its own backdrop here is a glass lens inside a glass
        // capsule, which is the arrangement that cost the lens its edge entirely.
        // See `PagedTabBar.suppressesBackdrop`.
        bar.suppressesBackdrop = true

        // Sized AND capped; see `LeadingSelectorHost`, which is where the reason
        // a plain `UIView` was not enough is written down.
        let host = LeadingSelectorHost(bar: bar)

        // The centre is left EMPTY, so the space between the groups stays
        // flexible for whatever a host wants to put there later.
        titleView = nil

        // ⚠️ SUPPLEMENTS. A leading item that replaces the back button silently
        // disables the navigation controller's interactive pop gesture — the
        // reason the feed once had to build a whole replacement pan. Harmless on
        // a tab root, where there is no back button to supplement.
        leftItemsSupplementBackButton = true

        let item = UIBarButtonItem(customView: host)
        // ⚠️ ITS OWN CAPSULE. iOS 26 draws ONE shared glass background behind
        // adjacent bar items, so the selector and the leading icon came out
        // fused inside a single pill — one container holding a `+` and three
        // tabs. `sharesBackground = false` is UIKit's own opt-out: "this item
        // will not be visually grouped with any other items", while keeping the
        // standard background of its own. `hidesSharedBackground` is the wrong
        // neighbour — it removes the background entirely, and the bar is bare.
        item.sharesBackground = false
        var leading = leftBarButtonItems ?? []
        // Whatever the host already put here keeps its place at the front: the
        // compose glyph on For You, the switcher on an own profile.
        leading.append(item)
        leftBarButtonItems = leading
        return item
    }
}
