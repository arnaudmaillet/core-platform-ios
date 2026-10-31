import DesignSystem
import UIKit

/// The third-party software the app ships with, and the licences it ships
/// under (#1128): Settings → Legal and About → Acknowledgements.
///
/// Read from `Resources/Acknowledgements.json`, written from each package's
/// own LICENSE (and NOTICE) file: Phosphor Icons (MIT, the art behind the
/// app's custom glyphs — `dev/symbols`), GRDB (MIT) and the Apache 2.0
/// packages, whose licence text is stored once.
struct Acknowledgements: Decodable, Equatable {
    struct Package: Decodable, Hashable {
        let name: String
        let license: String
        let url: String
        /// What the app uses it for, in a few words.
        let use: String
        /// The licence's full text when it is the package's own (MIT).
        let text: String?
        /// The package's NOTICE, which Apache 2.0 asks to be reproduced.
        let notice: String?
    }

    /// The Apache License 2.0, once for every package under it.
    let apache2: String
    let packages: [Package]

    /// The bundled list; nil only if the resource is missing.
    static let bundled: Acknowledgements? = {
        guard let url = Bundle.module.url(forResource: "Acknowledgements", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Acknowledgements.self, from: data)
    }()

    /// The text a package's page shows: its notice, then its licence, each
    /// paragraph reflowed to the screen's width.
    func licenseText(for package: Package) -> String {
        var parts: [String] = [package.url]
        if let notice = package.notice { parts.append(Self.reflowed(notice)) }
        parts.append(Self.reflowed(package.text ?? apache2))
        return parts.joined(separator: "\n\n")
    }

    /// A licence file is hard-wrapped at 80 columns, which wraps raggedly a
    /// second time on a phone: each paragraph's lines are joined into one.
    static func reflowed(_ text: String) -> String {
        text.components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

/// The list: one row per package, its licence beside it; a row opens the text.
final class AcknowledgementsViewController: UIViewController {
    nonisolated static let title = "Acknowledgements"

    private let acknowledgements: Acknowledgements
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Acknowledgements.Package>!

    init(acknowledgements: Acknowledgements) {
        self.acknowledgements = acknowledgements
        super.init(nibName: nil, bundle: nil)
        title = Self.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        collectionView = UICollectionView(
            frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Acknowledgements.Package> { cell, _, package in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = package.name
            content.secondaryText = "\(package.license) · \(package.use)"
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, package in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: package)
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = "This app is built with the open-source software above. Thank you to its authors."
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Acknowledgements.Package>()
        snapshot.appendSections([0])
        snapshot.appendItems(acknowledgements.packages)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}

extension AcknowledgementsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let package = dataSource.itemIdentifier(for: indexPath) else { return }
        navigationController?.pushViewController(
            LicenseTextViewController(title: package.name, text: acknowledgements.licenseText(for: package)),
            animated: true
        )
    }
}

/// One package's licence, as plain selectable text.
final class LicenseTextViewController: UIViewController {
    private let text: String

    init(title: String, text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
        self.title = title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground
        let textView = UITextView(frame: view.bounds)
        textView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        textView.isEditable = false
        textView.dataDetectorTypes = .link
        textView.font = .appFont(forTextStyle: .footnote)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 32, right: 12)
        textView.text = text
        view.addSubview(textView)
    }
}

// MARK: - How it is left (#1144)

extension AcknowledgementsViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}

// MARK: - How it is left (#1144)

extension LicenseTextViewController: StackScreen {
    var leaving: ScreenLeaving { .nativeBack }
}
