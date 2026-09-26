import AVFoundation
import CoreModels
import CoreNavigation
import DesignSystem
import FeedInterface
import MediaCore
import UIKit

/// The sound a post is set to, opened from the attribution at the foot of
/// the feed: what it is, a listen, "Use this sound", and the other videos
/// made with it.
///
/// ```
///  ┌──────────────────────────────────────┐
///  │ ▔▔                                   │
///  │ ┌──────┐  Veridis Quo                │  artwork = play/pause
///  │ │  ▶︎   │  Daft Punk                  │
///  │ └──────┘  0:30 · 3 videos            │
///  │ [ ♫ Use this sound ]           (↑)   │  ← collapsed detent ends
///  │ Videos                               │     a row's peek below
///  │ ▢ ▢ ▢                                │
///  │ ▢ ▢ ▢                                │  large: the whole grid
///  └──────────────────────────────────────┘
/// ```
///
/// **THE FEED STAYS ALIVE UNDER THE COLLAPSED SHEET.** Two detents: the
/// collapsed one shows the sound and its actions while the clip keeps playing
/// above; the large one is a page of its own, and the clip behind pauses
/// (`onCoverChanged`).
///
/// ⚠️ **FROM LARGE, A DRAG DOWN CLOSES — IT DOES NOT STOP AT COLLAPSED.**
/// UIKit walks a sheet down through every detent. Once the sheet reaches
/// large its detents shrink to `[large]`, so the next drag down can only
/// dismiss, and the clip resumes on the way out. The collapsed detent is only
/// how the sheet OPENS.
///
/// ⚠️ **THE PREVIEW PAUSES THE CLIP.** Two sounds at once is noise; listening
/// to the sound is a choice the viewer just made, so the clip gives way until
/// the preview stops or the sheet goes.
final class SoundSheetViewController: UIViewController {
    struct Tile: Hashable, Sendable {
        let postID: PostID
        let thumbnailURL: URL?
        /// What a text post shows in its tile, having no picture.
        let caption: String?
        let isCurrent: Bool
    }

    /// Whether the clip behind should pause: the sheet is large, or the
    /// preview is playing.
    var onCoverChanged: ((Bool) -> Void)?
    /// A tile was chosen; the sheet is already on its way out.
    var onSelectPost: ((PostID) -> Void)?
    /// "Use this sound"; the sheet is already on its way out. Nil hides it.
    var onUseSound: ((PostSound) -> Void)?
    /// The sheet is gone, however it went.
    var onDismissed: (() -> Void)?

    private static let collapsedDetent = UISheetPresentationController.Detent.Identifier("sound.collapsed")
    private static let topInset: CGFloat = 24
    /// How much of the grid's first row the collapsed sheet shows: enough to
    /// say "there is more below", not a row you could mistake for the page.
    private static let gridPeek: CGFloat = 56

    private let sound: PostSound
    private let authorHandle: String
    private let fallbackArtworkURL: URL?
    private let tiles: [Tile]
    private let imagePipeline: ImagePipeline

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, Tile>!
    private weak var header: SoundSheetHeaderView?

    private var collapsedHeight: CGFloat?
    private var isExpanded = false
    private var isPreviewing = false
    private var isCovering = false
    private var preview: AVPlayer?
    private var previewEndObserver: NSObjectProtocol?
    private var previewTimeObserver: Any?
    private var raisedSessionForPreview = false

