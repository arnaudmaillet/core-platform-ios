import DesignSystem
import UIKit

/// THE MEDIA CAPSULE (#2344, the owner, 2026-11-12): the host's attachments
/// (`ComposerConfiguration.attachments`) in ONE glass capsule, folded into
/// the own bubble while the reader writes — through a native `UIToolbar`
/// standing in the composer's row (route A), so the fold is the toolbar's
/// own and nothing is animated by hand:
///
/// ```
///  at rest:   [avatar][field ……][📷 🖼] [☺]     [sources…] · [anchor]
///  writing:   [avatar][field ……………………] [☺]     [anchor]
/// ```
///
/// - The sources are STOCK items (`BarItems.icon`, R1): neighbouring items,
///   the bar makes them one platter — two glyphs, one capsule, each its own
///   44 pt target and its own VoiceOver label.
/// - A separator (`BarItems.separator`), then the ANCHOR: the item that
///   stands where the own bubble rests, and that the capsule folds into and
///   grows back out of (`setItems(_:animated:)`, the iOS 26 toolbar's fold).
///   The own bubble itself is not a bar item — it grows into the voice
///   hold's mic, steps aside for a locked take and rides the row's
///   constraints (#2102) — so the anchor is an empty view the bar draws no
///   bubble around (`ownBackground`: the control it stands for, the own
///   bubble, draws its own glass), and the composer lays the toolbar so the
///   anchor sits exactly under the own bubble (`CommentsInputBar
///   .alignAttachmentBar`). The capsule narrows into it, under the own
///   bubble's glass.
/// - Writing: `[anchor]` alone; done writing: the three back. The field's
///   end follows in the same turn, on the toolbar's measured spring
///   (`SnapGlassColumn`'s constants).
/// - Reduce Motion: a cross-fade, as before #2344.
///
/// ⚠️ ROUTE A IS ON PROBATION (the issue): if the PR's film shows the field
/// jumping or lagging, or the toolbar's glass reads unlike the row's other
/// bubbles, route B replaces this with `UIGlassContainerEffect`
/// (`SnapGlassColumn`, horizontally).
@MainActor
final class ComposerAttachmentToolbar: UIToolbar {
    /// The anchor's identifier: the own bubble's place in the toolbar.
    static let ownBubbleID = "composer.own-bubble"

    /// How the last change of state was drawn: for tests.
    enum Change: Equatable {
        /// Nothing changed yet.
        case none
        /// Off screen or before the first layout: in place.
        case snapped
        /// The toolbar's own fold (`setItems(_:animated: true)`).
        case folded
        /// Reduce Motion: a cross-fade.
        case crossFaded
    }

    /// The sources' stock items, in the list's order.
    let sourceItems: [UIBarButtonItem]
    /// The capsule's own bubble apart from the anchor's place.
    let separatorItem = BarItems.separator()
    /// Keeps the run at the toolbar's trailing end, where the anchor meets
    /// the own bubble — one instance, so the toolbar matches it across
    /// states.
    let flexibleItem = UIBarButtonItem.flexibleSpace()
    /// The empty view the anchor item holds: as big as the own bubble.
    let anchorView = OwnBubbleAnchorView()
    private(set) lazy var anchorItem = BarItems.container(id: Self.ownBubbleID, view: anchorView, ownBackground: true)
    /// Whether the capsule is (or is on its way) in the toolbar.
    private(set) var showsSources = false
    private(set) var lastChange: Change = .none

    /// `tap` is handed the tapped source's id: the composer reads its
    /// action off the list then, so new actions keep the items.
    init(sources: [ComposerAttachmentSource], tint: UIColor, tap: @escaping @MainActor (String) -> Void) {
        sourceItems = sources.map { source in
            let id = source.id
            let item = BarItems.icon(
                id: source.id, image: UIImage(systemName: source.symbol), label: source.accessibilityLabel
            ) { tap(id) }
            item.accessibilityIdentifier = source.id
            item.tintColor = tint
            return item
        }
        super.init(frame: CGRect(x: 0, y: 0, width: 200, height: 44))
        // Only the items: no bar behind them, in either state.
        let clear = UIToolbarAppearance()
        clear.configureWithTransparentBackground()
        standardAppearance = clear
        compactAppearance = clear
        scrollEdgeAppearance = clear
        compactScrollEdgeAppearance = clear
        accessibilityIdentifier = "composer.attachments"
        setItems(currentItems, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The toolbar's items for a state: the capsule, the separator and the
    /// anchor at rest; the anchor alone while the reader writes. Pure, for
    /// tests.
    static func items(
        sources: [UIBarButtonItem], separator: UIBarButtonItem, anchor: UIBarButtonItem,
        flexible: UIBarButtonItem, showsSources: Bool
    ) -> [UIBarButtonItem] {
        guard showsSources, !sources.isEmpty else { return [flexible, anchor] }
        return [flexible] + sources + [separator, anchor]
    }

    /// The items for the state the toolbar is in.
    var currentItems: [UIBarButtonItem] {
        Self.items(
            sources: sourceItems, separator: separatorItem, anchor: anchorItem, flexible: flexibleItem,
            showsSources: showsSources
        )
    }

    /// The capsule in or out: folded into the anchor and grown back out of
    /// it by the toolbar (`animated`), cross-faded under Reduce Motion
    /// (`crossFades`), or in place.
    func setShowsSources(_ shows: Bool, animated: Bool, crossFades: Bool = false) {
        guard shows != showsSources else { return }
        showsSources = shows
        let items = currentItems
        guard animated else {
            lastChange = .snapped
            return UIView.performWithoutAnimation { setItems(items, animated: false) }
        }
        if crossFades {
            lastChange = .crossFaded
            UIView.transition(
                with: self, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
            ) {
                self.setItems(items, animated: false)
            }
            return
        }
        lastChange = .folded
        setItems(items, animated: true)
    }

    /// The width a run of `count` sources asks of the row: one own-bubble
    /// side per glyph — each glyph's 44 pt target in the bar's platter. The
    /// field ends `sm` short of it. ⚠️ An estimate of the platter's width,
    /// which the PR's film confirms on the simulator.
    static func capsuleWidth(count: Int) -> CGFloat {
        CGFloat(count) * CommentsInputBar.Metrics.controlSize
    }

    /// Room enough for the capsule, the separator and the anchor, with the
    /// toolbar's own margins either side: the toolbar never changes width,
    /// only its items do — the flexible space takes up the rest.
    static func width(count: Int) -> CGFloat {
        capsuleWidth(count: count) + CommentsInputBar.Metrics.controlSize + 96
    }

    /// Only the capsule takes a touch: the rest of the toolbar overlays the
    /// field's end and the own bubble, which keep theirs.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard showsSources, let hit = super.hitTest(point, with: event), hit !== self else { return nil }
        let anchor = anchorView.convert(anchorView.bounds, to: self)
        guard anchor.width > 0 else { return hit }
        // The capsule's run before the anchor, with a little slack for the
        // separator and the platter's ends.
        let run = Self.capsuleWidth(count: sourceItems.count) + Spacing.lg
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let inside = rightToLeft
            ? point.x > anchor.maxX && point.x <= anchor.maxX + run
            : point.x < anchor.minX && point.x >= anchor.minX - run
        return inside ? hit : nil
    }
}

/// The anchor's view: the own bubble's size, nothing drawn, no touch and no
/// VoiceOver element — the own bubble laid over it has all three.
@MainActor
final class OwnBubbleAnchorView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: CommentsInputBar.Metrics.controlSize, height: CommentsInputBar.Metrics.controlSize)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
}
