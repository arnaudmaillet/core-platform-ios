import DesignSystem
import UIKit

/// Modal form for editing the viewer's own profile: display name, bio, website.
/// Presented from the "Edit Profile" button; dismisses itself on cancel, and
/// (via the view model's `onSaved`) on a successful save.
final class EditProfileViewController: UIViewController {
    private let viewModel: EditProfileViewModel

    private let scrollView = UIScrollView()
    private let displayNameField = UITextField()
    private let bioTextView = UITextView()
    private let websiteField = UITextField()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private lazy var saveButton = UIBarButtonItem(
        systemItem: .save,
        primaryAction: UIAction { [weak self] _ in self?.save() }
    )

    init(viewModel: EditProfileViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Edit Profile"
        view.backgroundColor = .systemGroupedBackground
        configureNavigationBar()
        configureForm()
        setEditingEnabled(false)

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onSaveStateChange = { [weak self] state in self?.render(save: state) }
        viewModel.viewDidLoad()
    }

    // MARK: - Setup

    private func configureNavigationBar() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        navigationItem.rightBarButtonItem = saveButton
    }

    private func configureForm() {
        scrollView.pin(to: view, relativeTo: .safeArea)
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive

        displayNameField.borderStyle = .roundedRect
        displayNameField.placeholder = "Your name"
        displayNameField.font = .preferredFont(forTextStyle: .body)
        displayNameField.adjustsFontForContentSizeCategory = true

        bioTextView.font = .preferredFont(forTextStyle: .body)
        bioTextView.adjustsFontForContentSizeCategory = true
        bioTextView.layer.cornerRadius = 8
        bioTextView.backgroundColor = .secondarySystemGroupedBackground
        bioTextView.textContainerInset = UIEdgeInsets(
            top: Spacing.sm, left: Spacing.sm, bottom: Spacing.sm, right: Spacing.sm
        )

        websiteField.borderStyle = .roundedRect
        websiteField.placeholder = "https://"
        websiteField.font = .preferredFont(forTextStyle: .body)
        websiteField.adjustsFontForContentSizeCategory = true
        websiteField.keyboardType = .URL
        websiteField.autocapitalizationType = .none
        websiteField.autocorrectionType = .no

        let form = UIStackView(arrangedSubviews: [
            fieldGroup(caption: "Display Name", field: displayNameField),
            fieldGroup(caption: "Bio", field: bioTextView),
            fieldGroup(caption: "Website", field: websiteField)
        ])
        form.axis = .vertical
        form.spacing = Spacing.lg

        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        form.constrain(in: scrollView) { _ in
            form.topAnchor.constraint(equalTo: content.topAnchor, constant: Spacing.lg)
            form.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: Spacing.lg)
            form.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -Spacing.lg)
            form.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Spacing.lg)
        }
        bioTextView.heightAnchor.constraint(equalToConstant: 96).isActive = true

        spinner.hidesWhenStopped = true
    }

    /// A caption label stacked above its input control.
    private func fieldGroup(caption: String, field: UIView) -> UIView {
        let label = UILabel()
        label.text = caption
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel

        let stack = UIStackView(arrangedSubviews: [label, field])
        stack.axis = .vertical
        stack.spacing = Spacing.xs
        return stack
    }

    // MARK: - Render

    private func render(_ phase: EditProfileViewModel.Phase) {
        switch phase {
        case .loading:
            setEditingEnabled(false)
        case .ready(let fields):
            displayNameField.text = fields.displayName
            bioTextView.text = fields.bio
            websiteField.text = fields.website
            setEditingEnabled(true)
        case .failed(let message):
            setEditingEnabled(false)
            presentError(message)
        }
    }

    private func render(save state: EditProfileViewModel.SaveState) {
        switch state {
        case .idle:
            navigationItem.rightBarButtonItem = saveButton
            saveButton.isEnabled = true
        case .saving:
            spinner.startAnimating()
            navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        case .failed(let message):
            navigationItem.rightBarButtonItem = saveButton
            saveButton.isEnabled = true
            presentError(message)
        }
    }

    private func setEditingEnabled(_ enabled: Bool) {
        saveButton.isEnabled = enabled
        displayNameField.isEnabled = enabled
        bioTextView.isEditable = enabled
        websiteField.isEnabled = enabled
    }

    private func save() {
        view.endEditing(true)
        viewModel.save(EditProfileViewModel.Fields(
            displayName: displayNameField.text ?? "",
            bio: bioTextView.text ?? "",
            website: websiteField.text ?? ""
        ))
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
