import DesignSystem
import UIKit

/// Screen 1 of the sign-in flow: an explicit method menu — the federated
/// providers plus the email and phone credential flows — under one fixed
/// title, "Log in or sign up" (#1969): every method logs an account in and
/// signs a new one up (a code proves the address, and an address with an
/// account signs straight in, #840), so there is no separate "Log in" link.
/// It ends on the legal line. Its bar carries help (?) leading and close (×)
/// trailing (#1969, reversing #1811's bar-less list). No input, no keyboard:
/// a pure branch point in a content-fitted sheet. Dumb view: reports
/// selections upward; the flow coordinator decides where to go.
final class MethodSelectionViewController: AuthStepTableViewController {
    var onMethodSelected: ((SignInMethod) -> Void)?
    /// The legal line's pages (#1811); a nil one shows its name as plain text.
    var legalLinks = AuthLegalLinks()
    /// A legal link was tapped: the flow opens the page in place.
    var onOpenLink: ((URL) -> Void)?
    /// The help item (?) was tapped. Not wired yet (#1969): nil, and the tap
    /// does nothing — no alert, no haptic.
    var onHelp: (() -> Void)?
    /// The close item (×) was tapped: the flow closes the sheet, as a swipe.
    var onClose: (() -> Void)?

    /// The sheet's title, whatever opened it (#1969): every method both logs
    /// in and signs up, so neither word alone.
    static let sheetTitle = "Log in or sign up"
    static let helpItemIdentifier = "auth.methods.help"
    static let closeItemIdentifier = "auth.methods.close"

    // The form's steps wear the same two (`AuthFormBar`, #2022).
    private lazy var helpItem = AuthFormBar.makeHelpItem(identifier: Self.helpItemIdentifier) { [weak self] in
        self?.onHelp?()
    }

    private lazy var closeItem = AuthFormBar.makeCloseItem(identifier: Self.closeItemIdentifier) { [weak self] in
        self?.onClose?()
    }

    private static let methodCornerRadius: CGFloat = 12

    /// Each method gets its own standalone section (one row each); the legal
    /// line closes the list, as a header with no rows.
    private enum Section: Equatable {
        case method(SignInMethod)
        case legal
    }

    private let methods: [SignInMethod]
    private let sections: [Section]

    /// The method whose sign-in is running (Sign in with Apple): its row
    /// carries a spinner until the call ends (#827).
    private(set) var workingMethod: SignInMethod?

    init(methods: [SignInMethod] = SignInMethod.all) {
        self.methods = methods
        sections = methods.map(Section.method) + [.legal]
        super.init(style: .insetGrouped)
        // An inline title in the bar's own appearance, as on the form's steps.
        title = Self.sheetTitle
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = helpItem
        navigationItem.rightBarButtonItem = closeItem
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }


    /// ⚠️ NO SCROLL WHILE THE LIST FITS (#1908, the owner 2026-10-30: the
    /// sheet scrolled though nothing was hidden). The table's content runs
    /// past what the sheet shows — the grouped table's trailing padding and
    /// the bottom inset the sheet stands clear of (`fittedHeight`) — so a
    /// drag moved a list that was all on screen. It scrolls only when the
    /// last section's end is past the sheet's: the largest text, a small
    /// phone, where the sheet is capped at the screen.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.isScrollEnabled = Self.needsScroll(
            contentEnd: tableView.rectForFooter(inSection: sections.count - 1).maxY,
            topInset: tableView.adjustedContentInset.top, visibleHeight: tableView.bounds.height
        )
    }

    /// Whether content ending at `contentEnd` overflows a table showing
    /// `visibleHeight` under `topInset`. Pure, for tests.
    static func needsScroll(contentEnd: CGFloat, topInset: CGFloat, visibleHeight: CGFloat) -> Bool {
        topInset + contentEnd > visibleHeight + 1
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section] == .legal ? 0 : 1
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .legal:
            return UITableViewCell()
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
            showWorking(on: cell, for: method)
            return cell
        }
    }

    /// Puts the spinner on `method`'s row, or takes it off every row with nil.
    /// The coordinator locks the screen itself; this is only what it shows.
    func setWorking(_ method: SignInMethod?) {
        workingMethod = method
        // ⚠️ × WAITS FOR THE CALL (#1969). Sign in with Apple or a passkey
        // goes on in the system's sheet and on the server; closing under it
        // would leave its answer — a birthday step, a second step, an error
        // — nowhere to land. The row's spinner says why.
        closeItem.isEnabled = method == nil
        guard isViewLoaded else { return }
        for (index, section) in sections.enumerated() {
            guard case .method(let candidate) = section,
                  let cell = tableView.cellForRow(at: IndexPath(row: 0, section: index))
            else { continue }
            showWorking(on: cell, for: candidate)
        }
    }

    private func showWorking(on cell: UITableViewCell, for method: SignInMethod) {
        guard method == workingMethod else {
            cell.accessoryView = nil
            return
        }
        let spinner = AppLoaderView(size: .medium)
        spinner.startAnimating()
        cell.accessoryView = spinner
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .method(let method):
            onMethodSelected?(method)
        case .legal:
            break
        }
    }

    /// The legal line under the last method; nothing over the first.
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        switch sections[section] {
        case .method:
            return nil
        case .legal:
            return makeLegalHeader()
        }
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        switch sections[section] {
        case .method(let method):
            // The list opens one side margin under the bar, as the rows sit
            // from the sheet's sides.
            if method == methods.first { return Spacing.lg }
            return Spacing.sm - Self.collapsedFooterHeight // tight cohesive menu
        case .legal:
            return UITableView.automaticDimension
        }
    }

    /// The legal line, as text. Tests.
    var debugLegalLine: NSAttributedString { Self.legalLine(legalLinks) }
}

