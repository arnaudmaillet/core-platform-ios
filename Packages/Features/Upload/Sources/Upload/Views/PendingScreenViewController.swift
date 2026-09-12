import DesignSystem
import UIKit

/// A titled screen that says what is coming: the stand-in for a step that has an
/// entry point before it has a design. See `UploadFeatureBuilder`.
///
/// `showsClose` is false when it is PUSHED. A close button on a pushed screen
/// dismisses the whole flow from under the back button standing beside it, which
/// is not what a viewer one step into a post is asking for.
final class PendingScreenViewController: UIViewController {
    private let message: String?
    private let emptyState = EmptyStateView()

    init(title: String, message: String? = nil, showsClose: Bool = true) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
        self.title = title
        guard showsClose else { return }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        guard let message else { return }
        emptyState.configure(symbolName: "square.and.pencil", title: title ?? "", subtitle: message)
        emptyState.isUserInteractionEnabled = false
        emptyState.pin(to: view)
    }
}
