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

    #if DEBUG
    func qaOpenPrivacy() { onOpenPrivacy?() }
    #endif

    /// Pushes the privacy screen. A hook rather than a push done here: this
    /// controller doesn't own the navigation stack it sits in, and the
    /// composition root is what knows how the privacy store is built.
    var onOpenPrivacy: (() -> Void)?
    /// Pushes Account Type (#415); nil hides the row.
    var onOpenAccountType: (() -> Void)?

    private enum Section: Int, CaseIterable {
        case hero, banner, identity, links, privacy
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
    }

    private enum Item: Hashable {
        case hero
        case field(Field)
        /// Pushes the privacy screen. Not a `field`: it edits nothing on the
        /// profile being saved here, it navigates.
        case privacy
        /// Pushes Account Type; navigates like `privacy`.
        case accountType
        /// The video banner (#944): the shop item until it is owned, then
        /// the picker of the viewer's own videos.
        case videoBanner
        // Shimmer placeholders shown while the profile loads. They ride the same
        // sections + list layout as the real items, so the skeleton mirrors the
        // grouped geometry exactly; `rowSkeleton`'s index only varies the value
        // bone width so the rows don't read as identical.
        case heroSkeleton
        case rowSkeleton(Int)
        /// The video banner's row, redacted while the profile loads (#1774).
        case bannerSkeleton
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var isShowingSkeleton = false

    init(viewModel: EditProfileViewModel, imagePipeline: ImagePipeline) {
        self.viewModel = viewModel
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        // Editing is a task, not a place: the tab bar offers four ways to
        // abandon it half-finished, and none of them belong on a form. Declared
        // HERE rather than at the push site so it holds wherever this screen is
        // pushed from — the same reason the chat thread and the relationship
        // lists state it in their own inits.
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Edit Profile"
        configureCollectionView()
        configureDataSource()

        // The first load on the kit's timing (#1770): nothing for its delay,
        // then the shimmer — the real data cross-dissolves over it when it
        // lands, after the bones' minimum.
        awaitingFirstLoad = true
        skeletonGate.begin()

        viewModel.onPhaseChange = { [weak self] phase in self?.render(phase) }
        viewModel.onSaveStateChange = { [weak self] state in self?.render(save: state) }
        viewModel.onAvatarURLChange = { [weak self] url in self?.loadAvatar(url) }
        viewModel.onBannerChange = { [weak self] in self?.reconfigureBanner() }
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
        // A titled header: the soft blur covers the bar (#1591) — see
        // `applyTopEdge(for:)`.
        collectionView.applyTopEdge(for: .titled)
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let heroRegistration = UICollectionView.CellRegistration<EditProfileHeroCell, Item> { [weak self] cell, _, _ in
            guard let self else { return }
            cell.setRedacted(false)
            cell.setAvatar(
                avatarURL,
                monogram: MonogramAvatarView.monogram(name: fields?.displayName ?? "", handle: fields?.username ?? ""),
                pipeline: imagePipeline
            )
            cell.onChangePhoto = { [weak self] in self?.changePhotoTapped() }
        }

        let fieldRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Field> { [weak self] cell, _, field in
            var content = UIListContentConfiguration.valueCell()
            content.text = field.title
            content.secondaryText = self?.displayValue(for: field)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let privacyRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = UIListContentConfiguration.valueCell()
            content.text = "Privacy"
            content.image = UIImage(systemName: "lock")
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let accountTypeRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = UIListContentConfiguration.valueCell()
            content.text = "Account Type"
            content.image = UIImage(systemName: "briefcase")
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let videoBannerRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, _ in
            var content = UIListContentConfiguration.valueCell()
            content.text = "Video Banner"
            content.image = UIImage(systemName: "play.rectangle")
            switch self?.viewModel.videoBannerRow {
            case .locked(let price)?:
                content.secondaryText = "\(price) gems"
                cell.accessories = [.customView(configuration: .init(
                    customView: UIImageView(image: UIImage(systemName: "lock.fill")), placement: .trailing()
                )), .disclosureIndicator()]
            case .on?:
                content.secondaryText = "On"
                cell.accessories = [.disclosureIndicator()]
            default:
                content.secondaryText = "Off"
                cell.accessories = [.disclosureIndicator()]
            }
            cell.contentConfiguration = content
        }

        // The hero redacted (#1774): the real cell, its avatar awaiting its
        // picture and a bone where "Change photo" stands.
        let heroSkeletonRegistration = UICollectionView.CellRegistration<EditProfileHeroCell, Item> { cell, _, _ in
            cell.setRedacted(true)
        }
        // The banner's row redacted (#1774): its symbol, title and value.
        let bannerSkeletonRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, _ in
            var content = UIListContentConfiguration.valueCell()
            content.text = "Video Banner"
            content.secondaryText = "Off"
            content.image = UIImage(systemName: "play.rectangle")
            cell.contentConfiguration = SkeletonRowConfiguration(redacting: content)
            cell.accessories = []
        }

        // The field rows redacted (#1769): Name, Username, Bio, Website and
        // Links with sample values, as bones at the real rows' metrics.
        let rowSkeletonRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Int> { cell, _, index in
            let samples = [
                ("Name", "Kenji Tanaka"), ("Username", "kenji.dev"), ("Bio", "Building small tools"),
                ("Website", "kenji.dev"), ("Links", "2 links"),
            ]
            var content = UIListContentConfiguration.valueCell()
            (content.text, content.secondaryText) = samples[index % samples.count]
            cell.contentConfiguration = SkeletonRowConfiguration(redacting: content)
            cell.accessories = []
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .hero:
                return collectionView.dequeueConfiguredReusableCell(using: heroRegistration, for: indexPath, item: item)
            case .field(let field):
                return collectionView.dequeueConfiguredReusableCell(using: fieldRegistration, for: indexPath, item: field)
            case .privacy:
                return collectionView.dequeueConfiguredReusableCell(using: privacyRegistration, for: indexPath, item: item)
            case .accountType:
                return collectionView.dequeueConfiguredReusableCell(using: accountTypeRegistration, for: indexPath, item: item)
            case .videoBanner:
                return collectionView.dequeueConfiguredReusableCell(using: videoBannerRegistration, for: indexPath, item: item)
            case .heroSkeleton:
                return collectionView.dequeueConfiguredReusableCell(using: heroSkeletonRegistration, for: indexPath, item: item)
            case .rowSkeleton(let index):
                return collectionView.dequeueConfiguredReusableCell(using: rowSkeletonRegistration, for: indexPath, item: index)
            case .bannerSkeleton:
                return collectionView.dequeueConfiguredReusableCell(using: bannerSkeletonRegistration, for: indexPath, item: item)
            }
        }
    }

    // MARK: - Render

    /// The first load's skeleton on the kit's timing (#1770). Injectable so
    /// a test steps it.
    var skeletonClock: LoadingClock = .system
    private lazy var skeletonGate: SkeletonGate = {
        let gate = SkeletonGate(clock: skeletonClock)
        gate.onSkeletonChange = { [weak self] showing in
            guard let self, showing, awaitingFirstLoad else { return }
            applySkeletonSnapshot()
        }
        gate.onTakingLonger = { [weak self] in
            self?.skeletonGate.finish { [weak self] in self?.showTakingLonger() }
        }
        return gate
    }()
    /// Nothing loaded yet: the first answer replaces the bones (or the
    /// blank of the delay), and a failure has no form to stay on.
    private var awaitingFirstLoad = false

    /// Past 10 s with nothing loaded: "Taking longer than usual", Try Again.
    private func showTakingLonger() {
        guard awaitingFirstLoad else { return }
        isShowingSkeleton = false
        dataSource.apply(NSDiffableDataSourceSnapshot<Section, Item>(), animatingDifferences: false)
        loadFailure.configure(
            symbolName: TakingLongerCopy.symbol, title: TakingLongerCopy.title,
            subtitle: "Your profile is still on its way.",
            actionTitle: TakingLongerCopy.action, actionHandler: { [weak self] in self?.retryFirstLoad() }
        )
        loadFailure.isHidden = false
    }

    /// Try Again on the first load: the wait starts over.
    private func retryFirstLoad() {
        loadFailure.isHidden = true
        awaitingFirstLoad = true
        skeletonGate.begin()
        viewModel.reload()
    }

    private func render(_ phase: EditProfileViewModel.Phase) {
        // ⚠️ THE FIRST ANSWER WAITS OUT THE BONES' MINIMUM (#1770).
        if awaitingFirstLoad, phase != .loading {
            return skeletonGate.finish { [weak self] in self?.renderNow(phase) }
        }
        renderNow(phase)
    }

    private func renderNow(_ phase: EditProfileViewModel.Phase) {
        switch phase {
        case .loading:
            break
        case .ready(let fields):
            awaitingFirstLoad = false
            self.fields = fields
            loadFailure.isHidden = true
            applyRealSnapshot()
        case .failed(let message):
            // ⚠️ A FIRST LOAD THAT FAILED IS A DEAD END WITHOUT A WAY OUT
            // (#1767): an alert with only "OK" left the skeleton up for good.
            // With nothing loaded yet, the shared failure block replaces the
            // bones and offers Try Again; with the form already shown (a
            // reload after a rejected edit), the alert says what happened and
            // the form stays.
            guard awaitingFirstLoad else { return presentError(message) }
            isShowingSkeleton = false
            dataSource.apply(NSDiffableDataSourceSnapshot<Section, Item>(), animatingDifferences: false)
            loadFailure.configure(
                symbolName: "exclamationmark.triangle", title: message,
                actionTitle: "Try Again", actionHandler: { [weak self] in self?.retryFirstLoad() }
            )
            loadFailure.isHidden = false
        }
    }

    /// The first load's failure, with Try Again (#1767).
    private lazy var loadFailure: EmptyStateView = {
        let view = EmptyStateView()
        view.isHidden = true
        collectionView.backgroundView = view
        return view
    }()

    #if DEBUG
    /// The video banner's Buy, as the confirmation sheet's button.
    func debugBuyVideoBanner() async { await buyVideoBanner() }
    /// Whether the first load's failure block shows.
    var debugShowsLoadFailure: Bool { !loadFailure.isHidden }
    /// The form's rows by kind, as applied: "hero", "heroSkeleton",
    /// "rowSkeleton", "privacy"… — what a test reads.
    var debugItemKinds: [String] {
        dataSource.snapshot().itemIdentifiers.map { item in
            switch item {
            case .rowSkeleton: "rowSkeleton"
            case .field: "field"
            default: String(describing: item)
            }
        }
    }
    #endif

    private func render(save state: EditProfileViewModel.SaveState) {
        switch state {
        case .idle, .saving:
            break
        case .saved:
            // Said once the server has every edit (#803): fields save as they
            // are left, with no Done button to confirm them.
            Feedback.success("Profile saved", from: self)
        case .failed(let message):
            // Re-sync from the server so the list can't drift from the truth
            // after a rejected optimistic edit.
            presentError(message)
            viewModel.reload()
        }
    }

    /// The form redacted (#1774): every section the real form has, in its
    /// place — the hero redacted, the banner's row when the banner is
    /// offered, the field rows as bones — and the privacy rows real, since
    /// they show nothing that loads. Nothing moves when the content lands.
    private func applySkeletonSnapshot() {
        isShowingSkeleton = true
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        let banner = viewModel.videoBannerRow != .hidden
        snapshot.appendSections(banner ? [.hero, .banner, .identity, .links, .privacy] : [.hero, .identity, .links, .privacy])
        snapshot.appendItems([.heroSkeleton], toSection: .hero)
        if banner { snapshot.appendItems([.bannerSkeleton], toSection: .banner) }
        snapshot.appendItems([.rowSkeleton(0), .rowSkeleton(1), .rowSkeleton(2), .rowSkeleton(3)], toSection: .identity)
        snapshot.appendItems([.rowSkeleton(4)], toSection: .links)
        snapshot.appendItems([.privacy] + (onOpenAccountType == nil ? [] : [.accountType]), toSection: .privacy)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func applyRealSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        let banner = viewModel.videoBannerRow != .hidden
        snapshot.appendSections(banner ? [.hero, .banner, .identity, .links, .privacy] : [.hero, .identity, .links, .privacy])
        snapshot.appendItems([.hero], toSection: .hero)
        if banner { snapshot.appendItems([.videoBanner], toSection: .banner) }
        snapshot.appendItems([.field(.name), .field(.username), .field(.bio), .field(.website)], toSection: .identity)
        snapshot.appendItems([.field(.links)], toSection: .links)
        snapshot.appendItems([.privacy] + (onOpenAccountType == nil ? [] : [.accountType]), toSection: .privacy)

        guard isShowingSkeleton else {
            dataSource.apply(snapshot, animatingDifferences: false)
            return
        }
        // First real data: cross-dissolve the whole list so the shimmer fades
        // out as the content fades in, rather than snapping.
        isShowingSkeleton = false
        collectionView.crossfadeSkeleton { self.dataSource.apply(snapshot, animatingDifferences: false) }
    }

    private func reconfigureBanner() {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.videoBanner) else { return }
        snapshot.reconfigureItems([.videoBanner])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Reflects a single field's new value without rebuilding the list.
    private func reconfigure(_ field: Field) {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([.field(field)])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The hero's picture: its avatar loads it (#1750). If the real hero
    /// isn't on screen yet (still skeleton), the URL waits — the real
    /// snapshot picks it up when it applies.
    private func loadAvatar(_ url: URL?) {
        avatarURL = url
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(.hero) else { return }
        snapshot.reconfigureItems([.hero])
        dataSource.apply(snapshot, animatingDifferences: false)
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
        switch dataSource.itemIdentifier(for: indexPath) {
        case .field(let field): edit(field)
        case .privacy: onOpenPrivacy?()
        case .accountType: onOpenAccountType?()
        case .videoBanner: openVideoBanner()
        default: break
        }
    }
}