/// The two pages the sign-in sheet's legal line opens (#1811) — the same as
/// Settings → Support and Legal's, injected by the composition root (Auth does
/// not import Profile). Nil while the page has no address yet: the name is
/// plain text then, never a dead link.
public struct AuthLegalLinks: Equatable, Sendable {
    public var termsOfService: URL?
    public var privacyPolicy: URL?

    public init(termsOfService: URL? = nil, privacyPolicy: URL? = nil) {
        self.termsOfService = termsOfService
        self.privacyPolicy = privacyPolicy
    }
}

extension MethodSelectionViewController: UITextViewDelegate {
    /// "By continuing, you agree to our Terms of Service and acknowledge our
    /// Privacy Policy." — each name a link to its page when it has one.
    static func legalLine(_ links: AuthLegalLinks) -> NSAttributedString {
        let font = UIFont.appFont(forTextStyle: .footnote)
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.secondaryLabel]
        let line = NSMutableAttributedString(string: "By continuing, you agree to our ", attributes: base)
        func name(_ text: String, _ url: URL?) {
            var attributes = base
            if let url { attributes[.link] = url }
            line.append(NSAttributedString(string: text, attributes: attributes))
        }
        name("Terms of Service", links.termsOfService)
        line.append(NSAttributedString(string: " and acknowledge our ", attributes: base))
        name("Privacy Policy", links.privacyPolicy)
        line.append(NSAttributedString(string: ".", attributes: base))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return line
    }

    func textView(
        _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
    ) -> UIAction? {
        guard case .link(let url) = textItem.content else { return defaultAction }
        return UIAction { [weak self] _ in self?.onOpenLink?(url) }
    }
}

private extension MethodSelectionViewController {
    /// The legal line closing the list.
    func makeLegalHeader() -> UITableViewHeaderFooterView {
        let text = UITextView()
        text.attributedText = Self.legalLine(legalLinks)
        text.adjustsFontForContentSizeCategory = true
        text.isEditable = false
        text.isScrollEnabled = false
        text.backgroundColor = .clear
        text.textContainerInset = .zero
        text.textContainer.lineFragmentPadding = 0
        text.linkTextAttributes = [.foregroundColor: UIColor.label, .underlineStyle: NSUnderlineStyle.single.rawValue]
        text.delegate = self
        let header = UITableViewHeaderFooterView()
        text.constrain(in: header.contentView) { parent in
            text.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: Spacing.lg)
            text.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -Spacing.lg)
            text.topAnchor.constraint(equalTo: parent.topAnchor, constant: Spacing.lg)
            // The sheet's bottom margin (#1908): the side margin, nothing more
            // (`ContentFittingNavigationController.fittedHeight`).
            text.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -Spacing.lg)
        }
        return header
    }
}

private extension SignInMethod {
    /// Row artwork. Apple has a native SF Symbol; the other providers are
    /// monogram placeholders until licensed brand assets are bundled.
    var icon: UIImage? {
        switch self {
        case .provider(.apple): UIImage(systemName: "apple.logo")
        case .provider(.google): UIImage(systemName: "g.circle")
        case .email: UIImage(systemName: "envelope")
        case .phone: UIImage(systemName: "phone")
        case .passkey: UIImage(systemName: "person.badge.key")
        }
    }
}
