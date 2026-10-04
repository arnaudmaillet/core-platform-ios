import DesignSystem
import UIKit

/// The child of a settings section with no live row yet: the section's
/// planned contents as a plain, non-selectable list, and a footer that says
/// in so many words that none of it works yet.
///
/// Deliberately not a set of disabled toggles. A switch that looks real but
/// does nothing reads as a broken control, or worse as a setting that took;
/// a list of names says only what is coming.
final class SettingsComingSoonViewController: UIViewController {
    private let section: SettingsSection
    private var collectionView: UICollectionView!

    init(section: SettingsSection) {
        self.section = section
        super.init(nibName: nil, bundle: nil)
        title = section.title
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemGroupedBackground

        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.footerMode = .supplementary
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.prefersSoftTopEdge()
        collectionView.dataSource = self
        collectionView.allowsSelection = false
        collectionView.register(UICollectionViewListCell.self, forCellWithReuseIdentifier: "row")
        collectionView.register(
            UICollectionViewListCell.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: "header"
        )
        collectionView.register(
            UICollectionViewListCell.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
            withReuseIdentifier: "footer"
        )
        view.addSubview(collectionView)
    }
}

extension SettingsComingSoonViewController: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        self.section.plannedItems.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "row", for: indexPath) as! UICollectionViewListCell
        var content = UIListContentConfiguration.cell()
        content.text = section.plannedItems[indexPath.item]
        content.textProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        let isHeader = kind == UICollectionView.elementKindSectionHeader
        let view = collectionView.dequeueReusableSupplementaryView(
            ofKind: kind,
            withReuseIdentifier: isHeader ? "header" : "footer",
            for: indexPath
        ) as! UICollectionViewListCell
        var content = isHeader ? UIListContentConfiguration.header() : UIListContentConfiguration.footer()
        content.text = isHeader ? "Coming Soon" : "These settings aren't available in this version yet."
        view.contentConfiguration = content
        return view
    }
}
