import DesignSystem
import UIKit

final class LoginViewController: UIViewController {
    private let viewModel: LoginViewModel

    private let titleLabel = UILabel()
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let errorLabel = UILabel()
    private let submitButton = UIButton(configuration: .prominentGlass())
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(viewModel: LoginViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureSubviews()
        layoutSubviewsHierarchy()

        viewModel.onStateChange = { [weak self] state in
            self?.render(state)
        }
        render(.idle)
    }

    private func configureSubviews() {
        titleLabel.text = "Welcome back"
        titleLabel.font = .preferredFont(forTextStyle: .largeTitle)
        titleLabel.adjustsFontForContentSizeCategory = true

        for field in [usernameField, passwordField] {
            field.borderStyle = .roundedRect
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
        }
        usernameField.placeholder = "Username"
        usernameField.textContentType = .username
        usernameField.returnKeyType = .next
        passwordField.placeholder = "Password"
        passwordField.textContentType = .password
        passwordField.isSecureTextEntry = true
        passwordField.returnKeyType = .go

        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0

        submitButton.configuration?.title = "Sign In"
        submitButton.addAction(UIAction { [weak self] _ in self?.submit() }, for: .primaryActionTriggered)
        usernameField.addAction(UIAction { [weak self] _ in self?.passwordField.becomeFirstResponder() }, for: .editingDidEndOnExit)
        passwordField.addAction(UIAction { [weak self] _ in self?.submit() }, for: .editingDidEndOnExit)

        spinner.hidesWhenStopped = true
    }

    private func layoutSubviewsHierarchy() {
        let stack = UIStackView(arrangedSubviews: [
            titleLabel, usernameField, passwordField, errorLabel, submitButton
        ])
        stack.axis = .vertical
        stack.spacing = Spacing.lg
        stack.setCustomSpacing(Spacing.xxl, after: titleLabel)

        stack.constrain(in: view) { parent in
            stack.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            stack.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
            stack.centerYAnchor.constraint(equalTo: parent.centerYAnchor, constant: -Spacing.xxl)
        }
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: Spacing.xl)
        }
    }

    private func submit() {
        view.endEditing(true)
        viewModel.submit(username: usernameField.text ?? "", password: passwordField.text ?? "")
    }

    private func render(_ state: LoginViewModel.State) {
        switch state {
        case .idle:
            errorLabel.text = nil
            setSubmitting(false)
        case .submitting:
            errorLabel.text = nil
            setSubmitting(true)
        case .failed(let message):
            errorLabel.text = message
            setSubmitting(false)
        }
    }

    private func setSubmitting(_ submitting: Bool) {
        submitButton.isEnabled = !submitting
        usernameField.isEnabled = !submitting
        passwordField.isEnabled = !submitting
        if submitting {
            spinner.startAnimating()
        } else {
            spinner.stopAnimating()
        }
    }
}
