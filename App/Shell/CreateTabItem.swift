import UIKit

/// The bar's detached trailing item: a "+" that opens a menu of ways to make a
/// post — Camera, Upload Media, Text Post. It is NOT a place anyone stands on,
/// which is why it is not an `AppTab` and has no coordinator or stack.
///
/// # Why it is still a `UISearchTab`
///
/// The item sits apart, in its own bubble, and on iPhone that detachment is
/// something the SYSTEM does for one type, not something a tab can ask for.
/// Measured both ways on a compact device (#152):
///
///   - a plain `UITab` with `preferredPlacement = .pinned` lands INSIDE the
///     bubble of the other four — honoured as an ORDER, trailing-most, not as
///     a separation;
///   - a `UISearchTab` is separated, and Apple documents that as a property
///     of the type: "UISearchTab also automatically separates the search tab
///     from other tabs when the tab bar is compact."
///
/// `title` and `image` are `{ get set }` on `UITab` and are not redeclared
/// read-only by the subclass, so the search tab wears a "+". ⚠️ The system
/// still knows it as the search ROLE: `UISearchTab.identifier` is
/// system-assigned, so anything keyed on that identifier sees "search".
///
/// # Why a tap opens a menu and never selects it
///
/// `UITab` carries no menu of its own, and `UIContextMenuInteraction` has no
/// public way to present by code. A control does: `performPrimaryAction()` on
/// a button whose menu IS its primary action opens that menu, anchored to the
/// button. So the menu lives on an invisible button laid over the bubble, and
/// the tap goes to the REAL bubble — `MainTabCoordinator` refuses the
/// selection in `shouldSelectTab` and opens the menu from there.
///
/// ⚠️ THE OVERLAY MUST NOT TAKE THE TOUCH. It first did, the way the Profile
/// and For You overlays take their long presses, and the bubble lost its
/// Liquid Glass press response: the one item in the bar that no longer
/// answered a finger. So this overlay is an ANCHOR only — no interaction and
/// no accessibility element. VoiceOver activates the bar's own element, which
/// lands in the same `shouldSelectTab`.
@MainActor
final class CreateTabItem {
    /// What the menu offers, in declaration order.
    enum Destination: String, CaseIterable {
        case camera
        case upload
        case text
    }

    let tab: UITab
    /// Kept aligned over the bubble by `MainTabCoordinator`, which owns the bar.
    let overlay: UIButton

    init(open: @escaping @MainActor (Destination) -> Void) {
        // The provider is never asked for a screen that is shown — selection
        // is vetoed — but it must answer one.
        let tab = UISearchTab { _ in UIViewController() }
        tab.title = "Create"
        tab.image = UIImage(systemName: "plus")
        self.tab = tab

        let button = UIButton(type: .custom)
        button.backgroundColor = .clear
        // A `UIControl` ships with this off, which leaves a `menu` inert.
        button.isContextMenuInteractionEnabled = true
        button.showsMenuAsPrimaryAction = true
        button.menu = Self.menu(open: open)
        button.isUserInteractionEnabled = false
        button.isAccessibilityElement = false
        overlay = button
    }

    /// Opens the menu, anchored to the bubble.
    func presentMenu() {
        overlay.performPrimaryAction()
    }

    /// A plain list: icon AND label on every row.
    ///
    /// ⚠️ ICONS ONLY WAS BUILT AND MEASURED, AND IT IS NOT NARROWER.
    /// `preferredElementSize = .small` does drop the labels — the three
    /// glyphs in one horizontal row — but inside a menu of the STANDARD width:
    /// ~247pt of a 402pt screen, the glyphs spread evenly across it, laid over
    /// the Messages and Profile buttons. Nothing public sets a menu's width.
    /// The brief was icons only IF the menu could be narrowed, labels
    /// otherwise, so this is the "otherwise".
    private static func menu(open: @escaping @MainActor (Destination) -> Void) -> UIMenu {
        let actions = Destination.allCases.map { destination in
            UIAction(title: destination.title, image: UIImage(systemName: destination.symbolName)) { _ in
                open(destination)
            }
        }
        return UIMenu(children: actions)
    }
}

extension CreateTabItem.Destination {
    var title: String {
        switch self {
        case .camera: "Camera"
        case .upload: "Upload Media"
        case .text: "Text Post"
        }
    }

    var symbolName: String {
        switch self {
        case .camera: "camera"
        case .upload: "photo.on.rectangle"
        case .text: "textformat"
        }
    }
}
