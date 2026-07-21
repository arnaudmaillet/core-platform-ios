import DesignSystem
import MediaCore
import UIKit

/// The Edit Profile screen: a native inset-grouped list (Settings / Instagram
/// idiom). A hero section shows the avatar with a "Change photo" control; each
/// editable field is an action row — `[Label]  [Value] ›` — that pushes a
/// dedicated single-field editor. Nothing is edited inline here; the list only
/// displays current values and routes to the child editors.
///
/// Pushed from the profile's "Edit Profile" button. Edits persist per field
/// (each child's Save), optimistically reflected on the list; a failed save
/// re-syncs from the server.
final class EditProfileViewController: UIViewController {
    private let viewModel: EditProfileViewModel
    private let imagePipeline: ImagePipeline

    /// The working snapshot the list renders; child editors commit into it.
    private var fields: EditProfileViewModel.Fields?
    private var avatarURL: URL?
    private var avatarImage: UIImage?

    private enum Section: Int, CaseIterable {
        case hero, identity, links
    }

    /// The editable fields, one row each. `Item` wraps this plus the hero so the
    /// diffable data source has stable identities to reconfigure in place.
    private enum Field: Hashable {
        case name, username, bio, website, links

        var title: String {
            switch self {
            case .name: "Name"
            case .username: "Username"
            case .bio: "Bio"
            case .website: "Website"
            case .links: "Links"
            }
        }

        #if DEBUG
        init?(debugName: String) {
            switch debugName {
            case "name": self = .name
            case "username": self = .username
            case "bio": self = .bio
            case "website": self = .website
            case "links": self = .links
            default: return nil
            }
        }
        #endif
    }

    private enum Item: Hashable {
        case hero
        case field(Field)
        // Shimmer placeholders shown while the profile loads. They ride the same
        // sections + list layout as the real items, so the skeleton mirrors the
        // grouped geometry exactly; `rowSkeleton`'s index only varies the value
        // bone width so the rows don't read as identical.
        case heroSkeleton
        case rowSkeleton(Int)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var isShowingSkeleton = false

    init(viewModel: EditProfileViewModel, imagePipeline: ImagePipeline) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Edit Profile"
        configureCollectionView()
        configureDataSource()

        // Show the skeleton up front so the first frame is the shimmer, not an
        // empty screen — the real data cross-dissolves over it when it lands.
        applySkeletonSnapshot()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onSaveStateChange = { [weak self] state in self?.render(save: state) }
        viewModel.onAvatarURLChange = { [weak self] url in self?.loadAvatar(url) }
        viewModel.viewDidLoad()
    }

    // MARK: - Setup

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        let layout = UICollectionViewCompositionalLayout.list(using: config)

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let heroRegistration = UICollectionView.CellRegistration<EditProfileHeroCell, Item> { [weak self] cell, _, _ in
            cell.setAvatar(self?.avatarImage)
            cell.onChangePhoto = { [weak self] in self?.changePhotoTapped() }
        }

