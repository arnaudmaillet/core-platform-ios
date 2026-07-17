import MediaCore
import UIKit

/// One format page of the gallery pager, in the fixed shape its format owns:
/// an asymmetric media mosaic (Media) or a 1-column timeline of full-width
/// rows (Activity, Short). Layouts are format-bound, so the page's shape is
/// set at init and never morphs — moving between shapes IS the pager's
/// horizontal swipe.
///
/// Deliberately NOT a scrolling collection view: the outer scroll view owns
/// all vertical motion (nested vertical scrolling would fight the stretchy
/// banner and the pull-to-refresh), so this view self-sizes to its full
/// content and lets the outer surface scroll it. The cost is no cell reuse;
/// acceptable at today's one-page fetch, revisit alongside pagination.
final class ProfileGalleryGridView: UIView {
    /// The page's fixed shape.
    enum Style {
        /// The asymmetric media mosaic, full bleed.
        case grid
        /// 1-column full-width self-sizing rows with reading margins.
        case list
    }

    /// The mosaic's hairline gutter between bricks.
    private static let gutter: CGFloat = 1.5

    var onItemTapped: ((GalleryPost) -> Void)?

    private let imagePipeline: ImagePipeline
    private let style: Style
    private var posts: [GalleryPost] = []

    private let collectionView: SelfSizingCollectionView
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    /// The Media mosaic: a repeating 8-item pattern on a 3-column unit grid,
    /// mixing 1×1 squares with 1×2 portrait and 2×1 landscape blocks. Two
    /// mirrored halves keep the rhythm organic instead of stripey:
    ///
    ///     ┌───┐┌───────┐      ┌───────┐┌───┐
    ///     │ 0 ││   1   │      │ 4 │ 5 ││   │
    ///     │   │├───┬───┤      ├───┴───┤│ 7 │
    ///     │   ││ 2 │ 3 │      │   6   ││   │
    ///     └───┘└───┴───┘      └───────┘└───┘
    ///
    /// Gutters come from uniform per-item insets (half the gutter each side),
    /// the one recipe that stays even across nested groups; the outer edges
    /// bleed the same half-gutter, invisible against full-bleed margins.
    private static func gridLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let inset = NSDirectionalEdgeInsets(
                top: gutter / 2, leading: gutter / 2, bottom: gutter / 2, trailing: gutter / 2
            )
            func item(width: CGFloat, height: CGFloat) -> NSCollectionLayoutItem {
                let item = NSCollectionLayoutItem(layoutSize: .init(
                    widthDimension: .fractionalWidth(width),
                    heightDimension: .fractionalHeight(height)
                ))
                item.contentInsets = inset
                return item
            }

