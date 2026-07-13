import DesignSystem
import UIKit

/// Screen 1 of the sign-in flow: an explicit method menu — the federated
/// providers plus the email and phone credential flows — with the account
/// creation action set off below an "or" separator. No input, no keyboard:
/// a pure branch point. Dumb view: reports selections upward; the flow
/// coordinator decides where to go.
final class MethodSelectionViewController: BottomAnchoredTableViewController {
    var onMethodSelected: ((SignInMethod) -> Void)?
    var onCreateAccount: (() -> Void)?

    private static let methodCornerRadius: CGFloat = 12

    /// Each method gets its own standalone section (one row each); the
    /// sign-up link closes the menu below the "or" separator.
    private enum Section: Equatable {
        case method(SignInMethod)
        case createAccount
    }

    private let sections: [Section] =
        SignInMethod.all.map(Section.method) + [.createAccount]

    private lazy var createAccountCell = makeLinkCell(title: "Create an Account")

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .createAccount:
            return createAccountCell
        case .method(let method):
            let cell = UITableViewCell()
            // Sharper corners than input capsules so methods read as
            // distinct buttons; the update handler keeps the native
            // pressed-state tint.
            cell.configurationUpdateHandler = { cell, state in
                var background = UIBackgroundConfiguration.listGroupedCell().updated(for: state)
                background.cornerRadius = Self.methodCornerRadius
                cell.backgroundConfiguration = background
            }
            var content = UIListContentConfiguration.cell()
            content.text = method.displayName
            content.image = method.icon
            content.imageProperties.tintColor = .label
            content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
            cell.contentConfiguration = content
            cell.accessibilityTraits = .button
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .method(let method):
            onMethodSelected?(method)
        case .createAccount:
            onCreateAccount?()
        }
    }

    /// The "or" separator sits between the method menu and the account
    /// creation action, as the sign-up section's header so it travels with
    /// the grouped layout.
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard sections[section] == .createAccount else { return nil }
        return makeCenteredTextHeader(
            text: "or",
            textStyle: .footnote,
            topInset: Spacing.lg - Self.collapsedFooterHeight,
            bottomInset: Spacing.lg
        )
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        switch sections[section] {
        case .method(let method):
            if method == SignInMethod.all.first {
                return Spacing.xl // breathing room under the nav bar
            }
            return Spacing.sm - Self.collapsedFooterHeight // tight cohesive menu
        case .createAccount:
            return UITableView.automaticDimension // the "or" separator view
        }
    }
}

private extension SignInMethod {
    /// Row artwork. Apple has a native SF Symbol; the other providers are
    /// monogram placeholders until licensed brand assets are bundled.
    var icon: UIImage? {
        switch self {
        case .provider(.apple): UIImage(systemName: "apple.logo")
        case .provider(.google): UIImage(systemName: "g.circle")
        case .provider(.microsoft): UIImage(systemName: "m.square")
        case .email: UIImage(systemName: "envelope")
        case .phone: UIImage(systemName: "phone")
        }
    }
}
