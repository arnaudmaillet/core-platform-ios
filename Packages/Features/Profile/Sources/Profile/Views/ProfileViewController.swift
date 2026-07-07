import CoreMedia
import DesignSystem
import UIKit

final class ProfileViewController: UIViewController {
    private let viewModel: ProfileViewModel
    private let onLogout: () -> Void

    private let scrollView = UIScrollView()
    private let headerView: ProfileHeaderView
    private let refreshControl = UIRefreshControl()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()

    init(viewModel: ProfileViewModel, imagePipeline: ImagePipeline, onLogout: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onLogout = onLogout
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
        render(.loading)
        viewModel.viewDidLoad()
    }

    // MARK: - Setup

    private func configureNavigationBar() {
        // Log Out lives in an overflow menu — destructive, so it's one tap
        // removed from the surface, matching where it sat on the placeholder.
        let logout = UIAction(title: "Log Out", image: UIImage(systemName: "rectangle.portrait.and.arrow.right"), attributes: .destructive) { [weak self] _ in
            self?.onLogout()
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