            // Half A: portrait column leading, landscape + square pair trailing.
            let pairA = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(0.5)),
                subitems: [item(width: 0.5, height: 1), item(width: 0.5, height: 1)]
            )
            let stackA = NSCollectionLayoutGroup.vertical(
                layoutSize: .init(widthDimension: .fractionalWidth(2.0 / 3.0), heightDimension: .fractionalHeight(1)),
                subitems: [item(width: 1, height: 0.5), pairA]
            )
            let halfA = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(2.0 / 3.0)),
                subitems: [item(width: 1.0 / 3.0, height: 1), stackA]
            )

            // Half B: the mirror — square pair + landscape leading, portrait trailing.
            let pairB = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(0.5)),
                subitems: [item(width: 0.5, height: 1), item(width: 0.5, height: 1)]
            )
            let stackB = NSCollectionLayoutGroup.vertical(
                layoutSize: .init(widthDimension: .fractionalWidth(2.0 / 3.0), heightDimension: .fractionalHeight(1)),
                subitems: [pairB, item(width: 1, height: 0.5)]
            )
            let halfB = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(2.0 / 3.0)),
                subitems: [stackB, item(width: 1.0 / 3.0, height: 1)]
            )

            let pattern = NSCollectionLayoutGroup.vertical(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalWidth(4.0 / 3.0)),
                subitems: [halfA, halfB]
            )
            return NSCollectionLayoutSection(group: pattern)
        }
    }

    /// The 1-column timeline shape (Activity, Short): rows self-size to
    /// their content, with reading margins instead of the grid's full bleed.
    private static func listLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, _ in
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(88)
            ))
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: .init(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(88)
                ),
                subitems: [item]
            )
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 10
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
            return section
        }
    }

    init(imagePipeline: ImagePipeline, style: Style) {
        self.imagePipeline = imagePipeline
        self.style = style
        collectionView = SelfSizingCollectionView(
            frame: .zero,
            collectionViewLayout: style == .grid ? Self.gridLayout() : Self.listLayout()
        )
        super.init(frame: .zero)

        collectionView.isScrollEnabled = false
        collectionView.backgroundColor = .clear
        collectionView.register(GalleryTileCell.self, forCellWithReuseIdentifier: GalleryTileCell.reuseID)
        collectionView.register(GalleryListRowCell.self, forCellWithReuseIdentifier: GalleryListRowCell.reuseID)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.pin(to: self)

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.constrain(in: self) { parent in
            statusLabel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 48)
            statusLabel.leadingAnchor.constraint(equalTo: parent.layoutMarginsGuide.leadingAnchor)
            statusLabel.trailingAnchor.constraint(equalTo: parent.layoutMarginsGuide.trailingAnchor)
        }

        spinner.hidesWhenStopped = true
        spinner.constrain(in: self) { parent in
            spinner.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            spinner.topAnchor.constraint(equalTo: parent.topAnchor, constant: 56)
        }

        // Statuses (loading / empty / failed) need visible height even though
        // the collection view is empty then; the grid provides a floor and
        // grows past it with content.
        let floor = heightAnchor.constraint(greaterThanOrEqualToConstant: 140)
        floor.priority = .defaultHigh
        floor.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func render(_ state: ProfileViewModel.GalleryPageState) {
        switch state {
        case .loading:
            spinner.startAnimating()
            statusLabel.isHidden = true
            apply([])
        case .content(let posts):
            spinner.stopAnimating()
            statusLabel.isHidden = true
            apply(posts)
        case .empty(let message), .failed(let message):
            spinner.stopAnimating()
            statusLabel.text = message
            statusLabel.isHidden = false
            apply([])
        }
    }

    private func apply(_ posts: [GalleryPost]) {
        guard self.posts != posts else { return }
        self.posts = posts
        collectionView.reloadData()
        collectionView.invalidateIntrinsicContentSize()
    }
}

// MARK: - Data source / delegate

extension ProfileGalleryGridView: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        posts.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let post = posts[indexPath.item]
        switch style {
        case .list:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: GalleryListRowCell.reuseID, for: indexPath
            ) as! GalleryListRowCell
            cell.configure(with: post, imagePipeline: imagePipeline)
            return cell
        case .grid:
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: GalleryTileCell.reuseID, for: indexPath
            ) as! GalleryTileCell
            cell.configure(with: post, imagePipeline: imagePipeline)
            return cell
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onItemTapped?(posts[indexPath.item])
    }
}

// MARK: - Metric label

/// One icon+count pair of a metadata line ("♡ 1.2K"). The icon tracks the
/// label's font size through a symbol configuration, so both cell styles
/// (footnote rows, caption2 tile overlays) stay optically matched. Hidden
/// whenever the counter has no value — absence, not a asserted zero.
private final class MetricLabel: UIView {
    private let label = UILabel()

    init(symbol: String, font: UIFont, color: UIColor, shadowed: Bool = false) {
        super.init(frame: .zero)
        let icon = UIImageView(image: UIImage(systemName: symbol))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(font: font, scale: .small)
        icon.tintColor = color
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)

        label.font = font
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4
        row.pin(to: self)

