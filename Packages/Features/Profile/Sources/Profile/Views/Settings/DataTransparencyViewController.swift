import AVFoundation
import DesignSystem
import Photos
import UIKit

/// Settings → Privacy → Your Data and Permissions (#414): what the app
/// collects (read from its privacy manifest), who else receives it (nobody:
/// no third-party SDK collects data), and the iOS permissions it uses with
/// their current state.
///
/// The PIPL-style transparency screens of Douyin and WeChat, kept honest by
/// construction: the collected-data list IS the App Store manifest.
final class DataTransparencyViewController: UIViewController {
    enum PermissionState: Equatable {
        case allowed, limited, denied, notAsked

        var label: String {
            switch self {
            case .allowed: "Allowed"
            case .limited: "Limited"
            case .denied: "Not allowed"
            case .notAsked: "Not asked yet"
            }
        }
    }

    struct Permission: Hashable {
        let title: String
        let symbolName: String
        let purpose: String
        let state: PermissionState
    }

    private enum Section: Int, CaseIterable {
        case collected, thirdParties, permissions
    }

    private enum Item: Hashable {
        case collected(type: String, title: String, detail: String)
        case noManifest
        case thirdParty(String)
        case permission(Permission)
        case openSettings
    }

    /// Third-party code in the app and what it does. None of it collects
    /// personal data; keep in step with the packages the app links.
    static let thirdPartyLibraries = [
        "Connect and SwiftProtobuf — talking to our servers",
        "SwiftNIO (Apple) — networking",
        "Lottie (Airbnb) — animations"
    ]

    private let manifest: PrivacyManifest?
    private let permissions: @MainActor () -> [Permission]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    init(manifest: PrivacyManifest? = .load(), permissions: @escaping @MainActor () -> [Permission] = DataTransparencyViewController.currentPermissions) {
        self.manifest = manifest
        self.permissions = permissions
        super.init(nibName: nil, bundle: nil)
        title = "Your Data and Permissions"
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

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
        // Permissions change in iOS Settings while this screen waits behind it.
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPermissions),
            name: UIApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func refreshPermissions() {
        applySnapshot()
    }

    // MARK: - Permissions

    static func currentPermissions() -> [Permission] {
        let info = Bundle.main.infoDictionary ?? [:]
        func purpose(_ key: String) -> String { info[key] as? String ?? "" }
        func capture(_ type: AVMediaType) -> PermissionState {
            switch AVCaptureDevice.authorizationStatus(for: type) {
            case .authorized: .allowed
            case .denied, .restricted: .denied
            default: .notAsked
            }
        }
        func photos(_ level: PHAccessLevel) -> PermissionState {
            switch PHPhotoLibrary.authorizationStatus(for: level) {
            case .authorized: .allowed
            case .limited: .limited
            case .denied, .restricted: .denied
            default: .notAsked
            }
        }
        return [
            Permission(title: "Camera", symbolName: "camera", purpose: purpose("NSCameraUsageDescription"), state: capture(.video)),
            Permission(title: "Microphone", symbolName: "mic", purpose: purpose("NSMicrophoneUsageDescription"), state: capture(.audio)),
            Permission(title: "Photos", symbolName: "photo.on.rectangle", purpose: purpose("NSPhotoLibraryUsageDescription"), state: photos(.readWrite)),
            Permission(title: "Save to Photos", symbolName: "square.and.arrow.down", purpose: purpose("NSPhotoLibraryAddUsageDescription"), state: photos(.addOnly))
        ]
    }

    // MARK: - List

    private static func header(_ section: Section) -> String {
        switch section {
        case .collected: "Data We Collect"
        case .thirdParties: "Shared With Third Parties"
        case .permissions: "iOS Permissions"
        }
    }

    private func footer(_ section: Section) -> String? {
        switch section {
        case .collected:
            manifest?.tracks == true
                ? "Some of this is used to track you across other companies' apps."
                : "All of it is linked to your account, used only to run the app, and never used to track you across other companies' apps."
        case .thirdParties:
            "None of these libraries collects or receives your personal data."
        case .permissions:
            "Change these in iOS Settings at any time."
        }
    }

    static func detail(for data: PrivacyManifest.CollectedData) -> String {
        var parts = [data.purposeText]
        if !data.isLinkedToYou { parts.append("Not linked to you") }
        if data.isUsedForTracking { parts.append("Used for tracking") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            cell.accessories = []
            switch item {
            case .collected(_, let title, let detail):
                var content = UIListContentConfiguration.subtitleCell()
                content.text = title
                content.secondaryText = detail
                content.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = content
            case .noManifest:
                var content = UIListContentConfiguration.cell()
                content.text = "This build ships no privacy manifest."
                content.textProperties.color = .secondaryLabel
                cell.contentConfiguration = content
            case .thirdParty(let text):
                var content = UIListContentConfiguration.cell()
                content.text = text
                content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
                cell.contentConfiguration = content
            case .permission(let permission):
                var content = UIListContentConfiguration.subtitleCell()
                content.text = permission.title
                content.secondaryText = permission.purpose
                content.secondaryTextProperties.color = .secondaryLabel
                content.image = UIImage(systemName: permission.symbolName)
                content.imageProperties.tintColor = .label
                cell.contentConfiguration = content
                let state = UILabel()
                state.text = permission.state.label
                state.font = .preferredFont(forTextStyle: .subheadline)
                state.textColor = permission.state == .allowed ? .systemGreen : .secondaryLabel
                cell.accessories = [.customView(configuration: .init(customView: state, placement: .trailing(displayed: .always)))]
            case .openSettings:
                var content = UIListContentConfiguration.cell()
                content.text = "Open iOS Settings"
                content.textProperties.color = .tintColor
                cell.contentConfiguration = content
            }
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
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section).flatMap { self?.footer($0) }
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
        snapshot.appendSections(Section.allCases)
        if let manifest {
            snapshot.appendItems(manifest.collectedData.map {
                .collected(type: $0.type, title: $0.title, detail: Self.detail(for: $0))
            }, toSection: .collected)
        } else {
            snapshot.appendItems([.noManifest], toSection: .collected)
        }
        snapshot.appendItems(Self.thirdPartyLibraries.map(Item.thirdParty), toSection: .thirdParties)
        snapshot.appendItems(permissions().map(Item.permission) + [.openSettings], toSection: .permissions)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension DataTransparencyViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath) == .openSettings
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if dataSource.itemIdentifier(for: indexPath) == .openSettings,
           let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
