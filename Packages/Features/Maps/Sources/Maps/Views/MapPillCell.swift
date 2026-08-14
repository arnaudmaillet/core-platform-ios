import QuartzCore
import UIKit

/// One filter pill inside a bar's collection view: a FULLY INTERACTIVE
/// `MapPillButton` — native touch-down, tracking, highlight, and glass
/// material response, exactly as in the pre-collection scroll-view bars.
/// The collection view orchestrates (layout, diffable identity); the button
/// owns the touch. Taps surface through `onTap` (the button consumes the
/// event, so `didSelectItemAt` never fires for pill hits), and long-press
/// menus attach to the pill itself via `menuProvider`. The cell self-sizes
/// from the pill's intrinsic width.
///
/// Reuse & glass: the pill is created once per cell and kept across
/// reconfigures (`setContent` swaps identity), so the Liquid Glass material
/// is materialized once on window attach — reuse never re-contacts the
/// render server (the CI doctrine survives recycling).
final class MapPillCell: UICollectionViewCell {
    /// The pill's own `.touchUpInside` — the bar maps it to its selection.
    var onTap: (() -> Void)?
    /// Non-nil arms the pill's native long-press menu; nil renders the pill
    /// menu-less. What the provider returns is SPLIT — see `MapPillMenu` —
    /// because the two halves of a pill menu have opposite needs: the header
    /// must be on screen in the menu's first frame, the verbs must be current
    /// at the moment it opens.
    var menuProvider: (() -> MapPillMenu?)? {
        didSet { updateMenu() }
    }

    private var pill: MapPillButton?

    #if DEBUG
    /// What UIKit would actually PRESENT as the menu's header, which is not
    /// the same thing as what the bar builds — the gap between those two is
    /// exactly where the header went missing once. Readable without opening
    /// anything now that the header is installed eagerly.
    var debugInstalledMenuTitle: String? {
        guard let menu = pill?.menu else { return nil }
        let header = (menu.children.first as? UIMenu)?.children
            .compactMap { $0 as? UIAction }.first
        return header?.title ?? menu.title
    }

    /// The header's second line, as installed.
    var debugInstalledMenuSubtitle: String? {
        (pill?.menu?.children.first as? UIMenu)?.children
            .compactMap { $0 as? UIAction }.first?.subtitle
    }

    /// Presents the pill's menu without a finger — see
    /// `MapSubFilterBarView.debugPresentMenu(for:)`.
    func debugPresentMenu() {
        guard let pill else { return }
        if ProcessInfo.processInfo.arguments.contains("-maps-trace-menu") {
            print("[maps] menu presentation requested at \(CACurrentMediaTime())")
        }
        pill.showsMenuAsPrimaryAction = true
        pill.performPrimaryAction()
    }
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Glass halos bleed past the pill's bounds — nothing may clip.
        clipsToBounds = false
        contentView.clipsToBounds = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Alpha is BAR state, not cell state: the sub bar drives it from the
    /// duck-fade and both bars fade cells in on arrival. A recycled cell must
    /// therefore come back opaque — inheriting a ducked (or mid-dissolve)
    /// alpha from its previous tenant would strand a pill invisible in a bar
    /// that has no obstruction to fade it back.
    override func prepareForReuse() {
        super.prepareForReuse()
        alpha = 1
    }

    func configure(content: MapPillButton.Content, height: CGFloat, selected: Bool) {
        let pill = existingPill(height: height, initialContent: content)
        pill.setContent(content)
        pill.setSelectedAppearance(selected)
    }

    /// Rebuilds the installed menu. The header is drawn from state the cell
    /// captured when it was configured, so whatever changes that state — an
    /// avatar finishing its download — has to say so.
    func refreshMenu() { updateMenu() }

    /// Routes a resolved avatar to the pill (owner calls after async load).
    func setAvatar(_ image: UIImage?) {
        pill?.setAvatar(image)
    }

    private func existingPill(height: CGFloat, initialContent: MapPillButton.Content) -> MapPillButton {
        if let pill { return pill }
        let pill = MapPillButton(content: initialContent, height: height)
        // Direct native interaction — the button tracks its own touches
        // (touch-down highlight, press dip, glass response), the cell just
        // relays the recognized tap.
        pill.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        pill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pill.topAnchor.constraint(equalTo: contentView.topAnchor),
            pill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        self.pill = pill
        updateMenu()
        return pill
    }