// MARK: - Video banner (#944)

extension EditProfileViewController {
    /// Owned: the picker. Not yet: the item, its price and what it does.
    func openVideoBanner() {
        switch viewModel.videoBannerRow {
        case .hidden: return
        case .locked(let price): presentVideoBannerOffer(price: price)
        case .off, .on: pushVideoBannerPicker()
        }
    }

    private func presentVideoBannerOffer(price: Int) {
        let gems = viewModel.gems
        var message = "A muted loop from one of your own videos plays at the top of your profile. Bought once, yours for good."
        if gems < price { message += "\n\nYou have \(gems) gems: \(price - gems) more needed." }
        let sheet = UIAlertController(title: "Video Banner", message: message, preferredStyle: .actionSheet)
        let buy = UIAlertAction(title: "Buy for \(price) gems", style: .default) { [weak self] _ in
            Task { [weak self] in await self?.buyVideoBanner() }
        }
        buy.isEnabled = gems >= price
        sheet.addAction(buy)
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
        }
        present(sheet, animated: true)
    }

    private func buyVideoBanner() async {
        // Under way (#1775): "Buying…" past the loader's grace, the answer
        // in its place.
        let pending = PendingFeedback("Buying the video banner…", from: self)
        switch await viewModel.buyVideoBanner() {
        // One haptic per outcome: the toast's (#1884).
        case .bought, .alreadyOwned:
            pending.succeed("Video banner unlocked")
            pushVideoBannerPicker()
        case .insufficientGems(let needed, let have):
            pending.warn("\(needed - have) more gems needed")
        case .unavailable:
            pending.warn("Not available on this account")
        // The server's answers (#1475): nothing was charged.
        case .priceChanged(let price):
            pending.warn(price.map { "The price changed: now \($0) gems" } ?? "The price changed")
        case .failed:
            pending.warn("Couldn't reach the Shop. Nothing was charged — try again.")
        }
    }

    private func pushVideoBannerPicker() {
        let viewModel = viewModel
        push(VideoBannerPickerViewController(
            load: { try await viewModel.ownVideoPosts() },
            imagePipeline: imagePipeline,
            current: viewModel.bannerVideoURL,
            onPick: { post in viewModel.setVideoBanner(post) }
        ))
    }
}

