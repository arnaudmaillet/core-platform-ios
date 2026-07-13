import DesignSystem
import UIKit

/// Inset-grouped table whose content hugs the BOTTOM of the visible area —
/// above the keyboard while it is up — instead of the top. Implemented as a
/// top content inset recomputed each layout pass: the inset absorbs the free
/// space, so when content outgrows the viewport (accessibility sizes) the
/// inset collapses to zero and the table degrades to normal scrolling.
///
/// Also owns the flow's shared section metrics: zeroed implicit top padding,
/// collapsed footers, and self-sizing headers, so every visible gap belongs
/// to an explicit header height.
class BottomAnchoredTableViewController: UITableViewController {
    /// The flow-shared toolbar items (language selector + legal links),
    /// injected by the coordinator BEFORE the controller's view loads.
    /// Crucially these are the SAME instances on every step: items with
    /// `hidesSharedBackground` are composited only after a toolbar content
    /// transition settles, so any per-screen item diff makes the bare text
    /// items pop in late — with identical instances the toolbar has no diff
    /// to animate and the whole bar stays rendered through the push.
    var flowToolbarItems: [UIBarButtonItem] = []

    /// Footers collapse to 1pt (a literal 0 falls back to the grouped
    /// default), set via the `sectionFooterHeight`/`estimatedSectionFooterHeight`
    /// PROPERTIES — with the estimate left automatic, the footer-height
    /// delegate is consulted but its value never lands, and every footer
    /// renders at the ~17pt default. Header insets absorb the 1pt where a
    /// gap must be exact.
    static let collapsedFooterHeight: CGFloat = 1

    override func viewDidLoad() {
        super.viewDidLoad()
        // A bottom-pinned form shouldn't bounce when everything fits.
        tableView.alwaysBounceVertical = false
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 24
        tableView.sectionHeaderTopPadding = 0
        tableView.sectionFooterHeight = Self.collapsedFooterHeight
        tableView.estimatedSectionFooterHeight = Self.collapsedFooterHeight

        // The legal footer rides at the very end of the content, which the
        // bottom anchoring keeps at the canvas bottom (above the keyboard
        // when up, above the home indicator otherwise).
        // Flow chrome (language switcher + legal links) lives in the
        // navigation controller's bottom toolbar. The keyboard covers bottom
        // bars while up (standard UIKit), so it surfaces whenever the
        // keyboard is down.
        toolbarItems = flowToolbarItems
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
    }

    #if DEBUG
    /// `-login-landscape`: rotates the scene on appear — sim QA for the
    /// toolbar split layout (no tap/rotation injection available).
    /// `-login-layout-audit`: prints the resolved section/header/footer/row
    /// frames so spacing can be audited numerically from the console.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-login-landscape") {
            view.window?.windowScene?.requestGeometryUpdate(
                .iOS(interfaceOrientations: .landscapeRight)
            )
        }
        if arguments.contains("-login-layout-audit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
                print("AUDIT sectionHeaderTopPadding=\(tableView.sectionHeaderTopPadding)")
                for section in 0..<tableView.numberOfSections {
                    let header = tableView.rectForHeader(inSection: section)
                    let row = tableView.rectForRow(at: IndexPath(row: 0, section: section))
                    let footer = tableView.rectForFooter(inSection: section)
                    print("AUDIT s\(section) header=\(header.minY)..\(header.maxY) row=\(row.minY)..\(row.maxY) footer=\(footer.minY)..\(footer.maxY)")
                }
            }
        }
    }
    #endif

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        anchorContentToBottom()
    }

    /// Plain-text link row (clear background, centered, tinted) — the flow's
    /// secondary-action register: Forgot Password, Create Account.
    func makeLinkCell(title: String) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.backgroundConfiguration = .clear()
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.alignment = .center
        content.textProperties.color = .tintColor
        content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
        cell.contentConfiguration = content
        cell.accessibilityTraits = .button
        return cell
    }

    /// The Telegram-style hero block heading the credential screens: a big
    /// emoji glyph, bold title, and quiet subtitle, centered.
    func makeHeroHeader(emoji: String, title: String, subtitle: String) -> UITableViewHeaderFooterView {
        let icon = UILabel()
        icon.text = emoji
        icon.font = .systemFont(ofSize: 64)
        icon.isAccessibilityElement = false

        let titleLabel = UILabel()
        titleLabel.text = title
        let descriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .title1)
        titleLabel.font = UIFont(descriptor: descriptor.withSymbolicTraits(.traitBold) ?? descriptor, size: 0)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.md

        let header = UITableViewHeaderFooterView()
        stack.constrain(in: header.contentView) { parent in
            stack.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            stack.widthAnchor.constraint(lessThanOrEqualTo: parent.widthAnchor)
            stack.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.sm)
            stack.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Spacing.xl)
        }
        return header
    }

    /// Centered single-label section header, used for the flow's in-layout
    /// text ("or" separator, contextual email line).
    func makeCenteredTextHeader(
        text: String,
        textStyle: UIFont.TextStyle,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) -> UITableViewHeaderFooterView {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: textStyle)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0

        let header = UITableViewHeaderFooterView()
        label.constrain(in: header.contentView) { parent in
            label.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            label.widthAnchor.constraint(lessThanOrEqualTo: parent.widthAnchor)
            label.topAnchor.constraint(equalTo: parent.topAnchor, constant: topInset)
            label.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -bottomInset)
        }
        return header
    }

    private func anchorContentToBottom() {
        // adjustedContentInset.bottom carries the keyboard overlap (plus the
        // home indicator); the top system inset is read from safeAreaInsets
        // because adjustedContentInset.top would echo the pad being set here.
        let available = tableView.bounds.height
            - tableView.safeAreaInsets.top
            - tableView.adjustedContentInset.bottom
        let pad = max(0, available - tableView.contentSize.height)
        guard tableView.contentInset.top != pad else { return }
        tableView.contentInset.top = pad
        tableView.contentOffset.y = -(pad + tableView.safeAreaInsets.top)
    }
}
