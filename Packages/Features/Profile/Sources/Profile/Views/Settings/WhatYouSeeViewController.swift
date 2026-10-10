import DesignSystem
import UIKit

/// Settings → What You See (#407, #413): how much sensitive content the feeds
/// may show (synced on the profile, backend #731), whether For You is ranked
/// by the profile's interests, the interests themselves — each removable,
/// or all reset (timeline #662) — and how each feed is ordered: the
/// plain-language account of the recommender DSA Art. 27 and 38 ask for.
///
/// Not optimistic, like the other privacy-adjacent choices: the checkmark,
/// the switch and the list move once the server holds the change.
final class WhatYouSeeViewController: UIViewController {
    enum Phase: Equatable {
        case loading
        case loaded(SensitiveContentLevel, personalized: Bool)
        case failed
    }

    enum InterestsPhase: Equatable {
        case loading
        case loaded([InterestTag])
        case failed
    }

    enum Section: Hashable {
        case sensitive, personalization, interests, ordering
    }

    private enum Item: Hashable {
        case level(SensitiveContentLevel)
        case loading
        case failed
        case personalized
        case interest(InterestTag)
        case noInterests
        case interestsLoading
        case interestsFailed
        case resetInterests
        case following
        case forYou
    }

    private let preferences: any FeedPreferencesManaging
    private let interestTags: (any InterestTagsManaging)?
    /// Under 18: Standard isn't offered (the server clamps it anyway).
    ///
    /// ⚠️ **AN UNREAD AGE IS NOT AN ADULT ONE (#799).** It throws when the
    /// account can't be read, and the sensitive-content section then shows
    /// its failed row — retry reads the age with the settings — rather than
    /// offering Standard and the adult footer to an account that may be 14.
    /// The failed row over a guess: "teen" would grey out Standard for an
    /// adult just as wrongly.
    private let isTeen: () async throws -> Bool
    private var teen = false
    private var phase: Phase = .loading {
        didSet { applySnapshot() }
    }
    private var interestsPhase: InterestsPhase = .loading {
        didSet { applySnapshot() }
    }
    private var isSaving = false
    private var isSavingPersonalized = false
    /// Tags whose removal (or the reset) is in flight.
    private var removing: Set<String> = []
    private var isResetting = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(
        preferences: any FeedPreferencesManaging,
        interestTags: (any InterestTagsManaging)? = nil,
        isTeen: @escaping () async throws -> Bool = { false }
    ) {
        self.preferences = preferences
        self.interestTags = interestTags
        self.isTeen = isTeen
        super.init(nibName: nil, bundle: nil)
        title = SettingsSection.whatYouSee.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, case .interest(let interest) = dataSource.itemIdentifier(for: indexPath),
                  !removing.contains(interest.tag), !isResetting else { return nil }
            let action = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
                self?.remove(interest)
                done(true)
            }
            return UISwipeActionsConfiguration(actions: [action])
        }
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
        configureDataSource()
        applySnapshot()
        load()
    }

    private func load() {
        // A retry from the failed row that fails again says so.
        let wasFailed = phase == .failed
        phase = .loading
        Task { [weak self] in
            guard let self else { return }
            let (next, teen) = await Self.loadSensitive(preferences: preferences, isTeen: isTeen)
            self.teen = teen ?? self.teen
            phase = next
            if wasFailed, next == .failed {
                ToastView.present("Couldn't load these settings", symbol: "exclamationmark.triangle", in: view)
            }
        }
        loadInterests()
    }

    /// The sensitive-content section's read: the level, the For You switch
    /// and the age that decides whether Standard is offered. Any of the
    /// three failing fails the section — the age included (#799). Pure, so
    /// the rule is pinned by tests.
    static func loadSensitive(
        preferences: any FeedPreferencesManaging,
        isTeen: () async throws -> Bool
    ) async -> (phase: Phase, teen: Bool?) {
        do {
            async let level = preferences.sensitiveContent()
            async let personalized = preferences.personalizedFeed()
            let teen = try await isTeen()
            return (.loaded(try await level, personalized: try await personalized), teen)
        } catch {
            return (.failed, nil)
        }
    }

    private func loadInterests() {
        guard let interestTags else { return }
        interestsPhase = .loading
        Task { [weak self] in
            do {
                let tags = try await interestTags.interests()
                self?.interestsPhase = .loaded(tags)
            } catch {
                self?.interestsPhase = .failed
            }
        }
    }

    // MARK: - Copy

    static func header(_ section: Section) -> String {
        switch section {
        case .sensitive: "Sensitive Content"
        case .personalization: "For You"
        case .interests: "Your Interests"
        case .ordering: "How Your Feeds Are Ordered"
        }
    }

    static func footer(_ section: Section, teen: Bool) -> String? {
        switch section {
        case .sensitive:
            teen
                ? "You're under 18, so posts marked as sensitive stay out of your feeds. Applies to this profile."
                : "Applies to this profile, on all your devices."
        case .personalization:
            "When this is on, For You puts posts that match your interests first. Your interests come from the hashtags of posts you react to. When it's off, For You is ranked the same way for everyone, nothing is learnt, and the interests learnt so far are erased."
        case .interests:
            "Swipe left on an interest to remove it. A removed interest stops shaping For You and isn't learnt again. Resetting forgets everything, including interests you removed."
        case .ordering:
            "Following never uses your interests."
        }
    }

    static let personalizedTitle = "Personalised For You"
    static let resetTitle = "Reset Interests"
    static let followingDetail = "Posts from accounts you follow, newest first."

    static func forYouDetail(personalized: Bool) -> String {
        personalized
            ? "Popular and recent posts, with the ones that match your interests first."
            : "Popular and recent posts, ranked the same way for everyone."
    }

    static func noInterestsText(personalized: Bool) -> String {
        personalized
            ? "No interests yet. They appear as you react to posts with hashtags."
            : "Personalised For You is off, so no interests are learnt."
    }

    /// How much a tag weighs, in words: weights halve every 30 days without a
    /// new reaction, so the number itself means little to a reader.
    static func strength(_ weight: Double) -> String {
        switch weight {
        case 0.66...: "Strong"
        case 0.33..<0.66: "Moderate"
        default: "Light"
        }
    }

    // MARK: - List

    private var isPersonalized: Bool {
        if case .loaded(_, let personalized) = phase { return personalized }
        return false
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            cell.accessories = []
            var content = UIListContentConfiguration.subtitleCell()
            content.secondaryTextProperties.color = .secondaryLabel
            switch item {
            case .level(let level):
                content.text = level.title
                content.secondaryText = level.detail
                let unavailable = level == .standard && teen
                content.textProperties.color = unavailable ? .secondaryLabel : .label
                if case .loaded(let current, _) = phase, current == level {
                    cell.accessories = [.checkmark()]
                    cell.accessibilityTraits.insert(.selected)
                } else {
                    cell.accessibilityTraits.remove(.selected)
                }
                if unavailable { cell.accessibilityTraits.insert(.notEnabled) } else { cell.accessibilityTraits.remove(.notEnabled) }
            case .loading, .interestsLoading:
                content = .cell()
                content.text = "Loading…"
                content.textProperties.color = .secondaryLabel
            case .failed:
                content = .cell()
                content.text = "Couldn't load these settings. Tap to try again."
                content.textProperties.color = .secondaryLabel
            case .interestsFailed:
                content = .cell()
                content.text = "Couldn't load your interests. Tap to try again."
                content.textProperties.color = .secondaryLabel
            case .personalized:
                content = .cell()
                content.text = Self.personalizedTitle
                content.image = UIImage(systemName: "sparkles")
                content.imageProperties.tintColor = .label
                let toggle = UISwitch()
                toggle.isOn = isPersonalized
                toggle.isEnabled = !isSavingPersonalized
                toggle.accessibilityLabel = Self.personalizedTitle
                toggle.addAction(UIAction { [weak self] action in
                    guard let toggle = action.sender as? UISwitch else { return }
                    self?.setPersonalized(toggle.isOn)
                }, for: .valueChanged)
                cell.accessories = [.customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))]
            case .interest(let interest):
                content = .valueCell()
                content.text = "#" + interest.tag
                content.secondaryText = Self.strength(interest.weight)
                let busy = removing.contains(interest.tag) || isResetting
                content.textProperties.color = busy ? .secondaryLabel : .label
            case .noInterests:
                content = .cell()
                content.text = Self.noInterestsText(personalized: isPersonalized)
                content.textProperties.color = .secondaryLabel
            case .resetInterests:
                content = .cell()
                content.text = Self.resetTitle
                content.textProperties.color = isResetting ? .secondaryLabel : .systemRed
            case .following:
                content.text = "Following"
                content.secondaryText = Self.followingDetail
                content.image = UIImage(systemName: "person.2")
                content.imageProperties.tintColor = .label
            case .forYou:
                content.text = "For You"
                content.secondaryText = Self.forYouDetail(personalized: isPersonalized)
                content.image = UIImage(systemName: "sparkles")
                content.imageProperties.tintColor = .label
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).map(Self.header)
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = dataSource.sectionIdentifier(for: indexPath.section).flatMap { section in
                // How to remove an interest says nothing when there is none.
                if section == .interests, case .loaded(let tags) = self.interestsPhase, tags.isEmpty { return nil }
                return Self.footer(section, teen: self.teen)
            }
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.sensitive])
        switch phase {
        case .loading: snapshot.appendItems([.loading], toSection: .sensitive)
        case .failed: snapshot.appendItems([.failed], toSection: .sensitive)
        case .loaded:
            snapshot.appendItems(SensitiveContentLevel.allCases.map(Item.level), toSection: .sensitive)
            snapshot.appendSections([.personalization])
            snapshot.appendItems([.personalized], toSection: .personalization)
            if interestTags != nil {
                snapshot.appendSections([.interests])
                switch interestsPhase {
                case .loading: snapshot.appendItems([.interestsLoading], toSection: .interests)
                case .failed: snapshot.appendItems([.interestsFailed], toSection: .interests)
                case .loaded(let tags) where tags.isEmpty:
                    snapshot.appendItems([.noInterests], toSection: .interests)
                case .loaded(let tags):
                    snapshot.appendItems(tags.map(Item.interest) + [.resetInterests], toSection: .interests)
                }
            }
        }
        snapshot.appendSections([.ordering])
        snapshot.appendItems([.following, .forYou], toSection: .ordering)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        // Their footers follow state (teen, an empty list).
        snapshot.reloadSections([.sensitive] + (snapshot.sectionIdentifiers.contains(.interests) ? [.interests] : []))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func alert(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func choose(_ level: SensitiveContentLevel) {
        guard case .loaded(let current, let personalized) = phase, current != level, !isSaving else { return }
        guard !(level == .standard && teen) else { return }
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await preferences.setSensitiveContent(level)
                phase = .loaded(level, personalized: personalized)
                HapticSelection().selectionChanged()
            } catch {
                alert("Couldn't change this setting. Try again.")
            }
            isSaving = false
        }
    }

    /// Turning it off erases the learnt interests on the server, so the list
    /// is read again either way.
    private func setPersonalized(_ isOn: Bool) {
        guard case .loaded(let level, _) = phase, !isSavingPersonalized else { return }
        isSavingPersonalized = true
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await preferences.setPersonalizedFeed(isOn)
                isSavingPersonalized = false
                phase = .loaded(level, personalized: isOn)
                loadInterests()
            } catch {
                isSavingPersonalized = false
                applySnapshot()
                alert("Couldn't change \(Self.personalizedTitle). Try again.")
            }
        }
    }

    private func remove(_ interest: InterestTag) {
        guard let interestTags, !removing.contains(interest.tag), !isResetting else { return }
        removing.insert(interest.tag)
        applySnapshot()
        Task { [weak self] in
            do {
                let remaining = try await interestTags.removeInterest(interest.tag)
                guard let self else { return }
                removing.remove(interest.tag)
                interestsPhase = .loaded(remaining)
            } catch {
                guard let self else { return }
                removing.remove(interest.tag)
                applySnapshot()
                alert("Couldn't remove #\(interest.tag). Try again.")
            }
        }
    }

    private func confirmReset() {
        guard interestTags != nil, !isResetting else { return }
        let confirm = UIAlertController(
            title: "Reset your interests?",
            message: "For You forgets everything it learnt about you, including interests you removed, and starts over.",
            preferredStyle: .alert
        )
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        confirm.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in self?.reset() })
        present(confirm, animated: true)
    }

    private func reset() {
        guard let interestTags else { return }
        isResetting = true
        applySnapshot()
        Task { [weak self] in
            do {
                let remaining = try await interestTags.resetInterests()
                guard let self else { return }
                isResetting = false
                interestsPhase = .loaded(remaining)
            } catch {
                guard let self else { return }
                isResetting = false
                applySnapshot()
                alert("Couldn't reset your interests. Try again.")
            }
        }
    }
}

extension WhatYouSeeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .level(let level): !(level == .standard && teen)
        case .failed, .interestsFailed: true
        case .resetInterests: !isResetting
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .level(let level): choose(level)
        case .failed: load()
        case .interestsFailed: loadInterests()
        case .resetInterests: confirmReset()
        default: break
        }
    }
}
