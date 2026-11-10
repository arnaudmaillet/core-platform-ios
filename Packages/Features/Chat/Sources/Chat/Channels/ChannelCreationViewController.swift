import CoreModels
import DesignSystem
import UIKit

/// The new channel's sheet (#2215): what a channel is, in two lines
/// (#2230), where its photo will go (its initials, no picker yet —
/// `ChannelCreationViewModel`), its name, its description, who may join —
/// Public or On request, each said in a line — and "Create".
///
/// Opened from the "+" menu and the inbox search (#2230): with the
/// Channels tab gone, nothing around it says what a channel is any more,
/// so its header does — the words the empty tab said.
final class ChannelCreationViewController: UIViewController {
    private let viewModel: ChannelCreationViewModel

    /// Cancel: the host dismisses the sheet.
    var onCancel: (() -> Void)?

    private let scrollView = UIScrollView()
    /// What a channel is (#2230), over everything else.
    private let introLabel = UILabel()
    private let disc = MonogramAvatarView(diameter: GroupNameViewController.discDiameter)
    private let nameField = UITextField()
    private let descriptionField = UITextField()
    private let visibilityControl = UISegmentedControl()
    private let visibilityNote = UILabel()
    private let errorLabel = UILabel()
    private let createButton = AppButton(aspect: .pill(.prominent), size: .form, content: .title("Create"))

    init(viewModel: ChannelCreationViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "New Channel"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.onCancel?() }
        )
        introLabel.text = ChannelCopy.whatItIs
        introLabel.font = .appFont(forTextStyle: .subheadline)
        introLabel.textColor = .secondaryLabel
        introLabel.numberOfLines = 0
        introLabel.textAlignment = .center
        introLabel.adjustsFontForContentSizeCategory = true
        disc.setMonogram(MonogramAvatarView.monogram(name: "Channel", handle: ""))
        disc.accessibilityLabel = "Channel photo"

        configure(nameField, placeholder: "Channel name", font: .title3, label: "Channel name")
        nameField.textAlignment = .center
        nameField.addAction(UIAction { [weak self] _ in self?.nameChanged() }, for: .editingChanged)
        nameField.addAction(UIAction { [weak self] _ in self?.descriptionField.becomeFirstResponder() }, for: .editingDidEndOnExit)
        nameField.returnKeyType = .next

        configure(descriptionField, placeholder: "Description (optional)", font: .body, label: "Description")
        descriptionField.textAlignment = .center
        descriptionField.returnKeyType = .done
        descriptionField.addAction(UIAction { [weak self] _ in
            self?.viewModel.descriptionChanged(self?.descriptionField.text ?? "")
        }, for: .editingChanged)
        descriptionField.addAction(UIAction { [weak self] _ in self?.descriptionField.resignFirstResponder() }, for: .editingDidEndOnExit)

        for (index, choice) in ChannelCopy.choosableVisibilities.enumerated() {
            visibilityControl.insertSegment(withTitle: ChannelCopy.visibilityTitle(choice), at: index, animated: false)
        }
        visibilityControl.selectedSegmentIndex = ChannelCopy.choosableVisibilities.firstIndex(of: viewModel.visibility) ?? 0
        visibilityControl.accessibilityLabel = "Who can join"
        visibilityControl.addAction(UIAction { [weak self] _ in self?.visibilityChanged() }, for: .valueChanged)
        visibilityNote.font = .appFont(forTextStyle: .footnote)
        visibilityNote.textColor = .secondaryLabel
        visibilityNote.numberOfLines = 0
        visibilityNote.textAlignment = .center
        visibilityNote.adjustsFontForContentSizeCategory = true

        errorLabel.font = .appFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true

        createButton.addAction(UIAction { [weak self] _ in self?.create() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [
            introLabel, disc, nameField, descriptionField, visibilityControl, visibilityNote, errorLabel, createButton,
        ])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.lg
        stack.setCustomSpacing(Spacing.sm, after: visibilityControl)
        stack.setCustomSpacing(Spacing.xl, after: visibilityNote)
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.pin(to: view)
        let scroll = scrollView
        stack.constrain(in: scrollView) { _ in
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Spacing.xl)
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Spacing.xl)
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Spacing.lg)
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Spacing.lg)
            introLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor)
            descriptionField.widthAnchor.constraint(equalTo: stack.widthAnchor)
            visibilityControl.widthAnchor.constraint(equalTo: stack.widthAnchor)
            visibilityNote.widthAnchor.constraint(equalTo: stack.widthAnchor)
            createButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
        }

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onCanCreateChange = { [weak self] can in self?.createButton.isEnabled = can }
        createButton.isEnabled = viewModel.canCreate
        renderVisibility()
        render(viewModel.phase)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        nameField.becomeFirstResponder()
    }

    private func configure(_ field: UITextField, placeholder: String, font: UIFont.TextStyle, label: String) {
        field.placeholder = placeholder
        field.font = .appFont(forTextStyle: font)
        field.adjustsFontForContentSizeCategory = true
        field.clearButtonMode = .whileEditing
        field.autocapitalizationType = .sentences
        field.accessibilityLabel = label
    }

    private func nameChanged() {
        let text = nameField.text ?? ""
        viewModel.nameChanged(text)
        let shown = text.trimmingCharacters(in: .whitespaces).isEmpty ? "Channel" : text
        disc.setMonogram(MonogramAvatarView.monogram(name: shown, handle: ""))
    }

    private func visibilityChanged() {
        let index = visibilityControl.selectedSegmentIndex
        guard ChannelCopy.choosableVisibilities.indices.contains(index) else { return }
        viewModel.visibilityChanged(ChannelCopy.choosableVisibilities[index])
        renderVisibility()
    }

    private func renderVisibility() {
        visibilityNote.text = ChannelCopy.visibilityExplanation(viewModel.visibility)
    }

    private func create() {
        view.endEditing(true)
        viewModel.create()
    }

    private func render(_ phase: ChannelCreationViewModel.Phase) {
        createButton.setPhase(phase == .creating ? .loading : .content, animated: view.window != nil)
        nameField.isEnabled = phase != .creating
        descriptionField.isEnabled = phase != .creating
        visibilityControl.isEnabled = phase != .creating
        if case .failed(let message) = phase {
            errorLabel.text = message
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }
    }
}

// MARK: - How it is left (#1144)

extension ChannelCreationViewController: StackScreen {
    /// A sheet's root: its Cancel, or the sheet's swipe down.
    var leaving: ScreenLeaving { .controlsOnly }
}
