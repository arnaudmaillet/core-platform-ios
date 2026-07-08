import MediaCore
import DesignSystem
import UIKit

final class ProfileViewController: UIViewController {
    private let viewModel: ProfileViewModel
    /// Non-nil only for the signed-in viewer's own profile (the Profile tab);
    /// nil for a profile pushed via routing, which shows no account actions.
    private let onLogout: (() -> Void)?
    /// Builds the edit form (for the viewer's own profile); the closure it
    /// receives is invoked after a successful save. Nil for other users.
    private let makeEditViewController: ((@escaping () -> Void) -> UIViewController)?

    private let scrollView = UIScrollView()
    private let headerView: ProfileHeaderView
    private let refreshControl = UIRefreshControl()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()

    private var followButtonState: ProfileViewModel.FollowButton = .hidden

    init(
        viewModel: ProfileViewModel,
        imagePipeline: ImagePipeline,
        onLogout: (() -> Void)?,
        makeEditViewController: ((@escaping () -> Void) -> UIViewController)? = nil
    ) {
        self.viewModel = viewModel
        self.onLogout = onLogout
        self.makeEditViewController = makeEditViewController
        headerView = ProfileHeaderView(imagePipeline: imagePipeline)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Profile"
        view.backgroundColor = .systemBackground
        configureNavigationBar()
        configureViews()

        viewModel.onPhaseChange = { [weak self] phase in
            self?.render(phase)
        }
        viewModel.onFollowButtonChange = { [weak self] state in
            self?.followButtonState = state
            self?.headerView.configureAction(state)
        }
        headerView.onActionTapped = { [weak self] in
            self?.handleActionTapped()
        }
        headerView.onMessageTapped = { [weak self] in
            self?.viewModel.messageTapped()
        }
        render(.loading)
        viewModel.viewDidLoad()
    }

    #if DEBUG
    private var didAutoPresentEdit = false
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Dev convenience: `-edit-profile` opens the edit form on the viewer's
        // own profile, so the form is testable without tapping the button.
        if !didAutoPresentEdit, makeEditViewController != nil,
           ProcessInfo.processInfo.arguments.contains("-edit-profile") {
            didAutoPresentEdit = true
            presentEditProfile()
        }
    }
    #endif

    /// The header's action button means different things per state: Edit opens
    /// the edit form; Follow/Following toggle the relationship.
    private func handleActionTapped() {
        if followButtonState == .edit {
            presentEditProfile()
        } else {
            viewModel.toggleFollow()
        }
    }

    private func presentEditProfile() {
        guard let makeEditViewController else { return }
        let editViewController = makeEditViewController { [weak self] in
            self?.dismiss(animated: true)
            self?.viewModel.refresh()
        }
        present(UINavigationController(rootViewController: editViewController), animated: true)
    }

    // MARK: - Setup

    private func configureNavigationBar() {
        // Account actions only exist for the viewer's own profile.
        guard let onLogout else { return }
        // Log Out lives in an overflow menu — destructive, so it's one tap
        // removed from the surface, matching where it sat on the placeholder.
        let logout = UIAction(title: "Log Out", image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), attributes: .destructive) { _ in
            onLogout()
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [logout])
        )
    }

    private func configureViews() {
        scrollView.alwaysBounceVertical = true
        scrollView.pin(to: view)

        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        scrollView.refreshControl = refreshControl

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        headerView.constrain(in: scrollView) { _ in
            headerView.topAnchor.constraint(equalTo: content.topAnchor)
            headerView.leadingAnchor.constraint(equalTo: content.leadingAnchor)
            headerView.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            headerView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
            headerView.widthAnchor.constraint(equalTo: frame.widthAnchor)
        }

        spinner.hidesWhenStopped = true
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.isHidden = true
        statusLabel.constrain(in: view) { parent in
            statusLabel.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            statusLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }
    }

    // MARK: - Render

    private func render(_ phase: ProfileViewModel.Phase) {
        switch phase {
        case .loading:
            if !refreshControl.isRefreshing { spinner.startAnimating() }
            scrollView.isHidden = true
            statusLabel.isHidden = true

        case .content(let model):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            statusLabel.isHidden = true
            scrollView.isHidden = false
            // A routed profile titles itself with the person's name; the
            // viewer's own tab keeps the static "Profile" title.
            if onLogout == nil {
                title = model.displayName
            }
            headerView.configure(with: model)

        case .failed(let message):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            scrollView.isHidden = true
            statusLabel.text = message
            statusLabel.isHidden = false
        }
    }
}
