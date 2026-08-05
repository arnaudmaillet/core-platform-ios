import UIKit

/// One row of a tab's long-press menu.
///
/// ⚠️ **Data, not a `UIMenu`, and that is forced rather than preferred.** There
/// is no public way to present a `UIMenu` at a point: `UIContextMenuInteraction`
/// has no programmatic trigger, `showsMenuAsPrimaryAction` presents only from a
/// real touch, and `UIAction`'s handler cannot be read back — so an existing
/// menu cannot even be re-rendered into a list of our own. The moment the
/// system's gesture stops being the thing that opens the menu (and on a tab bar
/// it does — the tab buttons absorb the press on hardware), the menu's CONTENTS
/// have to travel as data too.
public struct TabMenuItem {
    public let title: String
    public let image: UIImage?
    /// A count shown at the trailing edge, for menus that carry one.
    public let badge: String?
    public let isSelected: Bool
    public let handler: () -> Void

    public init(
        title: String,
        image: UIImage? = nil,
        badge: String? = nil,
        isSelected: Bool = false,
        handler: @escaping () -> Void
    ) {
        self.title = title
        self.image = image
        self.badge = badge
        self.isSelected = isSelected
        self.handler = handler
    }
}

/// A run of rows with a separator after it — the inline sections a `UIMenu`
/// would have drawn.
public struct TabMenuSection {
    public let items: [TabMenuItem]
    public init(items: [TabMenuItem]) { self.items = items }
}

/// The list a tab shows when it is held.
///
/// Presented as an anchored `.popover` rather than as a sheet: a popover keeps
/// the arrow pointing at the tab it came from, dismisses on an outside tap, and
/// leaves the rest of the screen live — all of which a context menu does and an
/// action sheet does not. On iPhone that requires refusing the adaptation to a
/// sheet, which is what `adaptivePresentationStyle` is doing below.
public final class TabMenuViewController: UITableViewController {
    private let sections: [TabMenuSection]
    /// Row height and the widest the popover goes. Stated rather than measured:
    /// the popover needs a `preferredContentSize` BEFORE it lays out, and a
    /// menu of four rows should not be a different width from one of two.
    private static let rowHeight: CGFloat = 52
    private static let width: CGFloat = 260

    public init(sections: [TabMenuSection]) {
        self.sections = sections.filter { !$0.items.isEmpty }
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.rowHeight = Self.rowHeight
        tableView.isScrollEnabled = false
        tableView.backgroundColor = .clear
        // The popover supplies the material; a table drawing its own background
        // over it would flatten the blur into a slab.
        tableView.showsVerticalScrollIndicator = false
        // A first estimate, so the popover has something to present at before
        // the table has laid out. The real number arrives below.
        let rows = sections.reduce(0) { $0 + $1.items.count }
        preferredContentSize = CGSize(
            width: Self.width, height: CGFloat(rows) * Self.rowHeight
        )
    }

    /// ⚠️ **Sized from the table, not from arithmetic.** An inset-grouped table
    /// adds section insets, separators and corner padding that a row count
    /// cannot predict — the stated guess came out short and the popover clipped
    /// its last row, which on the switcher was "Add Profile". Asking the table
    /// what it measures is the only number that is right for every menu.
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let measured = CGSize(width: Self.width, height: tableView.contentSize.height)
        guard measured.height > 0, preferredContentSize != measured else { return }
        preferredContentSize = measured
    }

    public override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection s: Int) -> Int {
        sections[s].items.count
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        let item = sections[indexPath.section].items[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = item.title
        content.image = item.image
        // The avatars arrive pre-rounded at 36pt; anything else is a glyph.
        content.imageProperties.maximumSize = CGSize(width: 30, height: 30)
        content.imageProperties.cornerRadius = item.image?.size.width == 36 ? 15 : 0
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        // Selection is shown by a checkmark rather than by tinting the row:
        // these lists carry avatars, and a tinted row recolours them.
        cell.accessoryType = item.isSelected ? .checkmark : .none
        if let badge = item.badge {
            let label = UILabel()
            label.text = badge
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = .secondaryLabel
            label.sizeToFit()
            cell.accessoryView = item.isSelected ? nil : label
        } else {
            cell.accessoryView = nil
        }
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let item = sections[indexPath.section].items[indexPath.row]
        // Dismissed FIRST, then acted on. Several of these actions push or swap
        // a whole tab's contents, and doing that under a live popover leaves it
        // anchored to a bar item that has moved out from under it.
        dismiss(animated: true) { item.handler() }
    }
}
