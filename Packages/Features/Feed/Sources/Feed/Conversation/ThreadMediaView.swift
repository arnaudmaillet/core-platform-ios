import DesignSystem
import FeedInterface
import MediaCore
import UIKit

/// A message's photo or video in the conversation (#681), under its row and
/// indented to the row's text column, as the quote strip is.
///
/// - The picture at its own shape (clamped between 3:4 and 4:3 here, so a
///   panorama or a long screenshot neither takes over nor vanishes), at most
///   `maxWidth` wide, rounded.
/// - A video wears a play glyph and its length.
/// - The viewer's own message on its way is dimmed under a spinner; a FAILED
///   one says so, and a tap sends it again (`onTap` with `.failed`).
/// - A tap otherwise opens it full screen (the host's `onTap`).
@MainActor
final class ThreadMediaView: UIView {
    static let maxWidth: CGFloat = 240
    static let cornerRadius: CGFloat = 14
    /// The narrowest and widest shapes drawn.
    static let ratioRange: ClosedRange<CGFloat> = 0.75...(4.0 / 3.0)

    /// Tapped: open it, or — failed — send it again. The host reads
    /// `delivery` to tell which.
    var onTap: (() -> Void)?
    private(set) var delivery: ConversationThreadDelivery = .sent

    private let frameView = UIView()
    private let imageView = UIImageView()
    private let dim = UIView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let playBadge = UIImageView()
    private let durationLabel = UILabel()
    private let failedStack = UIStackView()
    private var ratioConstraint: NSLayoutConstraint?
    private var barLeading: NSLayoutConstraint?
    private var loadTask: Task<Void, Never>?
    private var shownURL: URL?

    init() {
        super.init(frame: .zero)
        frameView.layer.cornerRadius = Self.cornerRadius
        frameView.layer.cornerCurve = .continuous
        frameView.clipsToBounds = true
        frameView.backgroundColor = .tertiarySystemFill
        frameView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(frameView)

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        spinner.color = .white
        playBadge.image = UIImage(
            systemName: "play.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)
        )?.withRenderingMode(.alwaysOriginal).withTintColor(.white.withAlphaComponent(0.9))
        playBadge.contentMode = .center
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.shadowColor = UIColor.black.withAlphaComponent(0.4)
        durationLabel.shadowOffset = CGSize(width: 0, height: 1)

        let failedIcon = UIImageView(image: UIImage(
            systemName: "exclamationmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)
        )?.withTintColor(.systemRed, renderingMode: .alwaysOriginal))
        let failedLabel = UILabel()
        failedLabel.text = "Not sent · Tap to retry"
        failedLabel.font = .appFont(forTextStyle: .footnote)
        failedLabel.adjustsFontForContentSizeCategory = true
        failedLabel.textColor = .white
        failedStack.addArrangedSubview(failedIcon)
        failedStack.addArrangedSubview(failedLabel)
        failedStack.axis = .vertical
        failedStack.alignment = .center
        failedStack.spacing = Spacing.xs

        for view in [imageView, dim, spinner, playBadge, durationLabel, failedStack] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isUserInteractionEnabled = false
            frameView.addSubview(view)
        }
        let leading = frameView.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: CommentRowView.avatarSize + CommentRowView.avatarGap
        )
        barLeading = leading
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) { (view: ThreadMediaView, _: UITraitCollection) in
            view.barLeading?.constant = CommentRowView.avatarSize(for: view.traitCollection) + CommentRowView.avatarGap
        }
        // ⚠️ The picture's own size must not decide the bubble's: an image
        // view resists compression at its pixel size, and at `.defaultHigh`
        // this lost to it (a 320-point photo).
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        let width = frameView.widthAnchor.constraint(equalToConstant: Self.maxWidth)
        width.priority = .required - 1
        NSLayoutConstraint.activate([
            leading,
            width,
            frameView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            frameView.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.xs),
            frameView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: frameView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: frameView.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            dim.topAnchor.constraint(equalTo: frameView.topAnchor),
            dim.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: frameView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: frameView.centerYAnchor),
            playBadge.centerXAnchor.constraint(equalTo: frameView.centerXAnchor),
            playBadge.centerYAnchor.constraint(equalTo: frameView.centerYAnchor),
            durationLabel.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: Spacing.sm),
            durationLabel.bottomAnchor.constraint(equalTo: frameView.bottomAnchor, constant: -Spacing.sm),
            failedStack.centerXAnchor.constraint(equalTo: frameView.centerXAnchor),
            failedStack.centerYAnchor.constraint(equalTo: frameView.centerYAnchor),
            failedStack.leadingAnchor.constraint(greaterThanOrEqualTo: frameView.leadingAnchor, constant: Spacing.sm),
        ])
        setRatio(1)
        frameView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Draws `media` (nil hides the view) in its `delivery` state.
    func configure(_ media: ConversationThreadMedia?, delivery: ConversationThreadDelivery, pipeline: ImagePipeline?) {
        self.delivery = delivery
        guard let media else {
            isHidden = true
            loadTask?.cancel()
            imageView.image = nil
            shownURL = nil
            return
        }
        isHidden = false
        setRatio(Self.clampedRatio(media.aspectRatio))
        let isVideo = media.kind == .video
        playBadge.isHidden = !isVideo || delivery != .sent
        durationLabel.isHidden = !isVideo
        durationLabel.text = media.duration.map(Self.durationText)
        dim.isHidden = delivery == .sent
        spinner.isHidden = delivery != .sending
        if delivery == .sending { spinner.startAnimating() } else { spinner.stopAnimating() }
        failedStack.isHidden = delivery != .failed
        accessibilityLabel = switch delivery {
        case .sent: isVideo ? "Video" : "Photo"
        case .sending: isVideo ? "Video, sending" : "Photo, sending"
        case .failed: isVideo ? "Video, not sent" : "Photo, not sent"
        }
        accessibilityHint = delivery == .failed ? "Double-tap to send again." : (delivery == .sent ? "Double-tap to open." : nil)

        // The picture picked wins: the viewer's own message never waits on
        // the network, and a mock delivery URL has nothing behind it.
        if let preview = media.preview {
            loadTask?.cancel()
            shownURL = nil
            imageView.image = preview
            return
        }
        let url = isVideo ? media.posterURL : media.url
        guard url != shownURL else { return }
        shownURL = url
        imageView.image = nil
        loadTask?.cancel()
        guard let url, let pipeline else { return }
        loadTask = Task { [weak self] in
            let image = try? await pipeline.image(for: url)
            guard let self, !Task.isCancelled, self.shownURL == url else { return }
            self.imageView.image = image
        }
    }

    /// The picture shown now, for the full-screen viewer's first frame.
    var image: UIImage? { imageView.image }

    static func clampedRatio(_ ratio: CGFloat?) -> CGFloat {
        guard let ratio, ratio.isFinite, ratio > 0 else { return 1 }
        return min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func setRatio(_ ratio: CGFloat) {
        ratioConstraint?.isActive = false
        let constraint = frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor, multiplier: 1 / ratio)
        constraint.isActive = true
        ratioConstraint = constraint
    }

    @objc private func tapped() { onTap?() }

    #if DEBUG
    var debugFrameSize: CGSize { frameView.bounds.size }
    var debugIsSpinning: Bool { !spinner.isHidden && spinner.isAnimating }
    var debugShowsFailure: Bool { !failedStack.isHidden }
    var debugShowsPlay: Bool { !playBadge.isHidden }
    #endif
}