        if shadowed {
            // Overlay context (media tiles): legibility over any brightness
            // via a soft shadow, never a scrim — the thumbnail stays clean.
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.55
            layer.shadowRadius = 3
            layer.shadowOffset = .zero
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(_ value: Int64?) {
        isHidden = value == nil
        label.text = value.map(PostMetadata.count)
    }
}

// MARK: - Timeline row

/// One full-width row of the Activity/Short timelines: the caption with
/// reading padding on a soft card, plus — when the post carries media — a
/// rounded full-width preview under the text (play badge for videos), and a
/// quiet metadata line closing the card: reactions, comments, views on the
/// leading side, the post's compact age trailing. Short pages never have
/// media, so their rows are text + metadata.
private final class GalleryListRowCell: UICollectionViewCell {
    static let reuseID = "GalleryListRowCell"

    private let card = UIView()
    private let captionLabel = UILabel()
    private let mediaView = UIImageView()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private static let metaFont = UIFont.preferredFont(forTextStyle: .footnote)
    private let reactions = MetricLabel(symbol: "heart", font: metaFont, color: .secondaryLabel)
    private let comments = MetricLabel(symbol: "bubble.right", font: metaFont, color: .secondaryLabel)
    private let views = MetricLabel(symbol: "eye", font: metaFont, color: .secondaryLabel)
    private let ageLabel = UILabel()
    private var loadTask: Task<Void, Never>?
    /// Swapped per configure: the metadata line hangs off the caption for
    /// text-only rows; media rows interpose the preview.
    private var metaFollowsCaption: NSLayoutConstraint!
    private var mediaConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        card.pin(to: contentView)

        captionLabel.font = .preferredFont(forTextStyle: .body)
        captionLabel.adjustsFontForContentSizeCategory = true
        captionLabel.textColor = .label
        captionLabel.numberOfLines = 0
        captionLabel.constrain(in: card) { parent in
            captionLabel.topAnchor.constraint(equalTo: parent.topAnchor, constant: 16)
            captionLabel.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 16)
            captionLabel.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16)
        }

        mediaView.contentMode = .scaleAspectFill
        mediaView.clipsToBounds = true
        mediaView.layer.cornerRadius = 12
        mediaView.layer.cornerCurve = .continuous
        card.addSubview(mediaView)
        mediaView.translatesAutoresizingMaskIntoConstraints = false

        playBadge.tintColor = .white
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.55
        playBadge.layer.shadowRadius = 4
        playBadge.layer.shadowOffset = .zero
        playBadge.constrain(in: mediaView) { parent in
            playBadge.topAnchor.constraint(equalTo: parent.topAnchor, constant: 10)
            playBadge.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -10)
        }

        ageLabel.font = Self.metaFont
        ageLabel.textColor = .secondaryLabel
        ageLabel.adjustsFontForContentSizeCategory = true
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let metaRow = UIStackView(arrangedSubviews: [reactions, comments, views, spacer, ageLabel])
        metaRow.axis = .horizontal
        metaRow.alignment = .center
        metaRow.spacing = 14
        metaRow.constrain(in: card) { parent in
            metaRow.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 16)
            metaRow.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -16)
            metaRow.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -14)
        }
        metaFollowsCaption = metaRow.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 12)
        metaFollowsCaption.isActive = true
        mediaConstraints = [
            mediaView.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 12),
            mediaView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            mediaView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            mediaView.heightAnchor.constraint(equalToConstant: 180),
            metaRow.topAnchor.constraint(equalTo: mediaView.bottomAnchor, constant: 12)
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        mediaView.image = nil
    }

    func configure(with post: GalleryPost, imagePipeline: ImagePipeline) {
        captionLabel.text = post.caption
        let hasMedia = post.kind != .text
        mediaView.isHidden = !hasMedia
        playBadge.isHidden = post.kind != .video
        metaFollowsCaption.isActive = !hasMedia
        NSLayoutConstraint.deactivate(hasMedia ? [] : mediaConstraints)
        NSLayoutConstraint.activate(hasMedia ? mediaConstraints : [])

        reactions.set(post.reactionCount)
        comments.set(post.commentCount)
        views.set(post.viewCount)
        ageLabel.text = PostMetadata.compactAge(ofMillis: post.publishedAtMS)

        mediaView.image = nil
        mediaView.backgroundColor = post.kind == .video ? .darkGray : .tertiarySystemFill
        guard hasMedia, let url = post.thumbnailURL else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            mediaView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url), !Task.isCancelled else { return }
            self?.mediaView.image = image
        }
    }
}

