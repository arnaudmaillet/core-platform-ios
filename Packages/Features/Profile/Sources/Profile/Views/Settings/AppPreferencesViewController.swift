import CoreStorage
import DesignSystem
import UIKit

/// The screens of Settings → App and Device (#468): Playback and Sound,
/// Display, Comments on Media, Language and Storage — one controller, one
/// page per section (#409, #410). Everything here is stored on the device
/// (`MediaPlaybackPreferencesStore`, `MediaCommentPreferencesStore`,
/// `AppearancePreference`, `MotionPreference`) and follows the iPhone, not
/// the profile.
final class AppPreferencesViewController: UIViewController {
    enum Section: Int, CaseIterable {
        case playback, appearance, motion, band, muted, subtitles, language, storage
    }

    private enum Item: Hashable {
        case autoplay, startsWithSound, dataSaver
        case appearance, reduceMotion
        case bandSwitch, opacity, speed
        case mutedWords, mutedAccounts
        case subtitlesSwitch
        case appLanguage
        case cacheSize, clearCache
    }

    /// The sections each App and Device page shows.
    static func sections(for page: SettingsSection) -> [Section] {
        switch page {
        case .playback: [.playback]
        case .display: [.appearance, .motion]
        case .mediaComments: [.band, .muted, .subtitles]
        case .language: [.language]
        case .storage: [.storage]
        default: []
        }
    }

    private let page: SettingsSection

