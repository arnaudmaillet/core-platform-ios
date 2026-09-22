import DesignSystem
import UIKit

/// Says, above the grid, that the viewer has shared only part of their library —
/// and offers the two ways out without taking the grid away.
///
/// ⚠️ **NOT AN EMPTY STATE, AND THAT IS THE WHOLE POINT.** `MediaLibraryAccess`
/// already records that limited access "is a SUCCESS, not an error": the grid
/// below holds real photos the viewer agreed to share, so this is an offer laid
/// over them, never a wall in front of them. `.denied` is a different screen —
/// the picker's own empty state handles it — and this view must not duplicate it.
///
/// ⚠️ **ONE LINE, BECAUSE THE GRID IS THE POINT.** The first cut was a card with
/// a symbol, a title, a subtitle and two buttons stacked under it: three lines of
/// chrome above a surface whose entire job is showing pictures.
///
/// ⚠️ **THE WHOLE CAPSULE IS THE CONTROL.** The menu used to hang off a "Manage"
/// button inside the pill, which put two concentric triggers around one menu and
/// left a `UIButton` competing for touches with the container's own interaction.
/// Now the pill carries the menu and `UIGlassEffect.isInteractive` supplies the
/// press response, so the word "Manage" is an affordance label rather than a
/// second control.
final class MediaAccessNoticeView: UIView {
    /// ⚠️ **THE BAR'S OWN NUMBERS, ASKED OF UIKIT RATHER THAN EYEBALLED.**
    /// Walking the navigation bar's hierarchy on this screen gives, for every
    /// item: `UIButtonLabel 54.0x20.3 < _UIModernBarButton 54.0x32.3 <
    /// _UIButtonBarButton 78.0x36.0`. The visible capsule is the LAST of those —
    /// 36pt tall, 78 wide around a 54-wide label, so 12pt of padding a side.
    ///
    /// The middle one is a trap worth naming: `_UIModernBarButton` is exactly as
    /// wide as its label, so it is the label's box and not the bubble. An earlier
    /// probe reported its 32.33pt and the number looked entirely plausible —
    /// `leading=0 trailing=0` was the only thing that gave it away.
    ///
    /// Four attempts to read these off a screenshot failed first, for a
    /// structural reason: a white pill on a white sheet has no contrast, and this
    /// notice is translucent glass over coloured tiles. One height moved between
    /// 37.7pt and 28.0pt with the threshold — a number that depends on the
    /// threshold is not a measurement.
    private enum Metrics {
        /// `_UIButtonBarButton`'s height.
        static let height: CGFloat = 36
        /// (78.0 − 54.0) / 2 — the bar bubble's horizontal inset around its text.
        static let innerLeading: CGFloat = 12
    }

    private let label = UILabel()
    private let affordance = UILabel()
    private let host: UIVisualEffectView
    /// The whole capsule's control surface: a bare button filling the glass,
    /// carrying the menu and nothing else. The labels ride above it with
    /// interaction off, so there is one trigger rather than two concentric ones.
    private let trigger = UIButton(type: .custom)

    /// What the two ways out do. The view owns the menu; the screen owns the
    /// actions, because opening Settings and presenting the system picker both
    /// need a view controller.
    var onSelectMore: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    override init(frame: CGRect) {
        label.text = "You've shared some of your photos."
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2

        affordance.text = "Manage"
        affordance.font = .preferredFont(forTextStyle: .footnote)
        affordance.adjustsFontForContentSizeCategory = true
        affordance.textColor = .tintColor
        affordance.setContentHuggingPriority(.required, for: .horizontal)
        affordance.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [label, affordance])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        row.isUserInteractionEnabled = false

        // ⚠️ **ONE GLASS HOST, SUPPLIED HERE.** No `backgroundColor` and no
        // `layer.cornerRadius` underneath it: the design system's rule is one
        // material per surface, and a colour beneath glass reads as two. The
        // album strip on this screen carries none of its own — it sets
        // `hosting = .platter`, because a bar item is already composited through
        // the toolbar's glass — so this pill is the only material in the band.
        host = GlassCapsule.wrap(row)
        super.init(frame: frame)

