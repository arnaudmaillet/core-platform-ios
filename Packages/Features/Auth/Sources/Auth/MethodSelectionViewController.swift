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
        // Locked at once under a running sign-in, greyed only once its load
        // shows (#2270, `applyGating`).
        guard let self, !locksOthers else { return }
        onClose?()
    }


    /// Each method gets its own standalone section (one row each); the legal
    /// line closes the list, as a header with no rows.
    private enum Section: Equatable {
        case method(SignInMethod)
        case legal
    }

    private let methods: [SignInMethod]
    private let sections: [Section]

    /// The method whose sign-in is running (Sign in with Apple): its button
    /// holds its load until the call ends (#2020; a spinner, #827).
    private(set) var workingMethod: SignInMethod?

    /// Each method's button, made once (#2020): the app's own, at its form
    /// size, a card on the quiet ground — Apple's on its monochrome one.
    private var buttons: [SignInMethod: AppButton] = [:]
    /// Each method's row, made once, hosting its button on a clear ground.
    private var cells: [SignInMethod: UITableViewCell] = [:]
    /// Whether the other methods and × refuse taps: from the call's start to
    /// the end of its answer (#1969).
    private(set) var locksOthers = false
    /// The method whose load is drawn — past the button's grace with the call
    /// still running (#2270): only then do the others and × turn grey.
    private(set) var shownLoad: SignInMethod?

    /// - Parameter loadClock: the buttons' load time (their grace and
    ///   minimum, #2270). A test steps it.
    init(methods: [SignInMethod] = SignInMethod.all, loadClock: LoadingClock = .system) {
        self.methods = methods
        sections = methods.map(Section.method) + [.legal]
        super.init(style: .insetGrouped)
        for method in methods {
            let button = AppButton(
                aspect: .pill(method.ground), size: .form, shape: .card,
                content: AppButton.Content(title: method.displayName, symbol: method.symbolName)
            )
            // The tap is the button's, not the row's selection: no grey row
            // highlight, the button's swell instead.
            button.addAction(UIAction { [weak self] _ in self?.onMethodSelected?(method) }, for: .primaryActionTriggered)
            button.loadClock = loadClock
            button.onLoadShownChange = { [weak self] shown in self?.loadShown(shown, by: method) }
            buttons[method] = button
        }
        // An inline title in the bar's own appearance, as on the form's steps.
        title = Self.sheetTitle
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = helpItem
        navigationItem.rightBarButtonItem = closeItem
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The sheet's ground: OPAQUE, the form's own grouped grey — no glass
    /// and no blur through it (the owner, 2026-11-07).
    ///
    /// ⚠️ **RESOLVED OUTSIDE THE SHEET.** In a glass sheet at its fitted
    /// height `systemGroupedBackground` resolves to the glass's own ground:
    /// white in the light and clear in the dark, where the sheet went back
    /// to blur (the owner's iPhone). Its elevated light and dark values
    /// are taken here, with nothing of the sheet's context, at full alpha.
    static let sheetBackground = UIColor { traits in
        let plain = UITraitCollection { mutable in
            mutable.userInterfaceStyle = traits.userInterfaceStyle == .dark ? .dark : .light
            mutable.userInterfaceLevel = .elevated
            mutable.accessibilityContrast = traits.accessibilityContrast
        }
        return UIColor.systemGroupedBackground.resolvedColor(with: plain).withAlphaComponent(1)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = Self.sheetBackground
    }

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
            return cell(for: method)
        }
    }

    private func cell(for method: SignInMethod) -> UITableViewCell {
        if let cell = cells[method] { return cell }
        guard let button = buttons[method] else { return UITableViewCell() }
        let cell = AuthButtonCell(hosting: button)
        cells[method] = cell
        return cell
    }

    /// Puts `method`'s button in its held load, the others gated — or ends
    /// it everywhere with nil. The coordinator locks the screen itself; this
    /// is only what it shows.
    ///
    /// ⚠️ LOCKED AT ONCE, GREY ONLY ONCE THE LOAD SHOWS (#2270). The others
    /// and × refuse taps from the start (#1969), but turn grey only when the
    /// button's grace has passed with the call still running: a fast
    /// sign-in shows nothing but the press, then the sheet going down.
    ///
    /// - Parameter completion: runs once the answer may show — at once, or,
    ///   ending a load drawn for less than its minimum, at that minimum's
    ///   end. The lock lifts then too.
    func setWorking(_ method: SignInMethod?, completion: (@MainActor () -> Void)? = nil) {
        let previous = workingMethod
        workingMethod = method
        if method != nil { locksOthers = true }
        let animated = isViewLoaded
        for (candidate, button) in buttons where candidate != previous {
            button.setPhase(candidate == method ? .loading : .content, animated: animated)
        }
        applyGating()
        let ended: @MainActor () -> Void = { [weak self] in
            if let self, workingMethod == nil {
                locksOthers = false
                applyGating()
            }
            completion?()
        }
        // The answer waits for the load it ends.
        guard let previous, let button = buttons[previous] else { return ended() }
        button.setPhase(previous == method ? .loading : .content, animated: animated, completion: ended)
    }

    /// The call answered: its load ends, and this returns once the answer
    /// may show (#2270) — the caller's next step, the sheet going down, an
    /// error, never shows before the load has ended.
    func endWorking() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            setWorking(nil) { continuation.resume() }
        }
    }

    /// A method's load was drawn, or has ended.
    private func loadShown(_ shown: Bool, by method: SignInMethod) {
        if shown {
            shownLoad = method
        } else if shownLoad == method {
            shownLoad = nil
        }
        applyGating()
    }

    /// The others' and ×'s look and taps, from the lock and the load shown.
    private func applyGating() {
        // ⚠️ × WAITS FOR THE CALL (#1969). Sign in with Apple or a passkey
        // goes on in the system's sheet and on the server; closing under it
        // would leave its answer — a birthday step, a second step, an error
        // — nowhere to land. The button's load says why, once it shows.
        closeItem.isEnabled = shownLoad == nil
        for (candidate, button) in buttons {
            let isWorking = candidate == workingMethod || candidate == shownLoad
            button.isEnabled = shownLoad == nil || isWorking
            button.isLocked = locksOthers && !isWorking
        }
    }

    #if DEBUG
    /// A method's button. Tests.
    func debugButton(for method: SignInMethod) -> AppButton? { buttons[method] }
    var debugCloseItem: UIBarButtonItem { closeItem }
    #endif

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

extension SignInMethod {
    /// The button's symbol. Apple has a native SF Symbol; Google keeps a
    /// placeholder until licensed brand assets are bundled — then an
    /// `.image` icon in its own colours (`AppButton.Icon`, #2020).
    var symbolName: String {
        switch self {
        case .provider(.apple): "apple.logo"
        case .provider(.google): "g.circle"
        case .email: "envelope"
        case .phone: "phone"
        case .passkey: "person.badge.key"
        }
    }

    /// The button's ground. ⚠️ SIGN IN WITH APPLE'S GUIDELINES: a custom
    /// button keeps the Apple logo and "Continue with Apple" on a black, a
    /// white or a white-outlined ground — black in the light, white in the
    /// dark here (`.monochrome`); a grey one does not qualify. The others
    /// are quiet.
    var ground: AppButton.Ground {
        self == .provider(.apple) ? .monochrome : .quiet
    }
}