    init(
        sound: PostSound,
        authorHandle: String,
        fallbackArtworkURL: URL?,
        tiles: [Tile],
        imagePipeline: ImagePipeline
    ) {
        self.sound = sound
        self.authorHandle = authorHandle
        self.fallbackArtworkURL = fallbackArtworkURL
        self.tiles = tiles
        self.imagePipeline = imagePipeline
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [
                .custom(identifier: Self.collapsedDetent) { [weak self] context in
                    min(self?.collapsedHeight ?? 320, context.maximumDetentValue)
                },
                .large(),
            ]
            sheet.selectedDetentIdentifier = Self.collapsedDetent
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.delegate = self
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // ⚠️ CLEAR, so the sheet's own glass is the surface at the collapsed
        // detent — a painted background makes it opaque at every height.
        view.backgroundColor = .clear
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.delegate = self
        collectionView.contentInset.top = Self.topInset
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        configureDataSource()
        measureCollapsedHeight()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let sheet = sheetPresentationController {
            let radius = ScreenGeometry.cornerRadius(behind: view)
            if radius > 0 { sheet.preferredCornerRadius = radius }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed else { return }
        stopPreview()
        tearDownPreview()
    }

    /// The preview's player and its observers go with the sheet.
    private func tearDownPreview() {
        if let previewEndObserver { NotificationCenter.default.removeObserver(previewEndObserver) }
        if let previewTimeObserver { preview?.removeTimeObserver(previewTimeObserver) }
        previewEndObserver = nil
        previewTimeObserver = nil
        preview = nil
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed else { return }
        setCovering(false)
        onDismissed?()
    }

    // MARK: - Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let spacing: CGFloat = 2
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .fractionalWidth(1 / 3), heightDimension: .fractionalHeight(1)
            ))
            let columnWidth = (environment.container.effectiveContentSize.width - 2 * Spacing.lg - 2 * spacing) / 3
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: .init(widthDimension: .fractionalWidth(1),
                                  heightDimension: .absolute((columnWidth * 4 / 3).rounded())),
                repeatingSubitem: item, count: 3
            )
            group.interItemSpacing = .fixed(spacing)
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = spacing
            section.contentInsets = .init(top: 0, leading: Spacing.lg, bottom: Spacing.xl, trailing: Spacing.lg)
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(220)),
                elementKind: UICollectionView.elementKindSectionHeader, alignment: .top
            )
            section.boundarySupplementaryItems = [header]
            return section
        }
    }

    private func configureDataSource() {
        let pipeline = imagePipeline
        let tileRegistration = UICollectionView.CellRegistration<SoundSheetTileCell, Tile> { cell, _, tile in
            cell.configure(tile, pipeline: pipeline)
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<SoundSheetHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, _ in
            guard let self else { return }
            self.configure(header)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, path, tile in
            view.dequeueConfiguredReusableCell(using: tileRegistration, for: path, item: tile)
        }
        dataSource.supplementaryViewProvider = { view, _, path in
            view.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: path)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Tile>()
        snapshot.appendSections([0])
        snapshot.appendItems(tiles)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configure(_ header: SoundSheetHeaderView) {
        self.header = header
        header.configure(
            title: sound.title ?? "Original sound",
            subtitle: sound.artist ?? "@\(authorHandle)",
            meta: Self.meta(duration: sound.duration, posts: tiles.count),
            canPreview: sound.previewURL != nil,
            canUse: onUseSound != nil
        )
        header.setPlaying(isPreviewing)
        header.onTogglePreview = { [weak self] in self?.togglePreview() }
        header.onUse = { [weak self] in self?.useSound() }
        header.onShare = { [weak self] in self?.share() }
        if let url = sound.artworkURL ?? fallbackArtworkURL {
            Task { [weak header, pipeline = imagePipeline] in
                header?.setArtwork(await Self.image(at: url, pipeline: pipeline))
            }
        }
    }

    /// The collapsed detent: the header whole, and a peek of the grid.
    /// Measured in `viewDidLoad`, before the sheet has a window.
    private func measureCollapsedHeight() {
        // The header sits inside the section's side insets.
        let screen = presentingViewController?.view.window?.bounds.width ?? view.bounds.width
        let width = screen - 2 * Spacing.lg
        guard width > 0 else { return }
        let probe = SoundSheetHeaderView()
        probe.configure(
            title: sound.title ?? "Original sound", subtitle: sound.artist ?? "@\(authorHandle)",
            meta: Self.meta(duration: sound.duration, posts: tiles.count),
            canPreview: sound.previewURL != nil, canUse: true
        )
        let size = probe.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        )
        // ⚠️ A custom detent's height EXCLUDES the bottom safe area — the sheet
        // adds it back (see the wallet sheet's note).
        let window = view.window ?? presentingViewController?.view.window
        let bottomInset = window?.safeAreaInsets.bottom ?? 0
        collapsedHeight = (Self.topInset + size.height + Self.gridPeek - bottomInset).rounded()
    }

    /// A local file is read as it is; anything else goes through the app's
    /// pipeline. ⚠️ Not everything through the pipeline: the mock one paints
    /// a colour for any URL it does not recognise, a file among them.
    private static func image(at url: URL, pipeline: ImagePipeline) async -> UIImage? {
        if url.isFileURL {
            return await Task.detached(priority: .userInitiated) {
                UIImage(contentsOfFile: url.path)?.preparingForDisplay()
            }.value
        }
        return try? await pipeline.image(for: url)
    }

    /// "0:30 · 3 posts" — POSTS, not videos: a photograph or a text post can
    /// be set to a sound too.
    static func meta(duration: TimeInterval?, posts: Int) -> String {
        let count = posts == 1 ? "1 post" : "\(posts) posts"
        guard let duration, duration > 0 else { return count }
        return "\(Self.clock(duration)) · \(count)"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    // MARK: - Cover

    private func setCovering(_ covering: Bool) {
        guard covering != isCovering else { return }
        isCovering = covering
        onCoverChanged?(covering)
    }

    private func refreshCover() {
        setCovering(isExpanded || isPreviewing)
    }

    // MARK: - Preview

    private func togglePreview() {
        isPreviewing ? stopPreview() : startPreview()
    }

    private func startPreview() {
        guard let url = sound.previewURL else { return }
        if preview == nil {
            let player = AVPlayer(url: url)
            player.actionAtItemEnd = .pause
            previewEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopPreview(rewinding: true) }
            }
            previewTimeObserver = player.addPeriodicTimeObserver(
                forInterval: CMTime(value: 1, timescale: 4), queue: .main
            ) { [weak self] time in
                MainActor.assumeIsolated { self?.previewTicked(time.seconds) }
            }
            preview = player
        }
        // ⚠️ `.playback` while it plays: the viewer asked for this sound, and
        // an `.ambient` session would keep it silent on a phone set to silent
        // with nothing on screen to say why. Given back when it stops.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playback {
            try? session.setCategory(.playback, mode: .default)
            raisedSessionForPreview = true
        }
        isPreviewing = true
        refreshCover()
        header?.setPlaying(true)
        preview?.play()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func stopPreview(rewinding: Bool = false) {
        guard isPreviewing else { return }
        preview?.pause()
        if rewinding { preview?.seek(to: .zero) }
        if raisedSessionForPreview {
            raisedSessionForPreview = false
            try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .moviePlayback)
        }
        isPreviewing = false
        header?.setPlaying(false)
        header?.setMeta(Self.meta(duration: sound.duration, posts: tiles.count))
        refreshCover()
    }

    private func previewTicked(_ seconds: Double) {
        guard isPreviewing, seconds.isFinite else { return }
        let total = sound.duration.map { " / \(Self.clock($0))" } ?? ""
        header?.setMeta("\(Self.clock(seconds))\(total)")
    }

    // MARK: - Actions

    private func useSound() {
        guard let onUseSound else { return }
        let sound = sound
        dismiss(animated: true) { onUseSound(sound) }
    }

    private func share() {
        let text = [sound.title ?? "Original sound", sound.artist ?? "@\(authorHandle)"].joined(separator: " — ")
        let activity = UIActivityViewController(activityItems: ["♫ \(text)"], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = header ?? view
        present(activity, animated: true)
    }
}

// MARK: - Detents

extension SoundSheetViewController: UISheetPresentationControllerDelegate {
    func sheetPresentationControllerDidChangeSelectedDetentIdentifier(
        _ sheet: UISheetPresentationController
    ) {
        let expanded = sheet.selectedDetentIdentifier == .large
        guard expanded != isExpanded else { return }
        isExpanded = expanded
        refreshCover()
        guard expanded else { return }
        // See the type's note: from large, down means closed.
        sheet.animateChanges {
            sheet.detents = [.large()]
        }
    }
}

// MARK: - Grid

extension SoundSheetViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let tile = dataSource.itemIdentifier(for: indexPath) else { return }
        collectionView.deselectItem(at: indexPath, animated: true)
        let select = onSelectPost
        dismiss(animated: true) { select?(tile.postID) }
    }
}
