import MediaCore
import CoreModels
import DesignSystem
import MediaPlayback
import UIKit

/// A full-screen snap cell: cover-fit media under a bottom scrim, with the
/// author, caption and engagement controls overlaid. Text-only posts drop the
/// media and show a gradient backdrop instead.
///
/// It reuses `FeedItemDisplayModel` as-is — only the fields relevant to a
/// full-bleed layout (`mediaURL`, `avatarURL`, author text, caption string) are
/// read; the precomputed heights are ignored because every cell is bounds-sized.
/// Captions are re-styled here (white-on-scrim) on the main thread, which is
/// free when only one or two cells are ever alive at once.
final class SnapFeedCell: UICollectionViewCell, SnapCellLifecycle {
    static let reuseIdentifier = "SnapFeedCell"

    private let mediaView = UIImageView()
    private let videoRenderView = VideoRenderView()
    private let scrimView = GradientView(colors: [.clear, UIColor.black.withAlphaComponent(0.75)])
    private let textOnlyBackground = GradientView(
        colors: [UIColor(red: 0.15, green: 0.16, blue: 0.24, alpha: 1),
                 UIColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1)]
    )

    private let avatarView = UIImageView()
    private let nameLabel = UILabel()
    private let metaLabel = UILabel()
    private let captionLabel = UILabel()

    private let likeButton = UIButton(configuration: .plain())
    private let likeCountLabel = UILabel()
    private let commentButton = UIButton(configuration: .plain())

    /// A large centred play glyph shown while the active video is user-paused.
    private let pauseGlyph = UIImageView()
    /// Subtrees where a touch means "use the control", not "toggle playback".
    private var interactiveViews: [UIView] = []

    /// Set by the view controller; called on tap with the represented post.
    var onLikeTapped: ((PostID) -> Void)?
    /// Called when the author's avatar or name is tapped.
    var onAuthorTapped: ((ProfileID) -> Void)?
    /// Called when the comment button is tapped — opens the post's detail/comments.
    var onCommentTapped: ((PostID) -> Void)?

    private var representedID: PostID?
    private var authorID: ProfileID?
    private var mediaURL: URL?
    private var mediaKind: MediaKind = .image
    private var videoPlayback: VideoPlaybackController?
    private var imageTasks: [Task<Void, Never>] = []
    private var isActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .black
        contentView.clipsToBounds = true

        mediaView.contentMode = .scaleAspectFill
        mediaView.clipsToBounds = true

        avatarView.clipsToBounds = true
        avatarView.layer.cornerRadius = 18
        avatarView.backgroundColor = .darkGray
        avatarView.contentMode = .scaleAspectFill
        avatarView.widthAnchor.constraint(equalToConstant: 36).isActive = true
        avatarView.heightAnchor.constraint(equalToConstant: 36).isActive = true

        nameLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        nameLabel.textColor = .white
        metaLabel.font = .preferredFont(forTextStyle: .footnote)
        metaLabel.textColor = UIColor.white.withAlphaComponent(0.75)

        captionLabel.numberOfLines = 4
        captionLabel.textColor = .white

        // Legibility over arbitrary media, independent of the scrim.
        for label in [nameLabel, metaLabel, captionLabel] {
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.5
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = .zero
        }

        // Avatar + name route to the author's profile.
        for view in [avatarView, nameLabel] {
            view.isUserInteractionEnabled = true
            view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(authorTapped)))
        }

        var likeConfig = UIButton.Configuration.plain()
        likeConfig.image = UIImage(systemName: "heart")
        likeConfig.baseForegroundColor = .white
        likeButton.configuration = likeConfig
        likeButton.addAction(UIAction { [weak self] _ in
            guard let id = self?.representedID else { return }
            self?.onLikeTapped?(id)
        }, for: .primaryActionTriggered)

        likeCountLabel.font = UIFont.preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        likeCountLabel.textColor = .white
        likeCountLabel.textAlignment = .center

        var commentConfig = UIButton.Configuration.plain()
        commentConfig.image = UIImage(systemName: "bubble.right")
        commentConfig.baseForegroundColor = .white
        commentButton.configuration = commentConfig
        commentButton.addAction(UIAction { [weak self] _ in
            guard let id = self?.representedID else { return }
            self?.onCommentTapped?(id)
        }, for: .primaryActionTriggered)

        pauseGlyph.image = UIImage(systemName: "play.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 56, weight: .semibold))
        pauseGlyph.tintColor = UIColor.white.withAlphaComponent(0.85)
        pauseGlyph.contentMode = .center
        pauseGlyph.isUserInteractionEnabled = false
        pauseGlyph.isHidden = true
        pauseGlyph.layer.shadowColor = UIColor.black.cgColor
        pauseGlyph.layer.shadowOpacity = 0.4
        pauseGlyph.layer.shadowRadius = 6
        pauseGlyph.layer.shadowOffset = .zero

        // Background tap toggles play/pause; the delegate rejects taps that land
        // on an interactive control (rail / author row).
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
        tap.delegate = self
        contentView.addGestureRecognizer(tap)

        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout() {
        textOnlyBackground.pin(to: contentView)
        mediaView.pin(to: contentView)
        videoRenderView.pin(to: contentView)

        scrimView.isUserInteractionEnabled = false
        scrimView.constrain(in: contentView) { parent in
            scrimView.leadingAnchor.constraint(equalTo: parent.leadingAnchor)
            scrimView.trailingAnchor.constraint(equalTo: parent.trailingAnchor)
            scrimView.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
            scrimView.heightAnchor.constraint(equalTo: parent.heightAnchor, multiplier: 0.5)
        }

        // Author + caption, bottom-left, inset from the safe area.
        let header = UIStackView(arrangedSubviews: [avatarView, headerText()])
        header.axis = .horizontal
        header.spacing = Spacing.sm
        header.alignment = .center

        let leftStack = UIStackView(arrangedSubviews: [header, captionLabel])
        leftStack.axis = .vertical
        leftStack.spacing = Spacing.sm
        leftStack.alignment = .leading
        leftStack.constrain(in: contentView) { parent in
            leftStack.leadingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.leadingAnchor, constant: Spacing.lg)
            leftStack.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.lg)
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: parent.trailingAnchor, constant: -72)
        }

        // Engagement rail, bottom-right (TikTok-style vertical stack): like +
        // count, then comment.
        let railStack = UIStackView(arrangedSubviews: [likeButton, likeCountLabel, commentButton])
        railStack.axis = .vertical
        railStack.spacing = Spacing.xs
        railStack.alignment = .center
        railStack.setCustomSpacing(Spacing.md, after: likeCountLabel)
        railStack.constrain(in: contentView) { parent in
            railStack.trailingAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.trailingAnchor, constant: -Spacing.md)
            railStack.bottomAnchor.constraint(equalTo: parent.safeAreaLayoutGuide.bottomAnchor, constant: -Spacing.lg)
        }

        // Centred pause glyph (added last so it sits above the media/scrim).
        pauseGlyph.constrain(in: contentView) { parent in
            pauseGlyph.centerXAnchor.constraint(equalTo: parent.centerXAnchor)
            pauseGlyph.centerYAnchor.constraint(equalTo: parent.centerYAnchor)
        }

        // A touch inside the rail or the author header means "use that control",
        // not "toggle playback".
        interactiveViews = [railStack, header]
    }

    private func headerText() -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [nameLabel, metaLabel])
        stack.axis = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        return stack
    }

    // MARK: - Configuration

    func configure(
        with model: FeedItemDisplayModel,
        engagement: FeedViewModel.EngagementState,
        pipeline: ImagePipeline,
        videoPlayback: VideoPlaybackController?
    ) {
        representedID = model.id
        authorID = model.authorID
        mediaURL = model.mediaURL
        mediaKind = model.mediaKind
        self.videoPlayback = videoPlayback
        updateEngagement(engagement)

        nameLabel.text = model.authorName
        metaLabel.text = model.metaText

        let captionText = model.caption
        captionLabel.text = captionText
        captionLabel.isHidden = (captionText?.isEmpty ?? true)

        let hasMedia = model.mediaURL != nil
        let isVideo = hasMedia && model.mediaKind == .video
        let isImage = hasMedia && model.mediaKind == .image
        mediaView.isHidden = !isImage
        videoRenderView.isHidden = !isVideo
        scrimView.isHidden = !hasMedia
        textOnlyBackground.isHidden = hasMedia
        // Text-only posts lean on the caption, so give it more room and weight.
        captionLabel.numberOfLines = hasMedia ? 4 : 8
        captionLabel.font = hasMedia
            ? .preferredFont(forTextStyle: .body)
            : UIFont.preferredFont(forTextStyle: .title2).withWeight(.semibold)

        avatarView.image = nil
        mediaView.image = nil
        mediaView.transform = .identity
        videoRenderView.setPoster(nil)

        loadImage(model.avatarURL, into: avatarView, expecting: model.id, pipeline: pipeline)
        if isImage {
            loadImage(model.mediaURL, into: mediaView, expecting: model.id, pipeline: pipeline)
        }
        if isVideo, let thumbnailURL = model.thumbnailURL {
            loadPoster(thumbnailURL, expecting: model.id, pipeline: pipeline)
        }
    }

    /// Loads the video poster into the render view; shown under the player until
    /// the first frame is ready (or while an asset is still processing).
    private func loadPoster(_ url: URL, expecting id: PostID, pipeline: ImagePipeline) {
        imageTasks.append(Task { [weak self] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.representedID == id else { return }
            self.videoRenderView.setPoster(image)
        })
    }

    /// Updates only the engagement rail — live counter ticks and optimistic
    /// like toggles. Never relayouts.
    func updateEngagement(_ state: FeedViewModel.EngagementState) {
        likeCountLabel.text = Self.countText(state.likeCount)
        var config = likeButton.configuration
        config?.image = UIImage(systemName: state.isLiked ? "heart.fill" : "heart")
        config?.baseForegroundColor = state.isLiked ? .systemRed : .white
        likeButton.configuration = config
    }

    private func loadImage(_ url: URL?, into imageView: UIImageView, expecting id: PostID, pipeline: ImagePipeline) {
        guard let url else { return }
        imageTasks.append(Task { [weak self, weak imageView] in
            guard let image = try? await pipeline.image(for: url) else { return }
            guard let self, self.representedID == id else { return }
            imageView?.image = image
            // If the media arrives after activation, kick the motion now.
            if imageView === self.mediaView, self.isActive {
                self.startKenBurns()
            }
        })
    }

    @objc private func authorTapped() {
        guard let authorID else { return }
        onAuthorTapped?(authorID)
    }

    private static func countText(_ count: Int64) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : String(count)
    }

    // MARK: - SnapCellLifecycle

    func willBecomeActive() {
        guard !isActive else { return }
        isActive = true
        // Activation always starts playing, so any user-paused glyph is stale.
        setPauseGlyphVisible(false)
        switch mediaKind {
        case .video:
            guard let url = mediaURL, let videoPlayback else { return }
            let view = videoRenderView
            Task { await videoPlayback.play(url, in: view) }
        case .image:
            startKenBurns()
        }
    }

    // MARK: - Play/pause toggle

    @objc private func handleBackgroundTap() {
        togglePlayback()
    }

    /// Toggles the active video's playback and reflects it in the pause glyph.
    /// No-op for image/text cells (no player).
    func togglePlayback() {
        guard mediaKind == .video, let videoPlayback else { return }
        let paused = videoPlayback.togglePlayback(in: videoRenderView)
        setPauseGlyphVisible(paused)
    }

    private func setPauseGlyphVisible(_ visible: Bool) {
        guard pauseGlyph.isHidden == visible else { return }
        UIView.transition(with: pauseGlyph, duration: 0.15, options: .transitionCrossDissolve) {
            self.pauseGlyph.isHidden = !visible
        }
    }

    func didResignActive() {
        guard isActive else { return }
        isActive = false
        switch mediaKind {
        case .video:
            videoPlayback?.stop(videoRenderView)
        case .image:
            stopKenBurns()
        }
    }

    /// Phase 1's visible proof that activation works: a slow zoom on the active
    /// page's media. Phase 2 replaces this body with `player.play()`.
    private func startKenBurns() {
        guard mediaView.image != nil, !mediaView.isHidden else { return }
        mediaView.layer.removeAllAnimations()
        UIView.animate(withDuration: 8, delay: 0, options: [.curveLinear, .allowUserInteraction]) {
            self.mediaView.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
        }
    }

    private func stopKenBurns() {
        mediaView.layer.removeAllAnimations()
        UIView.performWithoutAnimation { self.mediaView.transform = .identity }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isActive = false
        stopKenBurns()
        setPauseGlyphVisible(false)
        videoPlayback?.stop(videoRenderView)
        representedID = nil
        authorID = nil
        mediaURL = nil
        mediaKind = .image
        for task in imageTasks { task.cancel() }
        imageTasks.removeAll()
        avatarView.image = nil
        mediaView.image = nil
        videoRenderView.setPoster(nil)
    }
}

