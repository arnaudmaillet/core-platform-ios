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
    /// Non-nil arms the pill's native long-press menu (person pills'
    /// Pin/Unpin); nil renders the pill menu-less. Resolved lazily at
    /// presentation time, so the Pin/Unpin title reflects live state.
    var menuProvider: (() -> UIMenu?)? {
        didSet { updateMenu() }
    }

    private var pill: MapPillButton?

    #if DEBUG
    /// The title of the menu UIKit would actually PRESENT, which is not the
    /// same thing as the title the bar builds — the gap between those two is
    /// exactly where the header went missing.
    var debugInstalledMenuTitle: String? { pill?.menu?.title }

    /// Presents the pill's menu without a finger — see
    /// `MapSubFilterBarView.debugPresentMenu(for:)`.
    func debugPresentMenu() {
        guard let pill else { return }
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
    /// `.priority` keeps the authored order thumb-first. These bars sit
    /// directly above the tab bar, so their menus always open UPWARD, and
    /// `.automatic` reverses the ladder in that direction — which would put a
    /// destructive Remove under the thumb and the common verb farthest away.
    private func updateMenu() {
        guard let pill else { return }
        pill.preferredMenuElementOrder = .priority
        guard let menuProvider else {
            pill.menu = nil
            return
        }
        // ⚠️ The TITLE is taken from the provided menu and put on the root —
        // this used to keep only `.children`, which silently threw the header
        // away. Nobody noticed while the pills carried names; now that they
        // are bare avatars, that header is the only place the menu says whose
        // face this is.
        //
        // The title is resolved eagerly (it is the pill's identity, and that
        // does not change under the viewer's thumb) while the CHILDREN stay
        // deferred, because they do change: the mute verb reads live state.
        // The guard is on the provider's PRESENCE, not on its result: a pill
        // configured before the bar has stored its options resolves nil for a
        // moment, and dropping the menu there would cost it the whole ladder
        // rather than just the header.
        pill.menu = UIMenu(
            title: menuProvider()?.title ?? "",
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.menuProvider?()?.children ?? [])
                }
            ]
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

