import CoreStorage
import DesignSystem
import UIKit

/// The screens of Settings → App and Device (#468): Playback and Sound,
/// Display, Emojis, Comments on Media and Language — one controller, one page
/// per section (#409, #410). Storage has its own screen
/// (`StorageSettingsViewController`, #899). Everything here is stored on the device
/// (`MediaPlaybackPreferencesStore`, `MediaCommentPreferencesStore`,
/// `AppearancePreference`, `MotionPreference`) and follows the iPhone, not
/// the profile.
final class AppPreferencesViewController: UIViewController {
    enum Section: Int, CaseIterable {
        case playback, players, sounds, appearance, care, motion, emojis, band, subtitles, commentsScreen, muted, language
    }

    enum Item: Hashable {
        case autoplay
        case backgroundPlay, pictureInPicture
        case playerPool
        case interfaceSounds, haptics
        case appearance, careMode, reduceMotion
        case animatedEmojis
        case bandSwitch, opacity, bandBackground, speed, dontCoverPeople
        case mutedWords, mutedAccounts
        case subtitlesSwitch
        case commentsBackdrop
        case appLanguage
    }

    /// The sections each App and Device page shows.
    static func sections(for page: SettingsSection) -> [Section] {
        switch page {
        case .playback: [.playback, .players, .sounds]
        case .display: [.appearance, .care, .motion]
        case .emojis: [.emojis]
        case .mediaComments: [.band, .subtitles, .commentsScreen, .muted]
        case .language: [.language]
        default: []
        }
    }

    private let page: SettingsSection