// MARK: - Hero cell

/// The avatar hero at the top of the editor: a large circular avatar over a
/// "Change photo" button, on a clear background so it doesn't read as a grouped
/// row. The avatar is the app's (#1750): the picture with its skeleton, the
/// initials without one — no generic person glyph.
private final class EditProfileHeroCell: UICollectionViewListCell {
    private let avatarView = AvatarView(diameter: EditProfileHeroCell.avatarDiameter, size: .px512)
    private let changeButton = UIButton(configuration: .plain())
    var onChangePhoto: (() -> Void)?

    private static let avatarDiameter: CGFloat = 96

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()

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
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.md),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.sm),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setAvatar(_ url: URL?, monogram: String, pipeline: ImagePipeline) {
        avatarView.setMonogram(monogram)
        avatarView.setPicture(url, pipeline: pipeline)
    }

    /// The hero redacted while the profile loads (#1774): the avatar holds
    /// its place with its own bone (`awaitPicture`, the avatar contract), and
    /// a bone stands where "Change photo" is — the real cell, so nothing moves
    /// when it is told who this is.
    func setRedacted(_ redacted: Bool) {
        changeButton.alpha = redacted ? 0 : 1
        changeButton.isUserInteractionEnabled = !redacted
        captionBone.isHidden = !redacted
        if redacted { avatarView.awaitPicture() }
    }

    private lazy var captionBone: SkeletonBoneView = {
        let bone = SkeletonBoneView(rounding: .capsule)
        bone.isHidden = true
        bone.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bone)
        NSLayoutConstraint.activate([
            bone.centerXAnchor.constraint(equalTo: changeButton.centerXAnchor),
            bone.centerYAnchor.constraint(equalTo: changeButton.centerYAnchor),
            bone.widthAnchor.constraint(equalToConstant: 110),
            bone.heightAnchor.constraint(equalToConstant: 14),
        ])
        return bone
    }()
}