        let fieldRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Field> { [weak self] cell, _, field in
            var content = UIListContentConfiguration.valueCell()
            content.text = field.title
            content.secondaryText = self?.displayValue(for: field)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let heroSkeletonRegistration = UICollectionView.CellRegistration<EditProfileHeroSkeletonCell, Item> { _, _, _ in }

        let rowSkeletonRegistration = UICollectionView.CellRegistration<EditProfileSkeletonRowCell, Int> { cell, _, index in
            cell.configure(index: index)
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .hero:
                return collectionView.dequeueConfiguredReusableCell(using: heroRegistration, for: indexPath, item: item)
            case .field(let field):
                return collectionView.dequeueConfiguredReusableCell(using: fieldRegistration, for: indexPath, item: field)
            case .heroSkeleton:
                return collectionView.dequeueConfiguredReusableCell(using: heroSkeletonRegistration, for: indexPath, item: item)
            case .rowSkeleton(let index):
                return collectionView.dequeueConfiguredReusableCell(using: rowSkeletonRegistration, for: indexPath, item: index)
            }
        }
    }

    // MARK: - Render

    private func render(_ phase: EditProfileViewModel.Phase) {
        switch phase {
        case .loading:
            break
        case .ready(let fields):
            self.fields = fields
            applyRealSnapshot()
            #if DEBUG
            handleDebugArgs()
            #endif
        case .failed(let message):
            presentError(message)
        }
    }

    private func render(save state: EditProfileViewModel.SaveState) {
        switch state {
        case .idle, .saving:
            break
        case .failed(let message):
            // Re-sync from the server so the list can't drift from the truth
            // after a rejected optimistic edit.
            presentError(message)
            viewModel.reload()
        }
    }

    /// The shimmer placeholder — one hero bone, four identity rows, one links
    /// row — laid out in the same sections and list layout as the real content.
    private func applySkeletonSnapshot() {
        isShowingSkeleton = true
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.hero, .identity, .links])
        snapshot.appendItems([.heroSkeleton], toSection: .hero)
        snapshot.appendItems([.rowSkeleton(0), .rowSkeleton(1), .rowSkeleton(2), .rowSkeleton(3)], toSection: .identity)
        snapshot.appendItems([.rowSkeleton(4)], toSection: .links)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func applyRealSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.hero, .identity, .links])
        snapshot.appendItems([.hero], toSection: .hero)
        snapshot.appendItems([.field(.name), .field(.username), .field(.bio), .field(.website)], toSection: .identity)
        snapshot.appendItems([.field(.links)], toSection: .links)

        guard isShowingSkeleton else {
            dataSource.apply(snapshot, animatingDifferences: false)
            return
        }
        // First real data: cross-dissolve the whole list so the shimmer fades
        // out as the content fades in, rather than snapping.
        isShowingSkeleton = false
        UIView.transition(with: collectionView, duration: 0.3, options: .transitionCrossDissolve) {
            self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    /// Reflects a single field's new value without rebuilding the list.
    private func reconfigure(_ field: Field) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([.field(field)])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func loadAvatar(_ url: URL?) {
        avatarURL = url
        guard let url else { return }
        let pipeline = imagePipeline
        Task { [weak self] in
            let image = try? await pipeline.image(for: url)
            guard let self, self.avatarURL == url, let image else { return }
            self.avatarImage = image
            // If the real hero isn't on screen yet (still skeleton), just stash
            // the image — the real snapshot will pick it up when it applies.
            var snapshot = self.dataSource.snapshot()
            guard snapshot.itemIdentifiers.contains(.hero) else { return }
            snapshot.reconfigureItems([.hero])
            await self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }

    // MARK: - Row values

    private func displayValue(for field: Field) -> String? {
        guard let fields else { return nil }
        switch field {
        case .name:
            return fields.displayName.isEmpty ? "Add name" : fields.displayName
        case .username:
            return "@" + fields.username
        case .bio:
            return fields.bio.isEmpty ? "Add bio" : fields.bio
        case .website:
            return fields.website.isEmpty ? "Add website" : fields.website
        case .links:
            switch fields.links.count {
            case 0: return "Add links"
            case 1: return fields.links[0].label.isEmpty ? "1 link" : fields.links[0].label
            case let n: return "\(n) links"
            }
        }
    }

    // MARK: - Navigation to child editors

    private func edit(_ field: Field) {
        guard fields != nil else { return }
        switch field {
        case .name: pushNameEditor()
        case .username: pushUsernameEditor()
        case .bio: pushBioEditor()
        case .website: pushWebsiteEditor()
        case .links: pushLinksEditor()
        }
    }

    private func pushNameEditor() {
        guard let fields else { return }
        push(EditFieldViewController(config: .init(
            title: "Name",
            initialValue: fields.displayName,
            placeholder: "Name",
            characterLimit: 30,
            autocapitalization: .words,
            helperText: "Your name as it appears on your profile.",
            onSave: { [weak self] value in
                self?.commitMetadata { $0.displayName = value }
                self?.reconfigure(.name)
            }
        )))
    }

    private func pushUsernameEditor() {
        guard let fields else { return }
        push(EditFieldViewController(config: .init(
            title: "Username",
            initialValue: fields.username,
            placeholder: "username",
            characterLimit: 30,
            autocapitalization: .none,
            autocorrection: .no,
            prefix: "@",
            helperText: "Usernames can use letters, numbers, underscores and periods.",
            validate: Self.validateUsername,
            onSave: { [weak self] value in
                self?.fields?.username = value
                self?.reconfigure(.username)
                // The @handle travels its own RPC, not the metadata update.
                self?.viewModel.saveUsername(value)
            }
        )))
    }

    private func pushBioEditor() {
        guard let fields else { return }
        push(EditFieldViewController(config: .init(
            title: "Bio",
            initialValue: fields.bio,
            placeholder: "Bio",
            multiline: true,
            characterLimit: 150,
            autocapitalization: .sentences,
            helperText: "Tell people a little about yourself.",
            onSave: { [weak self] value in
                self?.commitMetadata { $0.bio = value }
                self?.reconfigure(.bio)
            }
        )))
    }

    private func pushWebsiteEditor() {
        guard let fields else { return }
        push(EditFieldViewController(config: .init(
            title: "Website",
            initialValue: fields.website,
            placeholder: "https://",
            characterLimit: 100,
            keyboardType: .URL,
            autocapitalization: .none,
            autocorrection: .no,
            onSave: { [weak self] value in
                self?.commitMetadata { $0.website = value }
                self?.reconfigure(.website)
            }
        )))
    }

    private func pushLinksEditor() {
        guard let fields else { return }
        push(EditLinksViewController(links: fields.links, onSave: { [weak self] links in
            self?.commitMetadata { $0.links = links }
            self?.reconfigure(.links)
        }))
    }

    /// Applies a change to the working fields and persists the metadata set
    /// (name/bio/website/links) via `UpdateProfile`. The optimistic list update
    /// is done by the caller's `reconfigure`; a failed save re-syncs.
    private func commitMetadata(_ change: (inout EditProfileViewModel.Fields) -> Void) {
        guard var updated = fields else { return }
        change(&updated)
        fields = updated
        viewModel.saveMetadata(updated)
    }

    private func push(_ viewController: UIViewController) {
        navigationController?.pushViewController(viewController, animated: true)
    }

    // MARK: - Change photo

    private func changePhotoTapped() {
        // Honest gap: `UpdateAvatar` takes a URL and the contract exposes no
        // client-side image-upload path, so there's nothing to persist yet.
        let alert = UIAlertController(
            title: "Change Photo",
            message: "Photo uploads aren't available yet.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    #if DEBUG
    private var didHandleDebugArgs = false
    /// Dev convenience (no tap injection in the sim): `-edit-profile-field
    /// <name|username|bio|website|links>` auto-pushes that child editor so the
    /// focused screens are screenshottable without tapping a row.
    private func handleDebugArgs() {
        guard !didHandleDebugArgs, fields != nil else { return }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-edit-profile-field"), index + 1 < arguments.count,
           let field = Field(debugName: arguments[index + 1]) {
            didHandleDebugArgs = true
            DispatchQueue.main.async { [weak self] in self?.edit(field) }
        }
    }
    #endif

    // MARK: - Validation

    private static func validateUsername(_ value: String) -> String? {
        if value.isEmpty { return "Username can't be empty." }
        if value.count < 2 { return "Use at least 2 characters." }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.")
        if value.rangeOfCharacter(from: allowed.inverted) != nil {
            return "Only lowercase letters, numbers, _ and . are allowed."
        }
        return nil
    }
}

// MARK: - Selection

extension EditProfileViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard case .field(let field) = dataSource.itemIdentifier(for: indexPath) else { return }
        edit(field)
    }
}

// MARK: - Hero cell

/// The avatar hero at the top of the editor: a large circular avatar over a
/// "Change photo" button, on a clear background so it doesn't read as a grouped
/// row.
private final class EditProfileHeroCell: UICollectionViewListCell {
    private let avatarView = AvatarImageView()
    private let changeButton = UIButton(configuration: .plain())
    var onChangePhoto: (() -> Void)?

    private static let avatarDiameter: CGFloat = 96

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()

        avatarView.tintColor = .tertiaryLabel
        avatarView.backgroundColor = .secondarySystemFill
        avatarView.image = Self.placeholder

        changeButton.configuration?.title = "Change photo"
        changeButton.configuration?.baseForegroundColor = .tintColor
        changeButton.addAction(UIAction { [weak self] _ in self?.onChangePhoto?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [avatarView, changeButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: Self.avatarDiameter),
            avatarView.heightAnchor.constraint(equalToConstant: Self.avatarDiameter),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.md),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.sm),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setAvatar(_ image: UIImage?) {
        avatarView.image = image ?? Self.placeholder
    }

    private static let placeholder = UIImage(
        systemName: "person.crop.circle.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: avatarDiameter)
    )
}

// MARK: - Skeleton cells

/// Shimmer stand-in for the hero: a round avatar bone over a short caption bone,
/// on a clear background — matching `EditProfileHeroCell`'s footprint.
private final class EditProfileHeroSkeletonCell: UICollectionViewListCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()

        let avatarBone = SkeletonBoneView(rounding: .capsule)
        let captionBone = SkeletonBoneView(rounding: .capsule)
        let stack = UIStackView(arrangedSubviews: [avatarBone, captionBone])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            avatarBone.widthAnchor.constraint(equalToConstant: 96),
            avatarBone.heightAnchor.constraint(equalToConstant: 96),
            captionBone.widthAnchor.constraint(equalToConstant: 120),
            captionBone.heightAnchor.constraint(equalToConstant: 14),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.md),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.sm),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// Shimmer stand-in for a grouped field row: a short label bone pinned leading,
/// a wider value bone pinned trailing. Keeps the default grouped background so
/// the inset card and separators read exactly like the real rows.
private final class EditProfileSkeletonRowCell: UICollectionViewListCell {
    private let labelBone = SkeletonBoneView(rounding: .capsule)
    private let valueBone = SkeletonBoneView(rounding: .capsule)
    private lazy var valueWidth = valueBone.widthAnchor.constraint(equalToConstant: 120)

    /// Value-bone widths per row, so the placeholder rows don't look stamped.
    private static let valueWidths: [CGFloat] = [140, 90, 180, 150, 110]

    override init(frame: CGRect) {
        super.init(frame: frame)
        labelBone.translatesAutoresizingMaskIntoConstraints = false
        valueBone.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(labelBone)
        contentView.addSubview(valueBone)

        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            labelBone.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            labelBone.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            labelBone.widthAnchor.constraint(equalToConstant: 64),
            labelBone.heightAnchor.constraint(equalToConstant: 12),

            valueBone.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            valueBone.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            valueWidth,
            valueBone.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(index: Int) {
        valueWidth.constant = Self.valueWidths[index % Self.valueWidths.count]
    }
}
