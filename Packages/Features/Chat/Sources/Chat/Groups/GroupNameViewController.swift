import CoreNavigation
import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The new group's name step (#2214): where its photo will go, its name
/// (optional — the members' names stand in, as the field's placeholder
/// shows), who is in it, and "Create".
///
/// The disc shows the group's initials once it has a name — no photo is
/// picked yet (`GroupCreationViewModel`).
final class GroupNameViewController: UIViewController {
    private let viewModel: GroupCreationViewModel

    private let disc = MonogramAvatarView(diameter: GroupNameViewController.discDiameter)
    private let nameField = UITextField()
    private let membersLabel = UILabel()
    private let errorLabel = UILabel()
    private let createButton = AppButton(aspect: .pill(.prominent), size: .form, content: .title("Create"))

    static let discDiameter: CGFloat = 96

    init(viewModel: GroupCreationViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Name the group"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let placeholder = viewModel.placeholderName
        disc.setMonogram(MonogramAvatarView.monogram(name: placeholder, handle: ""))

        nameField.placeholder = placeholder
        nameField.font = .appFont(forTextStyle: .title3)
        nameField.adjustsFontForContentSizeCategory = true
        nameField.textAlignment = .center
        nameField.returnKeyType = .done
        nameField.clearButtonMode = .whileEditing
        nameField.accessibilityLabel = "Group name"
        nameField.addAction(UIAction { [weak self] _ in self?.nameChanged() }, for: .editingChanged)
        nameField.addAction(UIAction { [weak self] _ in self?.nameField.resignFirstResponder() }, for: .editingDidEndOnExit)

        let count = viewModel.members.count + 1
        membersLabel.text = "\(count) people: you, " + viewModel.members.map(\.displayName).joined(separator: ", ")
        membersLabel.font = .appFont(forTextStyle: .footnote)
        membersLabel.textColor = .secondaryLabel
        membersLabel.numberOfLines = 3
        membersLabel.textAlignment = .center
        membersLabel.adjustsFontForContentSizeCategory = true

        errorLabel.font = .appFont(forTextStyle: .footnote)
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.isHidden = true

        createButton.addAction(UIAction { [weak self] _ in self?.create() }, for: .primaryActionTriggered)

        let stack = UIStackView(arrangedSubviews: [disc, nameField, membersLabel, errorLabel, createButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.lg
        stack.setCustomSpacing(Spacing.xl, after: membersLabel)
        stack.constrain(in: view) { parent in
            stack.topAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.topAnchor, constant: Spacing.xl)
            stack.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            stack.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor)
            createButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
        }

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        render(viewModel.phase)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        nameField.becomeFirstResponder()
    }

    private func nameChanged() {
        let text = nameField.text ?? ""
        viewModel.nameChanged(text)
        let shown = text.trimmingCharacters(in: .whitespaces).isEmpty ? viewModel.placeholderName : text
        disc.setMonogram(MonogramAvatarView.monogram(name: shown, handle: ""))
    }

    private func create() {
        nameField.resignFirstResponder()
        viewModel.create()
    }

    private func render(_ phase: GroupCreationViewModel.Phase) {
        createButton.setPhase(phase == .creating ? .loading : .content, animated: view.window != nil)
        nameField.isEnabled = phase != .creating
        if case .failed(let message) = phase {
            errorLabel.text = message
            errorLabel.isHidden = false
        } else {
            errorLabel.isHidden = true
        }
    }
}

extension GroupNameViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
