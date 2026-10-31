import CoreNetworking
import DesignSystem
import UIKit

/// A supervisor edits a teen's limits (#417, backend #670 part 2): the daily
/// limit, a private account, who can message and comment at the loosest, and
/// hidden from search. Nothing is sent until Save; Save waits for the server
/// and a refusal keeps the draft so it can be fixed.
final class SupervisionLimitsViewController: UIViewController {
    enum Section: Int, CaseIterable {
        case daily, account, audiences
    }

    enum Item: Hashable {
        case dailyLimit
        case privateAccount
        case hiddenFromSearch
        case messages
        case comments
    }

    let model: SupervisionOverviewModel
    private let teenName: String
    /// The limits saved; the opener steps back and says so.
    private let onSaved: (SupervisionLimitsViewController) -> Void
    private let original: SupervisionLimits
    private(set) var draft: SupervisionLimits
    private(set) var isSaving = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(model: SupervisionOverviewModel, teenName: String, onSaved: @escaping (SupervisionLimitsViewController) -> Void) {
        self.model = model
        self.teenName = teenName
        self.onSaved = onSaved
        original = model.overview?.limits.limits ?? SupervisionLimits()
        draft = original
        super.init(nibName: nil, bundle: nil)
        title = SupervisionCopy.editLimitsTitle
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        setOwnTrailingBarItems([saveItem()], animated: false)
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
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
        updateSave()
    }

    static func footer(_ section: Section, teenName: String) -> String {
        switch section {
        case .daily:
            "\(teenName) sees a pause screen once today's time on all devices reaches it. Nothing is cut off."
        case .account:
            "A private account keeps posts to approved followers. Hidden from search keeps the profile out of search, suggestions and contact matching; a shared link or QR code still works."
        case .audiences:
            "The loosest choice \(teenName) can make. They can always pick something stricter."
        }
    }

    // MARK: - Draft

    func setDailyMinutes(_ minutes: Int?) { change { $0.dailyMinutes = minutes } }
    func setPrivateAccount(_ on: Bool) { change { $0.privateAccount = on } }
    func setHiddenFromSearch(_ on: Bool) { change { $0.hiddenFromSearch = on } }
    func setMessages(_ floor: AudienceFloor?) { change { $0.messages = floor } }
    func setComments(_ floor: AudienceFloor?) { change { $0.comments = floor } }

    private func change(_ mutate: (inout SupervisionLimits) -> Void) {
        mutate(&draft)
        applySnapshot()
        updateSave()
    }

    var canSave: Bool { draft != original && !isSaving }

    private func updateSave() {
        guard !isSaving else { return }
        ownTrailingBarItems.first?.isEnabled = canSave
    }

    static let saveID = "settings.supervisionLimits.save"

    private func saveItem() -> UIBarButtonItem {
        BarItems.title(id: Self.saveID, title: "Save", prominent: true) { [weak self] in self?.save() }
    }

    /// Save at work (#1775): the word becomes the kit's loader, under the
    /// same identifier, and comes back if the save fails.
    private func showSaving(_ saving: Bool) {
        let item = saving ? BarItems.busy(id: Self.saveID, label: "Saving") : saveItem()
        setOwnTrailingBarItems([item], animated: view.window != nil)
        updateSave()
    }

    func save() {
        guard canSave else { return }
        isSaving = true
        showSaving(true)
        let limits = draft
        Task { [weak self] in
            guard let self else { return }
            do {
                try await model.setLimits(limits)
                onSaved(self)
            } catch {
                isSaving = false
                showSaving(false)
                Feedback.failure(
                    SupervisionCopy.failureText(error, teen: false, fallback: "Couldn't save the limits"), from: self
                )
            }
        }
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.valueCell()
            switch item {
            case .dailyLimit:
                content.text = "Daily Limit"
                // The pop-up accessory draws only its chevron: the value is
                // the row's own second text.
                content.secondaryText = SupervisionCopy.dailyLimitText(draft.dailyMinutes)
                cell.accessories = [.popUpMenu(dailyMenu())]
            case .messages:
                content.text = "Who Can Message"
                content.secondaryText = SupervisionCopy.floorText(draft.messages)
                cell.accessories = [.popUpMenu(floorMenu(draft.messages, set: { [weak self] in self?.setMessages($0) }))]
            case .comments:
                content.text = "Who Can Comment"
                content.secondaryText = SupervisionCopy.floorText(draft.comments)
                cell.accessories = [.popUpMenu(floorMenu(draft.comments, set: { [weak self] in self?.setComments($0) }))]
            case .privateAccount:
                content = .cell()
                content.text = "Private Account"
                cell.accessories = [.customView(configuration: toggle(draft.privateAccount) { [weak self] in self?.setPrivateAccount($0) })]
            case .hiddenFromSearch:
                content = .cell()
                content.text = "Hidden from Search"
                cell.accessories = [.customView(configuration: toggle(draft.hiddenFromSearch) { [weak self] in self?.setHiddenFromSearch($0) })]
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: item)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = Section(rawValue: indexPath.section).map { Self.footer($0, teenName: self.teenName) }
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func dailyMenu() -> UIMenu {
        let choices: [Int?] = [nil] + SupervisionLimits.dailyMinuteChoices.map(Optional.some)
        return UIMenu(children: choices.map { minutes in
            UIAction(title: SupervisionCopy.dailyLimitText(minutes), state: draft.dailyMinutes == minutes ? .on : .off) { [weak self] _ in
                self?.setDailyMinutes(minutes)
            }
        })
    }

    private func floorMenu(_ current: AudienceFloor?, set: @escaping (AudienceFloor?) -> Void) -> UIMenu {
        let choices: [AudienceFloor?] = [nil] + AudienceFloor.allCases.map(Optional.some)
        return UIMenu(children: choices.map { floor in
            UIAction(title: SupervisionCopy.floorText(floor), state: current == floor ? .on : .off) { _ in set(floor) }
        })
    }

    private func toggle(_ isOn: Bool, onChange: @escaping (Bool) -> Void) -> UICellAccessory.CustomViewConfiguration {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addAction(UIAction { action in
            guard let toggle = action.sender as? UISwitch else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        return UICellAccessory.CustomViewConfiguration(customView: toggle, placement: .trailing())
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.dailyLimit], toSection: .daily)
        snapshot.appendItems([.privateAccount, .hiddenFromSearch], toSection: .account)
        snapshot.appendItems([.messages, .comments], toSection: .audiences)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension SupervisionLimitsViewController: UICollectionViewDelegate {
    /// A pop-up row opens its menu on a tap; a switch row takes none.
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .dailyLimit, .messages, .comments: true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
    }
}

// MARK: - How it is left (#1144)

extension SupervisionLimitsViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