        host.pin(to: self)
        // ⚠️ **`wrap` CONSTRAINS leading, trailing AND centerY — NEVER A HEIGHT.**
        // It used to be padded top and bottom by `Spacing.md`, which made the
        // pill 39.67pt: the label's own 15.67 plus 24. That is close enough to a
        // bar bubble to look right and wrong enough to read wrong beside one —
        // measured, the bubble is 36.
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Metrics.height)
        ])
        // ⚠️ **THE PADDING LIVES IN THE ROW, NOT IN A CONSTRAINT.** `wrap` has
        // already pinned the content flush to `contentView`, so adding leading
        // and trailing constraints here would fight those rather than inset
        // anything — the text sat hard against the capsule's edge
        // (`leading=0.0`, measured) and a second pair of constraints would have
        // been an Auto Layout conflict instead of a fix. Layout margins inset the
        // arranged subviews from inside, leaving `wrap`'s geometry untouched.
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0,
            leading: Metrics.innerLeading,
            bottom: 0,
            trailing: Metrics.innerLeading
        )

        // ⚠️ **A TAP, NOT A LONG PRESS — AND THE FIRST CUT GOT THIS WRONG.** It
        // used a `UIContextMenuInteraction`, which only opens on press-and-hold:
        // a gesture nobody would find on a banner, and not the one asked for.
        // Every menu-on-tap in this app is a button with
        // `showsMenuAsPrimaryAction` (eleven of them; `ProfileHeaderView` spells
        // out "One tap opens the checklist … so no long press"), and the only
        // `UIContextMenuInteraction`s are on list ROWS, where a long press is
        // what a viewer expects.
        //
        // The button fills the capsule and the contents ride above it without
        // taking touches, so there is exactly one trigger for one menu.
        trigger.showsMenuAsPrimaryAction = true
        trigger.pin(to: host.contentView)
        host.contentView.sendSubviewToBack(trigger)
        // ⚠️ THE SHAPE IS `cornerConfiguration`, WHICH `GlassCapsule` SETS — and
        // that matters precisely because this view presents a menu. UIKit morphs
        // a portal of the view out and back for it, and a layer-masked radius is
        // not part of what it interpolates: the capsule came back a hard SQUARE
        // for a frame. `cornerConfiguration` is a property UIKit owns and
        // animates with the view.
        rebuildMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var menu: UIMenu = UIMenu()

    /// ⚠️ **THE NATIVE PICKER LEADS, SETTINGS FOLLOWS.** Adding photos through
    /// `presentLimitedLibraryPicker` never leaves the app; Settings drops the
    /// viewer out of it and asks them to find their way back. Both are offered
    /// because only Settings can widen the permission itself.
    private func rebuildMenu() {
        menu = UIMenu(children: [
            UIAction(title: "Select More Photos…", image: UIImage(systemName: "photo.badge.plus")) {
                [weak self] _ in self?.onSelectMore?()
            },
            UIAction(title: "Allow Access to All Photos", image: UIImage(systemName: "gear")) {
                [weak self] _ in self?.onOpenSettings?()
            }
        ])
        // ⚠️ **THE BUTTON IS WHAT OPENS IT, SO THE BUTTON MUST HOLD IT.** Keeping
        // the menu only in the property left `showsMenuAsPrimaryAction` pointing
        // at nothing — a dead tap that the tests could not catch, because they
        // read the property rather than the control.
        trigger.menu = menu
    }

    #if DEBUG
    /// Internal for tests: the wording, and the two ways out, without a menu to
    /// open or a system sheet to present.
    ///
    /// ⚠️ These name an INTENTION — "what routes are offered" — not the control
    /// that carries them. The menu moved from a button to the capsule itself and
    /// these did not have to change, which is the point: a test that had to be
    /// edited would have been testing the mechanism.
    var debugText: String? { label.text }
    /// Internal for tests and the bar-metrics probe: where the text actually
    /// sits inside the capsule.
    ///
    /// ⚠️ CONVERTED INTO THIS VIEW'S COORDINATES ON PURPOSE. The label lives
    /// inside a stack, inside the effect view's `contentView`, inside the glass
    /// host — so its raw `frame` is relative to the stack and says nothing about
    /// the padding around the pill. Comparing that against a bar bubble's insets
    /// would be comparing two different origins and calling the difference a
    /// measurement.
    var debugLabelFrame: CGRect { label.convert(label.bounds, to: self) }
    var debugMenuTitles: [String] {
        menu.children.compactMap { ($0 as? UIAction)?.title }
    }
    func debugTapSelectMore() { onSelectMore?() }
    func debugTapOpenSettings() { onOpenSettings?() }
    #endif
}
