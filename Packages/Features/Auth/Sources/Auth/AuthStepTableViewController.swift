import DesignSystem
import UIKit

/// Every sign-in step's inset-grouped table, its content laid from the TOP
/// (#1908, the owner): the hero, the field and the primary button under the
/// bar, so the keyboard's arrival moves nothing. It used to hug the bottom of
/// the visible area — a block waiting at the foot of a full-height sheet,
/// then climbing with the keyboard: three motions before the viewer could
/// type. At the largest text sizes the content scrolls.
///
/// Also owns the flow's shared section metrics: zeroed implicit top padding,
/// collapsed footers, and self-sizing headers, so every visible gap belongs
/// to an explicit header height.
class AuthStepTableViewController: UITableViewController {
    /// Footers collapse to 1pt (a literal 0 falls back to the grouped
    /// default), set via the `sectionFooterHeight`/`estimatedSectionFooterHeight`
    /// PROPERTIES — with the estimate left automatic, the footer-height
    /// delegate is consulted but its value never lands, and every footer
    /// renders at the ~17pt default. Header insets absorb the 1pt where a
    /// gap must be exact.
    static let collapsedFooterHeight: CGFloat = 1

    override func viewDidLoad() {
        super.viewDidLoad()
        // A form that fits shouldn't bounce.
        tableView.alwaysBounceVertical = false
        // No effect under the bar: the rows run up under the pills untouched — see
        // `prefersClearTopEdge`.
        tableView.prefersClearTopEdge()
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 24
        tableView.sectionHeaderTopPadding = 0
        tableView.sectionFooterHeight = Self.collapsedFooterHeight
        tableView.estimatedSectionFooterHeight = Self.collapsedFooterHeight
    }

    #if DEBUG
    /// `-login-landscape`: rotates the scene on appear — sim QA for the
    /// landscape layout (no tap/rotation injection available).
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

    /// Plain-text link row (clear background, centered, tinted) — the flow's
    /// secondary-action register: Resend, Read the Privacy Policy.
    func makeLinkCell(title: String) -> UITableViewCell {
        let cell = UITableViewCell()
        cell.backgroundConfiguration = .clear()
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.cell()
        content.text = title
        content.textProperties.alignment = .center
        content.textProperties.color = .tintColor
        content.textProperties.font = .appFont(forTextStyle: .subheadline)
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
        subtitleLabel.font = .appFont(forTextStyle: .subheadline)
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
}

extension UIViewController {
    /// The step's field takes focus AS the push runs (#1908): the keyboard
    /// rises in the same animation as the slide and the sheet's growth, and
    /// from one step to the next it hands over in place — never down and up
    /// again. A step's `viewDidAppear` focus stays the fallback.
    func focusAlongTransition(_ field: UIResponder) {
        guard let coordinator = transitionCoordinator else { return }
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.view.layoutIfNeeded()
            field.becomeFirstResponder()
        })
    }
}

// MARK: - How it is left (#1144)

extension AuthStepTableViewController: StackScreen {
    /// A sign-in step hides its back button where going back would lose the flow.
    var leaving: ScreenLeaving { .nativeBack(unlessHiddenIn: navigationItem) }
}
