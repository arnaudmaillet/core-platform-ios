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
    /// What was in effect when the sheet opened, so Cancel can put it back.
    ///
    /// ⚠️ TAKEN AT INIT, NOT AT `viewDidLoad`. A sheet presented, cancelled and
    /// presented again is a NEW instance each time, but a `viewDidLoad` capture
    /// would also re-run on a view reload and quietly re-baseline to whatever
    /// was picked in between.
    private let openingSelection: [String: String]
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
        openingSelection = Dictionary(
            groups.map { ($0.id, $0.selectedID) }, uniquingKeysWith: { first, _ in first }
        )
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
            // ⚠️ ONE DETENT, AND `.large()` IS GONE ON PURPOSE. This sheet is
            // three rows of controls; dragged to full height it left most of
            // the screen empty and hid the results the filters act on, which
            // are the only reason to look at it. Its own content is the
            // ceiling.
            presentation.detents = [
                .custom(identifier: .init("filters")) { context in
                    min(sheet.contentHeight, context.maximumDetentValue)
                }
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
        // ⚠️ CANCEL REVERTS, DONE ACCEPTS — and the pair only makes sense
        // because the picks apply LIVE. The results underneath change as the
        // viewer moves a segment, which is the point of a sheet over a menu; so
        // "Cancel" cannot mean "discard an uncommitted buffer" (there is none)
        // and instead means "put back what was in effect when this opened".
        // `openingSelection` is that snapshot.
        //
        // ⚠️ SPELLED OUT, NOT `systemItem`. iOS 26 draws the system Done and
        // Cancel items as a WORDLESS ✓ and ✕ on a sheet — measured in-sim and
        // recorded on `MapSubFilterSheetViewController`, which spells its own
        // out for the same reason: on a screen made of selections, a bare
        // checkmark reads as one more selection.
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Cancel",
            primaryAction: UIAction { [weak self] _ in self?.revertAndDismiss() }
        )
        let done = UIBarButtonItem(
            title: "Done",
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        // `.prominent` (iOS 26's rename of `.done`) gives the affirmative its
        // filled accent capsule — the same weight the map's filter sheet gives
        // its own commit, and the same reason: abandoning should never be the
        // more prominent of the two.
        done.style = .prominent
        navigationItem.rightBarButtonItem = done
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
        // ⚠️ THE CONFLICT IS MOSTLY THE DISABLED SEGMENTS, and that is worth
        // knowing because it dates this code. A segmented control tracks a
        // finger sliding ACROSS it — that is how you scrub between options
        // without lifting — and a sheet tracks a finger dragging it DOWN. An
        // ENABLED segment consumes the touch and the two never meet; a DISABLED
        // one does not, so the sheet's pan takes it and the sheet slides away
        // under a finger that was aiming at an option.
        //
        // Seven of twelve segments are disabled today because `search.v1`
        // cannot honour them (see `filterGroups`). When it can, they are either
        // enabled or gone, and this guard has almost nothing left to do — it
        // stays for the diagonal drag on an enabled segment, which is the same
        // race with a much smaller window.
        //
        // So the sheet's own pan stands down for the length of the touch.
        control.addAction(UIAction { [weak self] _ in self?.setSheetDragEnabled(false) },
                          for: [.touchDown, .touchDragInside, .touchDragOutside])
        control.addAction(UIAction { [weak self] _ in self?.setSheetDragEnabled(true) },
                          for: [.touchUpInside, .touchUpOutside, .touchCancel])
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

    /// Puts every dimension back to what it was when this opened, then closes.
    ///
    /// ⚠️ THROUGH `onPick`, the same channel a tap uses. Reverting by writing
    /// the controls and skipping the callback would leave the sheet showing one
    /// thing and the results underneath showing another — the exact split this
    /// sheet exists to avoid.
    private func revertAndDismiss() {
        revertForTesting()
        dismiss(animated: true)
    }

    /// Turns the sheet's drag-to-dismiss off while a segment is being touched.
    ///
    /// ⚠️ FOUND BY RELATIONSHIP, NOT BY CLASS NAME, and guarded at every step.
    /// `UISheetPresentationController` exposes no pan of its own, so the
    /// recognizer is reached where UIKit installs it — on the presented view
    /// and the container above it. Anything unexpected there is simply left
    /// alone: the failure mode of this not finding the gesture is the conflict
    /// it was written to remove, which is what shipped before it existed. The
    /// failure mode of it disabling the wrong thing would be a sheet that
    /// cannot be dismissed, so it only ever touches `UIPanGestureRecognizer`
    /// and always turns them back on.
    private func setSheetDragEnabled(_ isEnabled: Bool) {
        let hosts = [
            navigationController?.presentationController?.presentedView,
            navigationController?.presentationController?.containerView
        ]
        for host in hosts.compactMap({ $0 }) {
            for gesture in host.gestureRecognizers ?? [] where gesture is UIPanGestureRecognizer {
                gesture.isEnabled = isEnabled
            }
        }
    }

    /// Picks a segment the way a tap does. The controls are private and a
    /// segmented control's selection cannot be driven through `sendActions`
    /// (measured on `UISearchTextField`'s editing events, same class of
    /// problem), so the seam is the pick itself rather than the touch.
    func pickForTesting(groupID: String, segmentID: String) {
        guard let position = groups.firstIndex(where: { $0.id == groupID }),
              let index = groups[position].segments.firstIndex(where: { $0.id == segmentID })
        else { return }
        pick(groupID: groupID, index: index)
    }

    /// Cancel, without the dismissal a test has no presenter for.
    func revertForTesting() {
        for (position, group) in groups.enumerated() {
            guard let original = openingSelection[group.id], original != group.selectedID
            else { continue }
            groups[position].selectedID = original
            controls[group.id]?.selectedSegmentIndex = groups[position].selectedIndex
            onPick(group.id, original)
        }
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
