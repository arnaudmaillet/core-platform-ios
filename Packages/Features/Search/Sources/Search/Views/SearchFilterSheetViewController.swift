import UIKit

/// The filter tray: three dimensions, each a segmented control, in a sheet.
///
/// # Why a sheet, and why segments
///
/// It was a `UIMenu` first. A menu is right for ONE dimension — one tap to
/// open, one to pick, and it dismisses itself. It is wrong for three: eleven
/// rows deep, nowhere to say what a group means, and it closes on every pick,
/// so setting two filters is two trips through the same control.
///
/// A sheet holds all three at once and keeps them on screen while the viewer
/// changes their mind. A segmented control per dimension makes the whole state
/// readable in one glance — which is the point of a sheet over a menu.
///
/// ⚠️ SOME SEGMENTS ARE DISABLED, AND THAT IS DELIBERATE RATHER THAN
/// UNFINISHED. `search.v1.SearchRequest` carries six fields — query,
/// entity_types, sort, page_size, page_token, exclude_author_ids — and
/// `SearchSort` has three values. So of the twelve segments this tray shows,
/// four can act. The rest are drawn because the product asked for them and
/// disabled because nothing can honour them, with the reason in the section
/// footer rather than left for the viewer to guess.
///
/// That is a change of mind from the menu, which omitted them on the rule that
/// "a disabled row is still a promise". A segmented control is different: the
/// options are the SHAPE of the choice, and hiding two of four segments makes
/// the dimension itself unreadable. Shown-and-explained beats absent here.
/// What is being asked for lives in `dev/BACKEND_GAPS.md` §19 and
/// `dev/issues/BACKEND_SEARCH_FILTERS.md`.
@MainActor
final class SearchFilterSheetViewController: UIViewController {

    /// One choice inside a dimension.
    struct Segment: Hashable {
        let id: String
        let title: String
        /// `false` when nothing can honour it — see the type's note.
        let isEnabled: Bool

        init(_ id: String, _ title: String, isEnabled: Bool = true) {
            self.id = id
            self.title = title
            self.isEnabled = isEnabled
        }
    }

    /// One dimension: a titled segmented control, plus the caveat under it.
    struct Group: Hashable {
        let id: String
        let title: String
        /// Why some segments cannot be picked. `nil` when they all can.
        let footer: String?
        let segments: [Segment]
        /// The segment in effect. Always one — a dimension with nothing chosen
        /// is a state this screen cannot render honestly.
        var selectedID: String

        var selectedIndex: Int {
            segments.firstIndex { $0.id == selectedID } ?? 0
        }
    }

    private var groups: [Group]
    private let onPick: (_ groupID: String, _ segmentID: String) -> Void

    /// What the sheet is showing, for tests. The groups are built by the screen
    /// that presents this, at presentation time, so this is the only way to
    /// check what a viewer is actually offered.
    var groupsForTesting: [Group] { groups }

    private let stack = UIStackView()
    private var controls: [String: UISegmentedControl] = [:]

    init(groups: [Group], onPick: @escaping (_ groupID: String, _ segmentID: String) -> Void) {
        self.groups = groups
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Wraps this in the navigation controller a sheet needs for its title bar,
    /// and asks for the detents the map's own filter sheet asks for.
    static func inSheet(
        groups: [Group],
        onPick: @escaping (_ groupID: String, _ segmentID: String) -> Void
    ) -> UIViewController {
        let sheet = SearchFilterSheetViewController(groups: groups, onPick: onPick)
        let navigation = UINavigationController(rootViewController: sheet)
        navigation.modalPresentationStyle = .pageSheet
        if let presentation = navigation.sheetPresentationController {
            // ⚠️ A CUSTOM DETENT SIZED TO THE CONTENT, with `.large` behind it.
            // The tray grows as dimensions land; a fixed `.medium` would leave
            // half a sheet of white under it today and clip it later.
            presentation.detents = [
                .custom(identifier: .init("filters")) { context in
                    min(sheet.contentHeight, context.maximumDetentValue)
                },
                .large()
            ]
            presentation.prefersGrabberVisible = true
            presentation.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        return navigation
    }

    /// The height the content needs, so the detent fits it rather than the
    /// content rattling around inside a detent.
    fileprivate var contentHeight: CGFloat {
        let footers = groups.count { $0.footer != nil }
        // bar + per-group (title 22 + control 34 + spacing 20) + footers + inset
        return 56 + CGFloat(groups.count) * 76 + CGFloat(footers) * 34 + 44
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Filters"
        view.backgroundColor = .systemGroupedBackground
        // ⚠️ LEADING, AND SPELLED OUT — both on precedent, not preference.
        //
        // Leading because there is nothing to commit: every pick applies to the
        // results underneath as it is made, so this sheet has a dismiss and no
        // affirmative. A trailing "Done" would be the second half of a
        // Cancel/Done pair whose first half does not exist, and would read as
        // "apply these" over filters that are already applied.
        //
        // Spelled out because `systemItem: .close` and `.done` draw as a
        // WORDLESS ✕ and ✓ on a sheet under iOS 26 — measured in-sim and
        // recorded on `MapSubFilterSheetViewController`, which spells its own
        // items out for the same reason: a bare checkmark on a screen full of
        // selections reads as one more selection.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Close",
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        configureStack()
    }

    private func configureStack() {
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20)
        ])

        for group in groups { stack.addArrangedSubview(dimensionView(for: group)) }
    }

    private func dimensionView(for group: Group) -> UIView {
        let title = UILabel()
        title.text = group.title
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .secondaryLabel

        let control = UISegmentedControl(items: group.segments.map(\.title))
        control.selectedSegmentIndex = group.selectedIndex
        // ⚠️ DISABLED PER SEGMENT, not per control. The dimension is readable —
        // four options, this is what they are — and the two that nothing can
        // honour refuse the tap instead of pretending to work.
        for (index, segment) in group.segments.enumerated() where !segment.isEnabled {
            control.setEnabled(false, forSegmentAt: index)
        }
        control.addAction(UIAction { [weak self, weak control] _ in
            guard let self, let control else { return }
            self.pick(groupID: group.id, index: control.selectedSegmentIndex)
        }, for: .valueChanged)
        controls[group.id] = control

        let column = UIStackView(arrangedSubviews: [title, control])
        column.axis = .vertical
        column.spacing = 8
        column.setCustomSpacing(8, after: title)

        guard let footerText = group.footer else { return column }
        let footer = UILabel()
        footer.text = footerText
        footer.font = .preferredFont(forTextStyle: .caption1)
        footer.adjustsFontForContentSizeCategory = true
        footer.textColor = .tertiaryLabel
        footer.numberOfLines = 0
        column.addArrangedSubview(footer)
        column.setCustomSpacing(8, after: control)
        return column
    }

    private func pick(groupID: String, index: Int) {
        guard let position = groups.firstIndex(where: { $0.id == groupID }),
              groups[position].segments.indices.contains(index)
        else { return }
        let segment = groups[position].segments[index]
        guard segment.isEnabled else {
            // Belt and braces: a disabled segment cannot be tapped, but it can
            // still be reached programmatically, and letting that through would
            // record a filter the screen cannot apply.
            controls[groupID]?.selectedSegmentIndex = groups[position].selectedIndex
            return
        }
        guard groups[position].selectedID != segment.id else { return }
        groups[position].selectedID = segment.id
        // ⚠️ THE SHEET STAYS UP. A menu closed on every pick, which made setting
        // two filters two trips through one control; the whole reason this is a
        // sheet is that the state stays visible while the viewer changes their
        // mind. The results underneath update as they go.
        onPick(groupID, segment.id)
    }
}
