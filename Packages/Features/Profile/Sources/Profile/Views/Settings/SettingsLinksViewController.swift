import DesignSystem
import SafariServices
import UIKit

/// Settings → Help and Support, and Settings → Legal and About (#391): rows
/// that open a web page in place, read from `SettingsLinks`, plus plain
/// information rows (the app version).
///
/// A row whose page does not exist yet says "Coming Soon" and opens nothing.
/// It stays on screen anyway: App Review and the DSA ask where these things
/// are, and the honest answer "not published yet" beats a missing row.
final class SettingsLinksViewController: UIViewController {
    struct Row: Hashable {
        let title: String
        let symbolName: String
        let url: URL?
        /// An information row: shows `value`, opens nothing.
        let value: String?

        static func link(_ title: String, symbol: String, url: URL?) -> Row {
            Row(title: title, symbolName: symbol, url: url, value: nil)
        }

        static func info(_ title: String, symbol: String, value: String) -> Row {
            Row(title: title, symbolName: symbol, url: nil, value: value)
        }

        var isComingSoon: Bool { value == nil && url == nil }
    }

    private let rows: [Row]
    private let footer: String?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Row>!

    init(title: String, rows: [Row], footer: String?) {
        self.rows = rows
        self.footer = footer
        super.init(nibName: nil, bundle: nil)
        self.title = title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Help and Support.
    static func help(links: SettingsLinks) -> SettingsLinksViewController {
        SettingsLinksViewController(
            title: SettingsSection.help.title,
            rows: [
                .link("Help Center", symbol: "questionmark.circle", url: links.helpCenter),
                .link("Contact Support", symbol: "envelope", url: links.contactSupport),
                .link("Report a Problem", symbol: "ant", url: links.reportProblem)
            ],
            footer: nil
        )
    }

    /// Legal and About.
    static func legal(links: SettingsLinks, version: String) -> SettingsLinksViewController {
        SettingsLinksViewController(
            title: SettingsSection.legal.title,
            rows: [
                .link("Terms of Service", symbol: "doc.text", url: links.termsOfService),
                .link("Privacy Policy", symbol: "hand.raised", url: links.privacyPolicy),
                .link("Community Guidelines", symbol: "person.3", url: links.communityGuidelines),
                .link("Legal Notice", symbol: "building.columns", url: links.legalNotice),
                .link("Copyright Report", symbol: "c.circle", url: links.copyrightReport),
                .link("Cookie and SDK Policy", symbol: "list.bullet.rectangle", url: links.cookiePolicy),
                .link("Transparency Reports", symbol: "chart.bar.doc.horizontal", url: links.transparencyReports),
                .info("Version", symbol: "info.circle", value: version)
            ],
            footer: nil
        )
    }

    /// "1.0 (42)" from the bundle.
    static func appVersion(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = rows.contains(where: \.isComingSoon) || footer != nil ? .supplementary : .none
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.delegate = self
        view.addSubview(collectionView)

        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { cell, _, row in
            var content = UIListContentConfiguration.valueCell()
            content.text = row.title
            content.image = UIImage(systemName: row.symbolName)
            content.imageProperties.tintColor = row.isComingSoon ? .secondaryLabel : .label
            if row.isComingSoon {
                content.textProperties.color = .secondaryLabel
                content.secondaryText = "Coming Soon"
                cell.accessories = []
            } else if let value = row.value {
                content.secondaryText = value
                cell.accessories = []
            } else {
                cell.accessories = [.disclosureIndicator()]
            }
            cell.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Row>(collectionView: collectionView) { collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: row)
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.footer()
            content.text = footer ?? (rows.contains(where: \.isComingSoon) ? "Pages marked Coming Soon aren't published yet." : nil)
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footerRegistration, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(rows)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func open(_ url: URL) {
        if url.scheme == "http" || url.scheme == "https" {
            present(SFSafariViewController(url: url), animated: true)
        } else {
            UIApplication.shared.open(url)
        }
    }
}

extension SettingsLinksViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        dataSource.itemIdentifier(for: indexPath)?.url != nil
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        if let url = dataSource.itemIdentifier(for: indexPath)?.url { open(url) }
    }
}