// MARK: - Tap arbitration

extension SnapFeedCell: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !Self.isInteractiveTouch(touch.view, interactiveRoots: interactiveViews, stopAt: contentView)
    }

    /// True when the touched view is (or descends from) an interactive control —
    /// a `UIControl`, or any of `interactiveRoots` — walking up to `stopAt`. So
    /// taps on the rail (like/comment) and the author row use those controls;
    /// taps on the background/media/caption toggle playback. Pure + static so
    /// the arbitration is unit-testable.
    static func isInteractiveTouch(_ touched: UIView?, interactiveRoots: [UIView], stopAt: UIView) -> Bool {
        var view = touched
        while let current = view {
            if current is UIControl { return true }
            if interactiveRoots.contains(where: { $0 === current }) { return true }
            if current === stopAt { break }
            view = current.superview
        }
        return false
    }
}

/// A view backed by a `CAGradientLayer`, sized automatically with its bounds.
private final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var gradientLayer: CAGradientLayer { layer as! CAGradientLayer }

    init(colors: [UIColor],
         startPoint: CGPoint = CGPoint(x: 0.5, y: 0),
         endPoint: CGPoint = CGPoint(x: 0.5, y: 1)) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        gradientLayer.colors = colors.map(\.cgColor)
        gradientLayer.startPoint = startPoint
        gradientLayer.endPoint = endPoint
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