// MARK: - Media tile

/// One square of the Media grid: photo thumbnail, or video poster + badge,
/// with the compact counter pair (reactions, views) resting bottom-leading —
/// caption2 over a soft shadow, no scrim, so the preview stays the star.
private final class GalleryTileCell: UICollectionViewCell {
    static let reuseID = "GalleryTileCell"

    private let imageView = UIImageView()
    private let playBadge = UIImageView(image: UIImage(systemName: "play.fill"))
    private static let metaFont = UIFont.preferredFont(forTextStyle: .caption2).withWeight(.semibold)
    private let reactions = MetricLabel(symbol: "heart.fill", font: metaFont, color: .white, shadowed: true)
    private let views = MetricLabel(symbol: "eye.fill", font: metaFont, color: .white, shadowed: true)
    private var loadTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.clipsToBounds = true
        // Soft mosaic bricks, not hard edges — matched to the list cards'
        // inner media rounding.
        contentView.layer.cornerRadius = 10
        contentView.layer.cornerCurve = .continuous

        imageView.contentMode = .scaleAspectFill
        imageView.pin(to: contentView)

        // The badge sits over media of any brightness: a soft shadow instead
        // of a scrim keeps the thumbnail unobstructed.
        playBadge.tintColor = .white
        playBadge.layer.shadowColor = UIColor.black.cgColor
        playBadge.layer.shadowOpacity = 0.55
        playBadge.layer.shadowRadius = 4
        playBadge.layer.shadowOffset = .zero
        playBadge.constrain(in: contentView) { parent in
            playBadge.topAnchor.constraint(equalTo: parent.topAnchor, constant: 8)
            playBadge.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -8)
        }

        // Views lead, reactions follow — reach first, then resonance.
        let counters = UIStackView(arrangedSubviews: [views, reactions])
        counters.axis = .horizontal
        counters.spacing = 8
        counters.constrain(in: contentView) { parent in
            counters.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: 8)
            counters.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -7)
            counters.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -8)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        imageView.image = nil
    }

    func configure(with post: GalleryPost, imagePipeline: ImagePipeline) {
        playBadge.isHidden = post.kind != .video
        // Video tiles keep a dark floor: their poster may be unrenderable
        // (or plain black in the simulator), and the glyph needs a stage.
        contentView.backgroundColor = post.kind == .video ? .darkGray : .secondarySystemBackground

        reactions.set(post.reactionCount)
        views.set(post.viewCount)

        imageView.image = nil
        guard let url = post.thumbnailURL else { return }
        if let cached = imagePipeline.cachedImage(for: url) {
            imageView.image = cached
            return
        }
        loadTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url), !Task.isCancelled else { return }
            self?.imageView.image = image
        }
    }
}

private extension UIFont {
    func withWeight(_ weight: Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

// MARK: - Self-sizing host

/// Reports the layout's full content size as intrinsic size, so the outer
/// scroll view can Auto-Layout the (non-scrolling) grid like any other view.
private final class SelfSizingCollectionView: UICollectionView {
    override var intrinsicContentSize: CGSize {
        collectionViewLayout.collectionViewContentSize
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size.height != intrinsicContentSize.height {
            invalidateIntrinsicContentSize()
        }
    }
}