    private let store: MediaCommentPreferencesStore
    private let playback: MediaPlaybackPreferencesStore
    private let cache: MediaCacheInventory
    /// Bytes in the media caches; nil while measuring.
    private var cacheBytes: Int64?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(
        page: SettingsSection,
        store: MediaCommentPreferencesStore = .standard,
        playback: MediaPlaybackPreferencesStore = .standard,
        cache: MediaCacheInventory = .standard
    ) {
        self.page = page
        self.store = store
        self.playback = playback
        self.cache = cache
        super.init(nibName: nil, bundle: nil)
        title = page.title
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
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersClearTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
        configureDataSource()
        applySnapshot()
        if page == .storage { measureCache() }
        // The footer quotes the iOS setting; keep it true when iOS changes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionSettingChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func motionSettingChanged() {
        guard page == .display else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([.reduceMotion])
        snapshot.reloadSections([.motion])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func measureCache() {
        let cache = cache
        Task { [weak self] in
            let bytes = await Task.detached(priority: .utility) { cache.size() }.value
            self?.cacheBytes = bytes
            self?.reconfigure([.cacheSize, .clearCache])
        }
    }

    private func confirmClearCache() {
        let sheet = UIAlertController(
            title: "Clear media cache?",
            message: "Videos and animations are downloaded again when you next see them. Drafts and posts aren't affected.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Clear Cache", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let cache = cache
            cacheBytes = nil
            reconfigure([.cacheSize, .clearCache])
            Task { [weak self] in
                await Task.detached(priority: .utility) { cache.clear() }.value
                self?.measureCache()
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The muted counts change on the pushed editors.
        if dataSource != nil { reconfigure([.mutedWords, .mutedAccounts]) }
    }

    // MARK: - Text

    private static func header(_ section: Section) -> String {
        switch section {
        case .appearance: "Appearance"
        case .motion: "Motion"
        case .language: "Language"
        case .playback: "Playback"
        case .band: "Reaction Band"
        case .muted: "Muted on Media"
        case .subtitles: "Subtitles"
        case .storage: "Storage"
        }
    }

    static func footer(_ section: Section) -> String {
        switch section {
        case .appearance: "System follows the iPhone's Light and Dark setting."
        case .motion:
            MotionPreference.appReducesMotion
                ? "Transitions and effects are kept to a minimum in the app."
                : "Off, the app follows iOS (Accessibility → Motion → Reduce Motion is currently "
                    + (UIAccessibility.isReduceMotionEnabled ? "on" : "off") + ")."
        case .language: "The app is in English for now. When more languages arrive, you'll choose yours here and in iOS Settings."
        case .playback: "A video that doesn't start on its own shows its first frame with a play mark; tap it to play. Data Saver lowers stream quality and stops loading upcoming videos ahead while on cellular."
        case .band: "The short reactions that scroll over videos and photos."
        case .muted: "Comments with these words, or from these accounts, never appear in the reaction band or the subtitles. They still show in the comments."
        case .subtitles: "Comments shown as captions above the reaction band."
        case .storage: "Downloaded videos and animations, kept so they open instantly. Clearing them frees space; nothing you made is removed."
        }
    }

    static func appearanceTitle(_ appearance: AppearancePreference) -> String {
        appearance.title
    }

    static func autoplayTitle(_ autoplay: MediaPlaybackPreferences.Autoplay) -> String {
        switch autoplay {
        case .always: "Always"
        case .wifiOnly: "Wi-Fi Only"
        case .never: "Never"
        }
    }

    static func speedTitle(_ speed: MediaCommentPreferences.BandSpeed) -> String {
        switch speed {
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }

    // MARK: - List

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, for: item)
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
            var content = UIListContentConfiguration.footer()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).map(Self.footer)
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        for section in Self.sections(for: page) {
            snapshot.appendSections([section])
            snapshot.appendItems(Self.items(in: section), toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private static func items(in section: Section) -> [Item] {
        switch section {
        case .playback: [.autoplay, .startsWithSound, .dataSaver]
        case .appearance: [.appearance]
        case .motion: [.reduceMotion]
        case .band: [.bandSwitch, .opacity, .speed]
        case .muted: [.mutedWords, .mutedAccounts]
        case .subtitles: [.subtitlesSwitch]
        case .language: [.appLanguage]
        case .storage: [.cacheSize, .clearCache]
        }
    }

    private func reconfigure(_ items: [Item]) {
        var snapshot = dataSource.snapshot()
        // Only what this page shows: reconfiguring an absent item traps.
        let present = items.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configure(_ cell: UICollectionViewListCell, for item: Item) {
        let preferences = store.preferences
        cell.accessories = []
        cell.contentView.subviews.filter { $0.tag == Self.controlTag }.forEach { $0.removeFromSuperview() }
        switch item {
        case .appearance:
            cell.contentConfiguration = nil
            let options = AppearancePreference.allCases
            let control = UISegmentedControl(items: options.map(Self.appearanceTitle))
            control.selectedSegmentIndex = options.firstIndex(of: AppearancePreference.current) ?? 0
            control.accessibilityLabel = "Appearance"
            control.addAction(UIAction { action in
                guard let control = action.sender as? UISegmentedControl else { return }
                AppearancePreference.set(options[control.selectedSegmentIndex])
            }, for: .valueChanged)
            install(control, in: cell, title: nil)
        case .reduceMotion:
            cell.contentConfiguration = Self.label("Reduce Motion", symbol: "figure.walk.motion")
            cell.accessories = [switchAccessory(isOn: MotionPreference.appReducesMotion) { isOn in
                MotionPreference.appReducesMotion = isOn
            }]
        case .appLanguage:
            var content = Self.label("App Language", symbol: "globe")
            content.secondaryText = Self.currentLanguageName()
            cell.contentConfiguration = content
        case .autoplay:
            cell.contentConfiguration = nil
            let options = MediaPlaybackPreferences.Autoplay.allCases
            let control = UISegmentedControl(items: options.map(Self.autoplayTitle))
            control.selectedSegmentIndex = options.firstIndex(of: playback.preferences.autoplay) ?? 0
            control.accessibilityLabel = "Autoplay"
            control.addAction(UIAction { [weak self] action in
                guard let control = action.sender as? UISegmentedControl else { return }
                let choice = options[control.selectedSegmentIndex]
                self?.playback.update { $0.autoplay = choice }
            }, for: .valueChanged)
            install(control, in: cell, title: "Autoplay Videos")
        case .startsWithSound:
            cell.contentConfiguration = Self.label("Start with Sound", symbol: "speaker.wave.2")
            cell.accessories = [switchAccessory(isOn: playback.preferences.startsWithSound) { [weak self] isOn in
                self?.playback.update { $0.startsWithSound = isOn }
            }]
        case .dataSaver:
            cell.contentConfiguration = Self.label("Data Saver", symbol: "antenna.radiowaves.left.and.right")
            cell.accessories = [switchAccessory(isOn: playback.preferences.dataSaver) { [weak self] isOn in
                self?.playback.update { $0.dataSaver = isOn }
            }]
        case .cacheSize:
            var content = Self.label("Media Cache", symbol: "internaldrive")
            content.secondaryText = cacheBytes.map(MediaCacheInventory.formatted) ?? "Measuring…"
            cell.contentConfiguration = content
        case .clearCache:
            var content = UIListContentConfiguration.cell()
            content.text = "Clear Cache"
            content.textProperties.color = cacheBytes.map { $0 > 0 } == true ? .systemRed : .secondaryLabel
            cell.contentConfiguration = content
        case .bandSwitch:
            cell.contentConfiguration = Self.label("Show Reaction Band", symbol: "text.bubble")
            cell.accessories = [switchAccessory(isOn: preferences.showsReactionBand) { [weak self] isOn in
                self?.store.update { $0.showsReactionBand = isOn }
                self?.reconfigure([.opacity, .speed])
            }]
        case .opacity:
            cell.contentConfiguration = nil
            let slider = UISlider()
            slider.minimumValue = Float(MediaCommentPreferences.opacityRange.lowerBound)
            slider.maximumValue = Float(MediaCommentPreferences.opacityRange.upperBound)
            slider.value = Float(preferences.bandOpacity)
            slider.minimumValueImage = UIImage(systemName: "circle.dotted")
            slider.maximumValueImage = UIImage(systemName: "circle.fill")
            slider.isEnabled = preferences.showsReactionBand
            slider.accessibilityLabel = "Opacity"
            slider.addAction(UIAction { [weak self] action in
                guard let slider = action.sender as? UISlider else { return }
                self?.store.update { $0.bandOpacity = Double(slider.value) }
            }, for: .valueChanged)
            install(slider, in: cell, title: "Opacity")
        case .speed:
            cell.contentConfiguration = nil
            let speeds = MediaCommentPreferences.BandSpeed.allCases
            let control = UISegmentedControl(items: speeds.map(Self.speedTitle))
            control.selectedSegmentIndex = speeds.firstIndex(of: preferences.bandSpeed) ?? 1
            control.isEnabled = preferences.showsReactionBand
            control.accessibilityLabel = "Speed"
            control.addAction(UIAction { [weak self] action in
                guard let control = action.sender as? UISegmentedControl else { return }
                let speed = speeds[control.selectedSegmentIndex]
                self?.store.update { $0.bandSpeed = speed }
            }, for: .valueChanged)
            install(control, in: cell, title: "Speed")
        case .mutedWords:
            var content = Self.label("Muted Words", symbol: "textformat.abc")
            content.secondaryText = preferences.mutedKeywords.isEmpty ? "None" : "\(preferences.mutedKeywords.count)"
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        case .mutedAccounts:
            var content = Self.label("Muted Accounts", symbol: "person.crop.circle.badge.minus")
            content.secondaryText = preferences.mutedHandles.isEmpty ? "None" : "\(preferences.mutedHandles.count)"
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        case .subtitlesSwitch:
            cell.contentConfiguration = Self.label("Show Subtitles", symbol: "captions.bubble")
            cell.accessories = [switchAccessory(isOn: preferences.showsSubtitles) { [weak self] isOn in
                self?.store.update { $0.showsSubtitles = isOn }
            }]
        }
    }

    private static let controlTag = 0x5E77

    /// The language the app is showing, in that language ("English").
    static func currentLanguageName(bundle: Bundle = .main) -> String {
        let code = bundle.preferredLocalizations.first ?? "en"
        return Locale(identifier: code).localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    private static func label(_ text: String, symbol: String) -> UIListContentConfiguration {
        var content = UIListContentConfiguration.valueCell()
        content.text = text
        content.image = UIImage(systemName: symbol)
        content.imageProperties.tintColor = .label
        return content
    }

    private func switchAccessory(isOn: Bool, onChange: @escaping (Bool) -> Void) -> UICellAccessory {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addAction(UIAction { action in
            guard let toggle = action.sender as? UISwitch else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        return .customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))
    }

    /// A caption over a full-width control, inside the row's margins.
    /// `title` nil when the section header already names the control.
    private func install(_ control: UIControl, in cell: UICollectionViewListCell, title: String?) {
        var arranged: [UIView] = [control]
        if let title {
            let caption = UILabel()
            caption.text = title
            caption.font = .preferredFont(forTextStyle: .body)
            caption.textColor = control.isEnabled ? .label : .secondaryLabel
            arranged.insert(caption, at: 0)
        }
        let stack = UIStackView(arrangedSubviews: arranged)
        stack.axis = .vertical
        stack.spacing = 8
        stack.tag = Self.controlTag
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12)
        ])
    }

    // MARK: - Editors

    private func mutedWordsEditor() -> MutedTermsViewController {
        MutedTermsViewController(configuration: .init(
            title: "Muted Words",
            placeholder: "Add a word or phrase",
            footer: "Matched anywhere in a comment, ignoring case.",
            normalize: MediaCommentPreferences.normalizedKeyword,
            display: { $0 },
            read: { [store] in store.preferences.mutedKeywords },
            write: { [store] terms in store.update { $0.mutedKeywords = terms } }
        ))
    }

    private func mutedAccountsEditor() -> MutedTermsViewController {
        MutedTermsViewController(configuration: .init(
            title: "Muted Accounts",
            placeholder: "Add a handle, like @maya",
            footer: "Their comments still exist; they just never ride on media for you.",
            normalize: MediaCommentPreferences.normalizedHandle,
            display: { "@\($0)" },
            read: { [store] in store.preferences.mutedHandles },
            write: { [store] terms in store.update { $0.mutedHandles = terms } }
        ))
    }
}

extension AppPreferencesViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .mutedWords, .mutedAccounts: true
        case .clearCache: cacheBytes.map { $0 > 0 } == true
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .mutedWords: navigationController?.pushViewController(mutedWordsEditor(), animated: true)
        case .mutedAccounts: navigationController?.pushViewController(mutedAccountsEditor(), animated: true)
        case .clearCache: confirmClearCache()
        default: break
        }
    }
}