    private let store: MediaCommentPreferencesStore
    private let playback: MediaPlaybackPreferencesStore
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(
        page: SettingsSection,
        store: MediaCommentPreferencesStore = .standard,
        playback: MediaPlaybackPreferencesStore = .standard
    ) {
        self.page = page
        self.store = store
        self.playback = playback
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
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)
        configureDataSource()
        applySnapshot()
        // The footer quotes the iOS setting; keep it true when iOS changes.
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionSettingChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil
        )
        // Low Power Mode, followed, overrides several sections (#1808): their
        // notes and controls follow it live, on every page.
        NotificationCenter.default.addObserver(
            self, selector: #selector(lowPowerModeChanged),
            name: .lowPowerModeEffectDidChange, object: nil
        )
    }

    @objc private func lowPowerModeChanged() {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
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

    /// Low Power Mode, followed (#1808), overrides Reduce Motion, Autoplay and
    /// Animate Emojis while it lasts: their rows show what applies, and can't
    /// be changed until it ends or the switch is off.
    private var isSavingBattery: Bool { LowPowerMode.savesBattery }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The muted counts change on the pushed editors.
        if dataSource != nil { reconfigure([.mutedWords, .mutedAccounts]) }
    }

    // MARK: - Text

    private static func header(_ section: Section) -> String {
        switch section {
        case .appearance: "Appearance"
        case .care: "Care Mode"
        case .motion: "Motion"
        case .emojis: "Emojis"
        case .sounds: "Sounds and Haptics"
        case .language: "Language"
        case .playback: "Playback"
        case .players: "Video Players"
        case .band: "Reaction Band"
        case .muted: "Muted on Media"
        case .subtitles: "Subtitles"
        case .commentsScreen: "Comments Screen"
        }
    }

    static func footer(_ section: Section) -> String {
        switch section {
        case .appearance: "System follows the iPhone's Light and Dark setting."
        case .care: "Larger, bolder text everywhere in the app, and the reaction band switched off for a calmer screen. If your iPhone's own text size is larger, it is kept."
        case .sounds: "Interface sounds are the small pops and clicks of the app's own controls; a video's sound is set above. A phone on silent stays silent, and iOS's System Haptics setting still applies."
        case .motion:
            LowPowerMode.savesBattery
                ? Self.lowPowerModeNote
                : MotionPreference.appReducesMotion
                ? "Transitions and effects are kept to a minimum in the app."
                : "Off, the app follows iOS (Accessibility → Motion → Reduce Motion is currently "
                    + (UIAccessibility.isReduceMotionEnabled ? "on" : "off") + ")."
        case .emojis:
            LowPowerMode.savesBattery
                ? Self.lowPowerModeNote
                : "Emojis and stickers in comments, messages and posts play their animation. Off, they stay still."
        case .language: "The app is in English for now. When more languages arrive, you'll choose yours here and in iOS Settings."
        case .players: Self.playerPoolFooter
        case .playback:
            (LowPowerMode.savesBattery ? Self.lowPowerModeNote + " " : "")
                + "Autoplay applies to videos in grids, rails and previews; a post you open full screen always plays. A video that doesn't start on its own shows its first frame with a play mark; tap it to play. To use less cellular data, see Storage. "
                + Self.backgroundPlayNote
        case .band: "The short reactions that scroll over videos and photos. Background darkens the strip behind them; it darkens more while you scrub through them. Don't Cover People lets reactions pass behind the people in a playing video; it pauses in Low Power Mode or when your iPhone is hot."
        case .muted: "Comments with these words, or from these accounts, never appear in the reaction band or the subtitles. They still show in the comments."
        case .subtitles: "Comments shown as captions above the reaction band. Background is the shade behind each caption."
        case .commentsScreen: "How dark a video or photo gets behind its comments when you open them. Darker reads more easily; lighter keeps more of the post."
        }
    }

    static let backgroundPlayNote = "With Background Play on, a video you're listening to keeps playing when you leave the app or lock your iPhone, with controls on the Lock Screen. With Picture in Picture on, a playing video moves into a small window over your other apps, and videos play their sound even when your iPhone is on silent."

    /// What an overridden section says while Low Power Mode is followed.
    /// Under the player pool control (#702): what it trades, never a number.
    static let playerPoolFooter = "How many videos the app keeps ready to play. More makes scrolling smoother but uses more performance and battery; Less saves battery."

    /// The player pool's control (#702, #1133): a segmented control, like
    /// Autoplay's on the same page — Less / Normal / More, never a number.
    /// `onChange` hears the pool a segment picked.
    static func makePlayerPoolControl(
        selected: MediaPlaybackPreferences.PlayerPool,
        onChange: @escaping (MediaPlaybackPreferences.PlayerPool) -> Void
    ) -> UISegmentedControl {
        let options = MediaPlaybackPreferences.PlayerPool.allCases
        let control = UISegmentedControl(items: options.map(playerPoolTitle))
        control.selectedSegmentIndex = options.firstIndex(of: selected) ?? 1
        control.accessibilityLabel = "Video Players"
        control.addAction(UIAction { action in
            guard let control = action.sender as? UISegmentedControl,
                  options.indices.contains(control.selectedSegmentIndex) else { return }
            onChange(options[control.selectedSegmentIndex])
        }, for: .valueChanged)
        return control
    }

    static func playerPoolTitle(_ pool: MediaPlaybackPreferences.PlayerPool) -> String {
        switch pool {
        case .less: "Less"
        case .normal: "Normal"
        case .more: "More"
        }
    }

    static let lowPowerModeNote = "Low Power Mode is on, so this is set for you. Your own choice comes back when Low Power Mode ends, or when Save Battery in Low Power Mode is off in Settings → App and Device."

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

    static func items(in section: Section) -> [Item] {
        switch section {
        case .playback: [.autoplay, .backgroundPlay, .pictureInPicture]
        case .players: [.playerPool]
        case .sounds: [.interfaceSounds, .haptics]
        case .appearance: [.appearance]
        case .care: [.careMode]
        case .motion: [.reduceMotion]
        case .emojis: [.animatedEmojis]
        case .band: [.bandSwitch, .opacity, .bandBackground, .speed, .dontCoverPeople]
        case .muted: [.mutedWords, .mutedAccounts]
        case .subtitles: [.subtitlesSwitch]
        case .commentsScreen: [.commentsBackdrop]
        case .language: [.appLanguage]
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
            let picker = AppearancePickerView(selection: AppearancePreference.current)
            picker.addAction(UIAction { action in
                guard let picker = action.sender as? AppearancePickerView else { return }
                AppearancePreference.set(picker.selection)
            }, for: .valueChanged)
            install(picker, in: cell, title: nil)
        case .interfaceSounds:
            cell.contentConfiguration = Self.label("Interface Sounds", symbol: "speaker.wave.1")
            cell.accessories = [switchAccessory(isOn: InterfaceSoundPreference.isOn) { isOn in
                InterfaceSoundPreference.isOn = isOn
            }]
        case .haptics:
            cell.contentConfiguration = Self.label("Haptics", symbol: "iphone.radiowaves.left.and.right")
            cell.accessories = [switchAccessory(isOn: HapticPreference.isOn) { isOn in
                HapticPreference.isOn = isOn
            }]
        case .careMode:
            cell.contentConfiguration = Self.label("Care Mode", symbol: "textformat.size")
            cell.accessories = [switchAccessory(isOn: CareModePreference.isOn) { [weak self] isOn in
                guard let self else { return }
                Self.applyCareMode(isOn, store: store)
            }]
        case .reduceMotion:
            cell.contentConfiguration = Self.label("Reduce Motion", symbol: "figure.walk.motion")
            cell.accessories = [switchAccessory(
                isOn: MotionPreference.appReducesMotion || isSavingBattery, isEnabled: !isSavingBattery
            ) { isOn in
                MotionPreference.appReducesMotion = isOn
            }]
        case .animatedEmojis:
            cell.contentConfiguration = Self.label("Animate Emojis", symbol: "face.smiling")
            cell.accessories = [switchAccessory(
                isOn: EmoteAnimationPreference.animatesEmotes, isEnabled: !isSavingBattery
            ) { isOn in
                EmoteAnimationPreference.isOn = isOn
            }]
        case .appLanguage:
            var content = Self.label("App Language", symbol: "globe")
            content.secondaryText = Self.currentLanguageName()
            cell.contentConfiguration = content
        case .autoplay:
            cell.contentConfiguration = nil
            let options = MediaPlaybackPreferences.Autoplay.allCases
            let control = UISegmentedControl(items: options.map(Self.autoplayTitle))
            let shown = isSavingBattery ? .never : playback.preferences.autoplay
            control.selectedSegmentIndex = options.firstIndex(of: shown) ?? 0
            control.isEnabled = !isSavingBattery
            control.accessibilityLabel = "Autoplay"
            control.addAction(UIAction { [weak self] action in
                guard let control = action.sender as? UISegmentedControl else { return }
                let choice = options[control.selectedSegmentIndex]
                self?.playback.update { $0.autoplay = choice }
            }, for: .valueChanged)
            install(control, in: cell, title: "Autoplay Videos")
        case .backgroundPlay:
            cell.contentConfiguration = Self.label("Background Play", symbol: "lock.iphone")
            cell.accessories = [switchAccessory(isOn: playback.preferences.backgroundPlay) { [weak self] isOn in
                self?.playback.update { $0.backgroundPlay = isOn }
            }]
        case .pictureInPicture:
            cell.contentConfiguration = Self.label("Picture in Picture", symbol: "pip")
            cell.accessories = [switchAccessory(isOn: playback.preferences.pictureInPicture) { [weak self] isOn in
                self?.playback.update { $0.pictureInPicture = isOn }
            }]
        case .playerPool:
            cell.contentConfiguration = nil
            let control = Self.makePlayerPoolControl(selected: playback.preferences.playerPool) { [weak self] pool in
                guard self?.playback.preferences.playerPool != pool else { return }
                self?.playback.update { $0.playerPool = pool }
            }
            // The section's header already says "Video Players": no caption.
            install(control, in: cell, title: nil)
        case .bandSwitch:
            cell.contentConfiguration = Self.label("Show Reaction Band", symbol: "text.bubble")
            cell.accessories = [switchAccessory(isOn: preferences.showsReactionBand) { [weak self] isOn in
                self?.store.update { $0.showsReactionBand = isOn }
                self?.reconfigure([.opacity, .bandBackground, .speed, .dontCoverPeople])
            }]
        case .dontCoverPeople:
            cell.contentConfiguration = Self.label("Don't Cover People", symbol: "person.crop.rectangle")
            cell.accessories = [switchAccessory(
                isOn: preferences.avoidsPeople, isEnabled: preferences.showsReactionBand
            ) { [weak self] isOn in
                self?.store.update { $0.avoidsPeople = isOn }
            }]
        case .opacity:
            installSlider(
                in: cell, title: "Opacity", range: MediaCommentPreferences.opacityRange, value: preferences.bandOpacity,
                isEnabled: preferences.showsReactionBand, symbols: ("circle.dotted", "circle.fill")
            ) { $0.bandOpacity = $1 }
        case .bandBackground:
            installSlider(
                in: cell, title: "Background", range: MediaCommentPreferences.bandBackgroundRange,
                value: preferences.bandBackgroundOpacity, isEnabled: preferences.showsReactionBand,
                symbols: ("checkerboard.rectangle", "rectangle.fill")
            ) { $0.bandBackgroundOpacity = $1 }
        case .commentsBackdrop:
            installSlider(
                in: cell, title: "Background", range: MediaCommentPreferences.commentsBackdropRange,
                value: preferences.commentsBackdropOpacity, isEnabled: true,
                symbols: ("photo", "rectangle.fill")
            ) { $0.commentsBackdropOpacity = $1 }
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

    static let careModeBandWasOnKey = "careMode.reactionBandWasOn"

    /// Care Mode on: larger, bolder text, and the reaction band off for a
    /// calmer screen. Care Mode off: the band comes back if Care Mode is what
    /// switched it off — a band the viewer had already turned off stays off.
    static func applyCareMode(_ isOn: Bool, store: MediaCommentPreferencesStore, defaults: UserDefaults = .standard) {
        if isOn {
            let bandWasOn = store.preferences.showsReactionBand
            defaults.set(bandWasOn, forKey: careModeBandWasOnKey)
            store.update { $0.showsReactionBand = false }
        } else if defaults.bool(forKey: careModeBandWasOnKey) {
            store.update { $0.showsReactionBand = true }
            defaults.removeObject(forKey: careModeBandWasOnKey)
        }
        CareModePreference.set(isOn)
    }

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

    private func switchAccessory(isOn: Bool, isEnabled: Bool = true, onChange: @escaping (Bool) -> Void) -> UICellAccessory {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.isEnabled = isEnabled
        toggle.addAction(UIAction { action in
            guard let toggle = action.sender as? UISwitch else { return }
            onChange(toggle.isOn)
        }, for: .valueChanged)
        return .customView(configuration: .init(customView: toggle, placement: .trailing(displayed: .always)))
    }

    /// A captioned slider writing one opacity of the comment preferences.
    private func installSlider(
        in cell: UICollectionViewListCell,
        title: String,
        range: ClosedRange<Double>,
        value: Double,
        isEnabled: Bool,
        symbols: (min: String, max: String),
        write: @escaping (inout MediaCommentPreferences, Double) -> Void
    ) {
        cell.contentConfiguration = nil
        let slider = UISlider()
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)
        slider.minimumValueImage = UIImage(systemName: symbols.min)
        slider.maximumValueImage = UIImage(systemName: symbols.max)
        slider.isEnabled = isEnabled
        slider.accessibilityLabel = title
        slider.addAction(UIAction { [weak self] action in
            guard let slider = action.sender as? UISlider else { return }
            self?.store.update { write(&$0, Double(slider.value)) }
        }, for: .valueChanged)
        install(slider, in: cell, title: title)
    }

    /// A caption over a full-width control, inside the row's margins.
    /// `title` nil when the section header already names the control.
    private func install(_ control: UIControl, in cell: UICollectionViewListCell, title: String?) {
        var arranged: [UIView] = [control]
        if let title {
            let caption = UILabel()
            caption.text = title
            caption.font = .appFont(forTextStyle: .body)
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
        default: false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .mutedWords: navigationController?.pushViewController(mutedWordsEditor(), animated: true)
        case .mutedAccounts: navigationController?.pushViewController(mutedAccountsEditor(), animated: true)
        default: break
        }
    }
}

// MARK: - How it is left (#1144)

extension AppPreferencesViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
