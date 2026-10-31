import UIKit

/// A toast's whole message, for a toast whose one line is cut (#1449): a tap
/// on it opens this bottom sheet.
///
/// ⚠️ A BOTTOM SHEET, THE SYSTEM'S. UIKit has no top sheet
/// (`UISheetPresentationController` only attaches to the bottom edge), and
/// a hand-made one would not match the system's glass, corners, dismissal
/// physics or VoiceOver handling: native chrome stays UIKit's (the owner's
/// rule, #1449).
///
/// It reads (the owner, 2026-10-19):
/// - the navigation bar: a close ✕ at its trailing end;
/// - the toast's glyph, large, in its style's ink, then the whole message
///   (multi-line, Dynamic Type);
/// - the toolbar, when the toast has an action (Undo, Retry): that action,
///   filling the bar, in NEUTRAL glass — never the brand's pink.
///
/// Presented wrapped (`wrappedInSheet`): a navigation controller whose bar
/// and toolbar are the sheet's own. One custom detent, as tall as the
/// content and the toolbar.
///
/// **THE CONTENT STARTS BEHIND THE NAVIGATION BAR**, as the sound sheet's
/// does (the owner, 2026-10-19): the bar holds only the ✕ at its trailing
/// end, and the glyph stands `inset` under the grabber, level with it, the
/// ✕ floating over the trailing corner.
///
/// The toast waits while it is up (`ToastCountdown.Hold.sheet`); acting
/// from here runs the toast's action, which dismisses both; closing it any
/// other way leaves the toast as it was.
@MainActor
final class ToastMessageSheet: UIViewController {
    private let message: String
    private let glyph: UIImage?
    private let glyphTint: UIColor
    private let actionTitle: String?
    /// The action, chosen here: run once the sheet has gone.
    var onAction: (() -> Void)?
    /// The sheet has gone, whichever way.
    var onGone: (() -> Void)?

    private let stack = UIStackView()
    private(set) var glyphView: UIImageView?
    private(set) var messageLabel = UILabel()
    /// The toolbar's one item, filling it — nil without an action.
    private(set) var actionButton: StretchedBarLabel?
    /// The bar's close ✕.
    private(set) lazy var closeItem: UIBarButtonItem = {
        let item = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in self?.close() })
        item.identifier = "toastSheet.close"
        return item
    }()
    private var hasGone = false

    /// The glyph's size: large, the sheet's headline (the owner, 2026-10-19).
    static let glyphPointSize: CGFloat = 52
    /// The content's room from the sheet's top and sides — the sound sheet's
    /// `headerInset`.
    static let inset: CGFloat = 2 * Spacing.sm

    init(message: String, glyph: UIImage?, glyphTint: UIColor, actionTitle: String?) {
        self.message = message
        self.glyph = glyph
        self.glyphTint = glyphTint
        self.actionTitle = actionTitle
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The sheet as presented: a navigation controller for the bar's ✕ and
    /// the toolbar's action, a page sheet with a grabber and one detent.
    func wrappedInSheet() -> UINavigationController {
        let navigation = UINavigationController(rootViewController: self)
        navigation.setToolbarHidden(actionTitle == nil, animated: false)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.detents = [.custom(identifier: Self.detent) { [weak self] context in
                guard let self else { return nil }
                return min(sheetHeight(), context.maximumDetentValue)
            }]
        }
        return navigation
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Clear: the sheet's own glass is the surface.
        view.backgroundColor = .clear
        navigationItem.rightBarButtonItem = closeItem

        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Spacing.lg
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        // Behind the bar, not under it: from the sheet's own top edge.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.inset),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Self.inset),
        ])

        if let glyph {
            let glyphView = UIImageView(image: glyph)
            glyphView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
                pointSize: Self.glyphPointSize, weight: .regular
            )
            glyphView.tintColor = glyphTint
            glyphView.contentMode = .scaleAspectFit
            glyphView.isAccessibilityElement = false
            self.glyphView = glyphView
            stack.addArrangedSubview(glyphView)
        }

        messageLabel.text = message
        messageLabel.font = .appFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .label
        messageLabel.numberOfLines = 0
        stack.addArrangedSubview(messageLabel)
        messageLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        if let actionTitle {
            // The action, filling the toolbar, in NEUTRAL glass (the owner,
            // 2026-10-19: never pink here) — the BAR's bubble, plain (#1679,
            // `BarItems.stretched`: there is no flexible-width bar item, and
            // a title item's `width` is ignored on iOS 27).
            let made = BarItems.stretched(id: "toastSheet.action", title: actionTitle) { [weak self] in self?.act() }
            actionButton = made.label
            toolbarItems = [made.item]
        }
    }

    static let detent = UISheetPresentationController.Detent.Identifier("toast.fullMessage")

    /// The sheet's height: the content at the sheet's width, from its top,
    /// and the toolbar when it shows — measured, never laid out by the
    /// detent itself.
    func sheetHeight() -> CGFloat {
        loadViewIfNeeded()
        let width = sheetWidth
        let content = stack.systemLayoutSizeFitting(
            CGSize(width: max(0, width - 2 * Self.inset), height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        var toolbar: CGFloat = 0
        if actionTitle != nil {
            let estimate = navigationController?.toolbar.sizeThatFits(CGSize(width: width, height: 0)).height ?? 0
            toolbar = max(estimate, BarItems.bubbleHeight + Spacing.sm)
        }
        return ceil(Self.inset + content + Spacing.xl + toolbar)
    }

    /// The width the sheet is drawn at: its own once laid out, else its
    /// presenter's (a phone's sheet spans the screen).
    private var sheetWidth: CGFloat {
        let own = navigationController?.view.bounds.width ?? view.bounds.width
        if own > 0 { return own }
        return presentingViewController?.view.bounds.width ?? 390
    }

    /// What is presented, and so what is dismissed.
    private var presented: UIViewController { navigationController ?? self }

    private func close() {
        guard presented.presentingViewController != nil else { return gone() }
        closePresentation()
    }

    private func act() {
        let action = onAction
        onAction = nil
        // Never presented (a test host's modal that never completes): gone
        // at once.
        guard presented.presentingViewController != nil else {
            gone()
            action?()
            return
        }
        closePresentation { action?() }
    }

    private func gone() {
        guard !hasGone else { return }
        hasGone = true
        onGone?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard presented.isBeingDismissed || presented.presentingViewController == nil else { return }
        gone()
    }

    #if DEBUG
    /// The action's button, tapped. Tests.
    func debugAct() { act() }
    /// The ✕, tapped. Tests.
    func debugClose() { close() }
    /// Gone without acting. Tests: the test host's modals never complete.
    func debugGone() { gone() }
    #endif
}
