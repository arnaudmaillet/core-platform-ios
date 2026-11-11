import CoreNavigation
import CoreModels
import DesignSystem
import MediaCore
import UIKit

/// The new group's name step (#2214): where its photo will go, its name
/// (optional — the members' names stand in, as the field's placeholder
/// shows), who is in it, and "Create".
///
/// The disc is the group's picture (#2233): the faces of the members
/// picked, as its inbox row and its thread will show them — no photo is
/// picked yet (`GroupCreationViewModel`).
final class GroupNameViewController: UIViewController {
    private let viewModel: GroupCreationViewModel
    private let imagePipeline: ImagePipeline?
    /// Where the picked members' pictures are looked up; nil: their
    /// initials.
    private let profiles: (any ChatProfileLookup)?
    /// The pictures found, once the lookup answered.
    private var pictures: [ProfileID: URL]?

    private let disc = GroupAvatarView(diameter: GroupNameViewController.discDiameter, size: .px256)
    private let nameField = UITextField()
    private let membersLabel = UILabel()
    private let errorLabel = UILabel()
    private let createButton = AppButton(aspect: .pill(.prominent), size: .form, content: .title("Create"))

    static let discDiameter: CGFloat = 96

    init(viewModel: GroupCreationViewModel, imagePipeline: ImagePipeline? = nil, profiles: (any ChatProfileLookup)? = nil) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        self.profiles = profiles
        super.init(nibName: nil, bundle: nil)
        title = "Name the group"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let placeholder = viewModel.placeholderName
        drawDisc()
        loadPictures()

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
        viewModel.nameChanged(nameField.text ?? "")
        // The name is the picture's last resort: its initials, with no face.
        drawDisc()
    }

    /// The group's picture as it stands: the picked members' faces, their
    /// pictures' skeletons while the lookup is on its way.
    private func drawDisc() {
        let typed = viewModel.name.trimmingCharacters(in: .whitespaces)
        disc.setContent(
            Self.groupAvatar(
                members: viewModel.members, name: typed.isEmpty ? viewModel.placeholderName : typed,
                pictures: pictures, awaitsPictures: profiles != nil
            ),
            pipeline: imagePipeline
        )
    }

    private func loadPictures() {
        guard let profiles, pictures == nil else { return }
        let ids = viewModel.members.map(\.id)
        Task { [weak self] in
            let found = await profiles.profiles(ids)
            guard let self else { return }
            var urls: [ProfileID: URL] = [:]
            for (id, profile) in found { urls[id] = profile.avatarURL }
            self.pictures = urls
            self.drawDisc()
        }
    }

    /// The new group's picture (#2233): its members' faces in the order
    /// they were picked — the order they join in — the viewer counted in
    /// its size. `pictures` nil: the lookup is still on its way, and a face
    /// holds its skeleton when `awaitsPictures`, its initials otherwise.
    static func groupAvatar(
        members: [PersonDisplayModel], name: String, pictures: [ProfileID: URL]?, awaitsPictures: Bool
    ) -> GroupAvatarContent {
        let faces: [GroupAvatarFace] = members.prefix(ConversationIdentity.stackedFaces).map { member in
            GroupAvatarFace(
                name: member.displayName.isEmpty ? member.handle : member.displayName,
                avatarURL: pictures?[member.id],
                awaitsPicture: pictures == nil && awaitsPictures
            )
        }
        return GroupAvatarContent(name: name, faces: faces, memberCount: members.count + 1)
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
