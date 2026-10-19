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
/// It reads: the toast's glyph in its style's ink, the whole message
/// (multi-line, Dynamic Type), then the toast's action when it has one
/// (Undo, Retry) beside Close. One custom detent, as tall as that content.
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
    private(set) var messageLabel = UILabel()
    private(set) var actionButton: AppButton?
    private(set) var closeButton: AppButton!
    private var hasGone = false

    init(message: String, glyph: UIImage?, glyphTint: UIColor, actionTitle: String?) {
        self.message = message
        self.glyph = glyph
        self.glyphTint = glyphTint
        self.actionTitle = actionTitle
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // No background of its own: the sheet's material is the system's.
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = Spacing.lg
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: Spacing.xl + Spacing.sm),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.lg),
        ])

        if let glyph {
            let glyphView = UIImageView(image: glyph)
            glyphView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title2, scale: .large)
            glyphView.tintColor = glyphTint
            glyphView.contentMode = .left
            glyphView.isAccessibilityElement = false
            stack.addArrangedSubview(glyphView)
        }

        messageLabel.text = message
        messageLabel.font = .appFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .label
        messageLabel.numberOfLines = 0
        stack.addArrangedSubview(messageLabel)

        let buttons = UIStackView()
        buttons.axis = .horizontal
        buttons.spacing = Spacing.md
        buttons.distribution = .fillEqually
        let close = AppButton(aspect: .pill(.quiet), size: .header, content: .title("Close"))
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        closeButton = close
        buttons.addArrangedSubview(close)
        if let actionTitle {
            let action = AppButton(aspect: .pill(.prominent), size: .header, content: .title(actionTitle))
            action.addAction(UIAction { [weak self] _ in self?.act() }, for: .primaryActionTriggered)
            actionButton = action
            buttons.addArrangedSubview(action)
        }
        stack.setCustomSpacing(Spacing.xl, after: messageLabel)
        stack.addArrangedSubview(buttons)

        if let sheet = sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.detents = [.custom(identifier: Self.detent) { [weak self] context in
                guard let self else { return nil }
                return min(fittedHeight(width: sheetWidth), context.maximumDetentValue)
            }]
        }
    }

    static let detent = UISheetPresentationController.Detent.Identifier("toast.fullMessage")

    /// The width the sheet is drawn at: its own once laid out, else its
    /// presenter's (a phone's sheet spans the screen).
    private var sheetWidth: CGFloat {
        if view.bounds.width > 0 { return view.bounds.width }
        return presentingViewController?.view.bounds.width ?? 390
    }

    /// The sheet's height for `width`: its content, measured once laid out
    /// at that width (the detent reads it; it never lays the sheet out).
    func fittedHeight(width: CGFloat) -> CGFloat {
        let margins = view.layoutMargins.left + view.layoutMargins.right
        let content = stack.systemLayoutSizeFitting(
            CGSize(width: max(0, width - margins), height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height
        return ceil(content + Spacing.xl + Spacing.sm + Spacing.lg)
    }

    private func act() {
        let action = onAction
        onAction = nil
        // Never presented (a test host's modal that never completes): gone
        // at once.
        guard presentingViewController != nil else {
            gone()
            action?()
            return
        }
        dismiss(animated: true) { action?() }
    }

    private func gone() {
        guard !hasGone else { return }
        hasGone = true
        onGone?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        gone()
    }

    #if DEBUG
    /// The action's button, tapped. Tests.
    func debugAct() { act() }
    /// Gone without acting. Tests: the test host's modals never complete.
    func debugGone() { gone() }
    #endif
}
