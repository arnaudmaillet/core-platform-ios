import DesignSystem
import UIKit

final class ConversationViewController: UIViewController {
    private let viewModel: ConversationViewModel

    private let scrollView = UIScrollView()
    private let messagesStack = UIStackView()
    private let refreshControl = UIRefreshControl()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let statusLabel = UILabel()

    private let composeBar = UIView()
    private let composeField = UITextField()
    private let sendButton = UIButton(configuration: .plain())
    private let composeSpinner = UIActivityIndicatorView(style: .medium)

    init(viewModel: ConversationViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Conversation"
        view.backgroundColor = .systemBackground
        configureViews()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onSendingChange = { [weak self] sending in self?.renderSending(sending) }
        render(.loading)
        viewModel.viewDidLoad()
    }

    // MARK: - Setup

    private func configureViews() {
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        refreshControl.addAction(UIAction { [weak self] _ in self?.viewModel.refresh() }, for: .valueChanged)
        scrollView.refreshControl = refreshControl

        configureComposeBar()
        scrollView.constrain(in: view) { parent in
            scrollView.topAnchor.constraint(equalTo: parent.topAnchor)
            scrollView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            scrollView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            scrollView.bottomAnchor.constraint(equalTo: composeBar.topAnchor)
        }

        messagesStack.axis = .vertical
        messagesStack.spacing = Spacing.sm
        let content = scrollView.contentLayoutGuide
        let frame = scrollView.frameLayoutGuide
        messagesStack.constrain(in: scrollView) { _ in
            messagesStack.topAnchor.constraint(equalTo: content.topAnchor, constant: Spacing.md)
            messagesStack.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: Spacing.lg)
            messagesStack.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -Spacing.lg)
            messagesStack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Spacing.md)
        }

        spinner.hidesWhenStopped = true
        spinner.constrain(in: view) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        statusLabel.font = .preferredFont(forTextStyle: .body)
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

    private func configureComposeBar() {
        composeBar.backgroundColor = .systemBackground
        composeField.placeholder = "Message…"
        composeField.borderStyle = .roundedRect
        composeField.returnKeyType = .send
        composeField.delegate = self
        composeField.font = .preferredFont(forTextStyle: .body)
        composeField.adjustsFontForContentSizeCategory = true

        var sendConfig = UIButton.Configuration.plain()
        sendConfig.image = UIImage(systemName: "arrow.up.circle.fill")
        sendConfig.contentInsets = .zero
        sendButton.configuration = sendConfig
        sendButton.addAction(UIAction { [weak self] _ in self?.sendMessage() }, for: .primaryActionTriggered)
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        composeSpinner.hidesWhenStopped = true

        let row = UIStackView(arrangedSubviews: [composeField, sendButton, composeSpinner])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.sm
        row.pin(to: composeBar, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg
        ))

        let separator = UIView()
        separator.backgroundColor = .separator
        view.addSubview(composeBar)
        composeBar.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false
        composeBar.addSubview(separator)
        NSLayoutConstraint.activate([
            composeBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composeBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composeBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            separator.topAnchor.constraint(equalTo: composeBar.topAnchor),
            separator.leadingAnchor.constraint(equalTo: composeBar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: composeBar.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5)
        ])
    }

    private func sendMessage() {
        let text = composeField.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        composeField.text = ""
        viewModel.send(text)
    }

    // MARK: - Render

    private func render(_ phase: ConversationViewModel.Phase) {
        switch phase {
        case .loading:
            if !refreshControl.isRefreshing { spinner.startAnimating() }
            scrollView.isHidden = true
            statusLabel.isHidden = true
        case .content(let models):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            statusLabel.isHidden = true
            scrollView.isHidden = false
            messagesStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for model in models {
                messagesStack.addArrangedSubview(MessageBubbleView(model: model))
            }
            scrollToBottom()
        case .failed(let message):
            spinner.stopAnimating()
            refreshControl.endRefreshing()
            scrollView.isHidden = true
            statusLabel.text = message
            statusLabel.isHidden = false
        }
    }

    private func renderSending(_ sending: Bool) {
        composeField.isEnabled = !sending
        sendButton.isHidden = sending
        if sending { composeSpinner.startAnimating() } else { composeSpinner.stopAnimating() }
    }

    private func scrollToBottom() {
        view.layoutIfNeeded()
        let bottom = scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
        if bottom > 0 {
            scrollView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
    }
}

extension ConversationViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendMessage()
        return false
    }
}
