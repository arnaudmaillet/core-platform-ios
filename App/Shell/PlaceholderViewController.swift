import DesignSystem
import UIKit

/// A simple centered placeholder for tabs whose real feature hasn't been built
/// yet: an SF Symbol, a title, a subtitle, and an optional action button.
final class PlaceholderViewController: UIViewController {
    private let symbolName: String
    private let displayTitle: String
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        message: String = "Coming soon",
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        symbolName = systemImage
        displayTitle = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let icon = UIImageView(image: UIImage(systemName: symbolName))
        icon.tintColor = .tertiaryLabel
        icon.contentMode = .scaleAspectFit
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .regular)

        let titleLabel = UILabel()
        titleLabel.text = displayTitle
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center

        let messageLabel = UILabel()
        messageLabel.text = message
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, messageLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.sm
        stack.setCustomSpacing(Spacing.lg, after: icon)

        if let actionTitle {
            let button = UIButton(configuration: .glass())
            button.configuration?.title = actionTitle
            button.addAction(UIAction { [weak self] _ in self?.action?() }, for: .primaryActionTriggered)
            stack.addArrangedSubview(button)
            stack.setCustomSpacing(Spacing.xl, after: messageLabel)
        }

        stack.constrain(in: view) { parent in
            stack.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            stack.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: parent.layoutMarginsGuide.leadingAnchor)
            stack.trailingAnchor.constraint(lessThanOrEqualTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }
}