    /// The UIButton-native long-press menu: `button.menu` without
    /// `showsMenuAsPrimaryAction` presents on press-and-hold while taps stay
    /// taps. A manually-attached `UIContextMenuInteraction` does NOT fire on
    /// a tracking UIButton — verified dead under real long-presses, which is
    /// why this stays on the button even though the menu is now a full
    /// entity-aware ladder rather than one action.
    ///
    /// `.fixed`: the menu reads top-down exactly as it was authored.
    ///
    /// It was `.priority` — thumb-first, which these bars need because they
    /// sit directly above the tab bar and their menus always open UPWARD, so
    /// UIKit reverses the ladder to keep the first element nearest the touch.
    /// That is the right rule for a list of verbs and the wrong one once the
    /// first element is a HEADER: reversed, the person's name sank to the
    /// bottom of the menu, under the verbs acting on them. A header that is
    /// not at the top is not a header.
    ///
    /// ⚠️ The cost is the ladder's own order: Share now sits nearest the
    /// thumb and Message farthest from it.
    private func updateMenu() {
        guard let pill else { return }
        pill.preferredMenuElementOrder = .fixed
        guard let menuProvider else {
            pill.menu = nil
            return
        }
        let built = menuProvider()
        // ⚠️ The HEADER is installed here, not resolved at presentation.
        //
        // It used to sit inside the deferred element with the verbs, and a
        // deferred element by definition resolves AFTER UIKit has begun
        // presenting — measured at ~19ms, one frame, which is enough for the
        // menu to draw a placeholder first and swap the real rows in. The
        // name and the handle arrived in that swap rather than in the first
        // frame, which is what read as the handle loading late.
        //
        // Nothing in the header can change under a thumb: the person's name,
        // handle and face are the pill's identity, and all three are already
        // in memory — `MapFavorite` hydrates them in ONE profile fetch, so
        // there is no state in which the name is known and the handle is not.
        // It is built once, up front, and drawn in the first frame.
        //
        // The VERBS stay deferred, because they genuinely are live: the mute
        // entry reads a flag anything else in the app may have flipped since
        // this cell was configured.
        pill.menu = UIMenu(
            title: built?.title ?? "",
            children: [
                built?.header,
                UIDeferredMenuElement.uncached { [weak self] completion in
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-maps-trace-menu") {
                        print("[maps] menu verbs resolved at \(CACurrentMediaTime())")
                    }
                    #endif
                    completion(self?.menuProvider?()?.liveSection() ?? [])
                },
            ].compactMap { $0 }
        )
    }
}

/// A bar's collection view: with `delaysContentTouches = false` (immediate
/// button touch-down), UIKit refuses by default to cancel a UIControl's
/// tracking — a drag STARTING on a pill would never scroll the row. Restore
/// the scroll-view contract: touches on pills cancel into scrolling.
final class MapBarCollectionView: UICollectionView {
    override func touchesShouldCancel(in view: UIView) -> Bool { true }
}

/// The bars' duck-fade curve: pills dissolve as they APPROACH an obstructing
/// glass element (the sub bar's fixed leading button) and are fully
/// transparent at shallow overlap. Starting the fade only at first contact
/// left pills half-under the obstruction at high alpha — the obstruction's
/// capsule edge then sliced them into a blurred-behind-glass half and a
/// sharp half, reading as a hard rectangular clip. Fading across
/// `approach` (before contact) → `depth` (into the overlap) means nothing
/// legible ever sits beneath the glass.
enum MapBarDuckFade {
    /// Points before contact at which the dissolve begins.
    static let approach: CGFloat = 12
    /// Overlap depth at which the pill is fully transparent.
    static let depth: CGFloat = 28

    /// `penetration`: how far the pill's approaching edge has advanced past
    /// the fade's start line (obstruction edge + approach margin).
    static func alpha(forPenetration penetration: CGFloat) -> CGFloat {
        1 - min(1, max(0, penetration / (approach + depth)))
    }
}

