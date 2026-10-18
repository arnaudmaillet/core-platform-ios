import DesignSystem
import MediaCore
import PostGrid
import UIKit

/// Edit Profile → Video banner (#944): the viewer's own video posts, three
/// to a row; a tap makes that post's loop the banner. "Remove" takes the
/// banner back to none. The owner, 2026-10-18: the video comes from your own
/// posts — there is no separate upload.
final class VideoBannerPickerViewController: UIViewController {
    private let load: () async throws -> [GalleryPost]
    private let imagePipeline: ImagePipeline
    /// The loop on the banner now, to mark its post.
    private let current: URL?
    private let onPick: (GalleryPost?) -> Void

    private(set) var posts: [GalleryPost] = []
    private var collectionView: UICollectionView!
    /// The branded loader (#1329), never a stock spinner (`StockSpinnerGuardTests`).
    private let spinner = AppLoaderView(size: .medium)
    private let emptyLabel = UILabel()

    init(
        load: @escaping () async throws -> [GalleryPost], imagePipeline: ImagePipeline, current: URL?,
        onPick: @escaping (GalleryPost?) -> Void
    ) {
        self.load = load
        self.imagePipeline = imagePipeline
        self.current = current
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Video Banner"
        view.backgroundColor = .systemGroupedBackground
        if current != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Remove", primaryAction: UIAction { [weak self] _ in self?.pick(nil) }
            )
        }
        configureCollectionView()
        configureStates()
        reload()
    }

    private func configureCollectionView() {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / 3), heightDimension: .fractionalHeight(1)))
        item.contentInsets = NSDirectionalEdgeInsets(top: 1, leading: 1, bottom: 1, trailing: 1)
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(4 / 9)),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        let header = NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(44)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top
        )
        section.boundarySupplementaryItems = [header]
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout(section: section))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(VideoBannerTileCell.self, forCellWithReuseIdentifier: VideoBannerTileCell.reuseID)
        collectionView.register(
            VideoBannerHintView.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: VideoBannerHintView.reuseID
        )
        view.addSubview(collectionView)
    }

    private func configureStates() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .appFont(forTextStyle: .body)
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.isHidden = true
        view.addSubview(spinner)
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -24),
        ])
    }

    private func reload() {
        spinner.startAnimating()
        Task { [weak self] in
            guard let self else { return }
            do {
                let posts = try await self.load()
                self.spinner.stopAnimating()
                self.show(posts)
            } catch {
                self.spinner.stopAnimating()
                self.showEmpty("Couldn't load your videos.")
            }
        }
    }

    /// Internal for tests.
    func show(_ posts: [GalleryPost]) {
        self.posts = posts
        if posts.isEmpty {
            showEmpty("No video posts yet.\nPost a video, then pick it here.")
        } else {
            emptyLabel.isHidden = true
        }
        collectionView.reloadData()
    }

    private func showEmpty(_ message: String) {
        emptyLabel.text = message
        emptyLabel.isHidden = false
    }

    private func pick(_ post: GalleryPost?) {
        HapticSelection().selectionChanged()
        onPick(post)
        navigationController?.popViewController(animated: true)
    }
}

extension VideoBannerPickerViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { posts.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: VideoBannerTileCell.reuseID, for: indexPath)
        if let tile = cell as? VideoBannerTileCell {
            let post = posts[indexPath.item]
            tile.configure(post, pipeline: imagePipeline, isCurrent: current != nil && post.videoURL == current)
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath
    ) -> UICollectionReusableView {
        collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: VideoBannerHintView.reuseID, for: indexPath)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        pick(posts[indexPath.item])
    }
}

/// One video post: its cover, a play mark, a check on the banner's own.
private final class VideoBannerTileCell: UICollectionViewCell {
    static let reuseID = "VideoBannerTileCell"
    private let cover = UIImageView()
    private let mark = UIImageView(image: UIImage(systemName: "play.fill"))
    private let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
    private var url: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true
        contentView.backgroundColor = .secondarySystemFill
        cover.contentMode = .scaleAspectFill
        mark.tintColor = .white
        mark.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        check.tintColor = .white
        check.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        for view in [cover, mark, check] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: contentView.topAnchor),
            cover.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mark.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            mark.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            check.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            check.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ post: GalleryPost, pipeline: ImagePipeline, isCurrent: Bool) {
        check.isHidden = !isCurrent
        accessibilityLabel = post.caption.isEmpty ? "Video" : post.caption
        accessibilityTraits = isCurrent ? [.button, .selected] : .button
        let url = post.thumbnailURL
        guard url != self.url else { return }
        self.url = url
        cover.image = nil
        guard let url else { return }
        Task { [weak self] in
            let image = try? await pipeline.image(for: url, size: .px256)
            guard let self, self.url == url else { return }
            self.cover.image = image
        }
    }
}

/// What the banner is, above the posts.
private final class VideoBannerHintView: UICollectionReusableView {
    static let reuseID = "VideoBannerHintView"

    override init(frame: CGRect) {
        super.init(frame: frame)
        let label = UILabel()
        label.text = "Pick one of your videos. It plays muted at the top of your profile, and shows as a still under Low Power Mode or Reduce Motion."
        label.numberOfLines = 0
        label.font = .appFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
