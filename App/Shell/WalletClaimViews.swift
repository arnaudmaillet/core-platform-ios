import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import PostGrid
import UIKit

// The pieces of the wallet sheet (`WalletClaimViewController`): the summary at
// its head — the two currencies side by side over the streak and today's
// earnings — the stake rows under it, their section headers, the compact bar
// the summary collapses into on scroll, and the blurs the list passes under.
//
// ⚠️ **CARDS ONLY FOR WHAT CAN BE PRESSED** (26 September 2026). The summary
// used to sit in three filled cards — two balances and a streak card — and a
// card is the app's promise that a thing can be pressed: nothing in the summary
// can. So the summary is BARE, big numbers straight on the page with hairlines
// between them, and the only cards on the sheet are the stake rows, which open
// their post. The page itself is the grouped grey with white cards on it —
// For You's and Profile's surface (`Surface`).

// MARK: - Shared

enum WalletSheetMetrics {
    static let sideMargin: CGFloat = Spacing.lg
    static let rowCorner: CGFloat = 18
    static let claimHeight: CGFloat = 52
    static let thumbnail: CGFloat = 48
    /// The balances: the sheet's main information, so its biggest type.
    static let balanceSize: CGFloat = 40
}

/// A number followed by its currency's glyph — "20 ♥", "+10 💎" — the ONE order
/// every amount on the sheet is written in.
func walletAmount(
    _ text: String, glyph: UIImage?, font: UIFont, color: UIColor = .label
) -> NSAttributedString {
    let result = NSMutableAttributedString(string: text + " ", attributes: [
        .font: font, .foregroundColor: color,
    ])
    result.append(walletGlyph(glyph, font: font))
    return result
}

/// A glyph inline in a line of type — the currencies' icons beside their
/// numbers, sized to the text they sit in.
func walletGlyph(_ image: UIImage?, font: UIFont) -> NSAttributedString {
    guard let image else { return NSAttributedString() }
    let attachment = NSTextAttachment(image: image)
    let side = font.capHeight + 3
    attachment.bounds = CGRect(x: 0, y: (font.capHeight - side) / 2, width: side * image.size.width / max(image.size.height, 1), height: side)
    return NSAttributedString(attachment: attachment)
}

/// "Unlocks in 3h 12m" / "in 42m" / "any moment".
func walletRemainingText(until date: Date, now: Date) -> String {
    let seconds = max(0, Int(date.timeIntervalSince(now).rounded(.up)))
    guard seconds > 60 else { return "any moment" }
    let hours = seconds / 3600, minutes = (seconds % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}

/// "just now" / "5h ago" / "2d ago".
func walletAgoText(since date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 3600 { return seconds < 120 ? "just now" : "\(seconds / 60)m ago" }
    if seconds < 86_400 { return "\(seconds / 3600)h ago" }
    return "\(seconds / 86_400)d ago"
}

// MARK: - Summary

/// One currency: its token, its name, its balance, and a word for what it is —
/// on the page itself, no card (see the file's note).
final class WalletBalanceTile: UIView {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let valueLabel = UILabel()
    private let noteLabel = UILabel()

    init(icon: UIImage?, name: String, note: String) {
        super.init(frame: .zero)
        iconView.image = icon
        iconView.contentMode = .scaleAspectFit
        nameLabel.text = name
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .secondaryLabel
        // Rounded and monospaced: a balance is a figure that changes under
        // the viewer's eyes, and its digits must not jostle when it does.
        let base = UIFont.monospacedDigitSystemFont(ofSize: WalletSheetMetrics.balanceSize, weight: .bold)
        valueLabel.font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 0) } ?? base
        valueLabel.textColor = .label
        valueLabel.textAlignment = .center
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.5
        noteLabel.text = note
        noteLabel.font = .systemFont(ofSize: 12, weight: .regular)
        noteLabel.textColor = .tertiaryLabel
        noteLabel.textAlignment = .center

        let top = UIStackView(arrangedSubviews: [iconView, nameLabel])
        top.spacing = Spacing.xs
        top.alignment = .center
        let column = UIStackView(arrangedSubviews: [top, valueLabel, noteLabel])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 0
        column.setCustomSpacing(Spacing.xs, after: top)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.sm),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
            valueLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setValue(_ value: Int) {
        // The FULL number: the sheet is the ledger view, where "100 000" is
        // the honest reading and the toolbar's "100K" stays glanceable.
        valueLabel.text = value.formatted()
        accessibilityValue = valueLabel.text
    }

    /// The claim's payoff: the new number pops.
    func pop() {
        valueLabel.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 2) {
            self.valueLabel.transform = .identity
        }
    }
}

/// The head of the sheet: Points and Gems side by side, a hairline, then the
/// streak on the left and today's earnings on the right.
///
/// ```
///        ♥ Points      │      💎 Gems
///          250         │         37
///     To stake on posts│ Earned by your stakes
///   ─────────────────────────────────────────
///   🔥 3-day streak    │  Earned today  25 / 200
///      Kept for today  │  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬
/// ```
///
/// Bare, on the page: nothing here can be pressed, so nothing here wears a
/// card. The balances get the height — they are what the sheet is for.
final class WalletSummaryView: UIView {
    let pointsTile = WalletBalanceTile(
        icon: UIImage(
            systemName: PointsSymbol.coin,
            withConfiguration: PointsSymbol.coinPalette
        )?.withRenderingMode(.alwaysOriginal),
        name: "Points", note: "To stake on posts"
    )
    let gemsTile = WalletBalanceTile(
        icon: GemSymbol.glyphImage(UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
        name: GemSymbol.name, note: "Earned by your stakes"
    )

    private let streakDisc = UIView()
    private let streakIcon = UIImageView()
    private let streakTitle = UILabel()
    private let streakSubtitle = UILabel()
    private let earnedTitle = UILabel()
    private let earnedValue = UILabel()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private var progressWidth: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let balancesDivider = Self.hairline()
        let balances = UIStackView(arrangedSubviews: [pointsTile, balancesDivider, gemsTile])
        balances.alignment = .center
        balances.spacing = Spacing.sm

        // — Streak, left half —
        streakDisc.layer.cornerRadius = 16
        streakIcon.contentMode = .center
        streakIcon.translatesAutoresizingMaskIntoConstraints = false
        streakDisc.addSubview(streakIcon)
        streakTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        streakTitle.textColor = .label
        streakSubtitle.font = .systemFont(ofSize: 12)
        streakSubtitle.textColor = .secondaryLabel
        streakSubtitle.numberOfLines = 2
        let streakText = UIStackView(arrangedSubviews: [streakTitle, streakSubtitle])
        streakText.axis = .vertical
        streakText.spacing = 1
        let streak = UIStackView(arrangedSubviews: [streakDisc, streakText])
        streak.spacing = Spacing.sm
        streak.alignment = .center

        // — Today's earnings, right half —
        earnedTitle.text = "Earned today"
        earnedTitle.font = .systemFont(ofSize: 12)
        earnedTitle.textColor = .secondaryLabel
        earnedValue.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        earnedValue.textColor = .label
        progressTrack.backgroundColor = .tertiarySystemFill
        progressTrack.layer.cornerRadius = 2
        progressFill.backgroundColor = PointsSymbol.tint
        progressFill.layer.cornerRadius = 2
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        let earned = UIStackView(arrangedSubviews: [earnedTitle, earnedValue, progressTrack])
        earned.axis = .vertical
        earned.spacing = 3
        earned.setCustomSpacing(Spacing.xs, after: earnedValue)

        let halvesDivider = Self.hairline()
        let halves = UIStackView(arrangedSubviews: [streak, halvesDivider, earned])
        halves.alignment = .center
        halves.spacing = Spacing.md

        let rule = UIView()
        rule.backgroundColor = .separator

        let column = UIStackView(arrangedSubviews: [balances, rule, halves])
        column.axis = .vertical
        column.spacing = Spacing.md
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
            // The two balances share the width evenly, the hairline between.
            gemsTile.widthAnchor.constraint(equalTo: pointsTile.widthAnchor),
            balancesDivider.heightAnchor.constraint(equalTo: balances.heightAnchor, multiplier: 0.7),
            rule.heightAnchor.constraint(equalToConstant: 0.5),
            streakDisc.widthAnchor.constraint(equalToConstant: 32),
            streakDisc.heightAnchor.constraint(equalToConstant: 32),
            streakIcon.centerXAnchor.constraint(equalTo: streakDisc.centerXAnchor),
            streakIcon.centerYAnchor.constraint(equalTo: streakDisc.centerYAnchor),
            halvesDivider.heightAnchor.constraint(equalTo: halves.heightAnchor),
            // The two halves share the row evenly too.
            earned.widthAnchor.constraint(equalTo: streak.widthAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 4),
            progressTrack.widthAnchor.constraint(equalTo: earned.widthAnchor),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
        ])
    }

    /// A vertical hairline between two halves.
    private static func hairline() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        return line
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(with snapshot: WalletSnapshot) {
        pointsTile.setValue(snapshot.balance)
        gemsTile.setValue(snapshot.gems)

        // The streak's three faces: none yet (invitation), fed today (kept),
        // not yet fed (urgent) — each says what to DO, in a line.
        let active = snapshot.streakDays > 0
        streakIcon.image = UIImage(
            systemName: active ? "flame.fill" : "flame",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        )?.withTintColor(active ? .systemOrange : .secondaryLabel, renderingMode: .alwaysOriginal)
        streakDisc.backgroundColor = active
            ? UIColor.systemOrange.withAlphaComponent(0.15) : .quaternarySystemFill
        if !active {
            streakTitle.text = "No streak yet"
            streakSubtitle.text = "Claim daily for up to ×2"
        } else if snapshot.claimedToday > 0 {
            streakTitle.text = "\(snapshot.streakDays)-day streak"
            streakSubtitle.text = "Kept for today"
        } else {
            streakTitle.text = "\(snapshot.streakDays)-day streak"
            streakSubtitle.text = "Claim to keep it"
        }

        earnedValue.text = "\(snapshot.claimedToday) / \(snapshot.dailyClaimCap)"
        let fraction = snapshot.dailyClaimCap > 0
            ? min(1, CGFloat(snapshot.claimedToday) / CGFloat(snapshot.dailyClaimCap)) : 0
        progressWidth?.isActive = false
        progressWidth = progressFill.widthAnchor.constraint(equalTo: progressTrack.widthAnchor, multiplier: fraction)
        progressWidth?.isActive = true
    }
}

final class WalletSummaryCell: UICollectionViewCell {
    let summary = WalletSummaryView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        summary.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(summary)
        NSLayoutConstraint.activate([
            summary.topAnchor.constraint(equalTo: contentView.topAnchor),
            summary.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            summary.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - Stakes

/// One stake: the post it was placed on, and where it stands.
///
/// ACTIVE — the points committed and how long until it settles.
/// SETTLED — what it earned in gems, or "No reward" (a normal outcome: the
/// charter pays demonstrated value, not attention), and how long ago.
///
/// A card, and a pressable one: it opens the post in the feed, flying from
/// its thumbnail (media) or revealing from the card (text) — see
/// `WalletClaimViewController.openFeed`.
final class WalletStakeCell: UICollectionViewCell {
    private let thumbnail = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let resultLabel = UILabel()
    private let detailLabel = UILabel()
    private var imageTask: Task<Void, Never>?
    private var shownURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // A white card on the grouped page — the one thing on the sheet that
        // can be pressed (it opens the post).
        contentView.backgroundColor = Surface.card
        contentView.layer.cornerRadius = WalletSheetMetrics.rowCorner
        contentView.layer.cornerCurve = .continuous
        Surface.applyCardEdge(to: contentView)
        // The app's one press: the card gives a little under the finger.
        PressFeedback.attach(toView: contentView, sound: nil)

        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 10
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.backgroundColor = .tertiarySystemFill
        thumbnail.tintColor = .secondaryLabel

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .label
        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = .secondaryLabel
        resultLabel.textAlignment = .right
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .right
        for label in [resultLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 2
        let trailing = UIStackView(arrangedSubviews: [resultLabel, detailLabel])
        trailing.axis = .vertical
        trailing.alignment = .trailing
        trailing.spacing = 2
        let row = UIStackView(arrangedSubviews: [thumbnail, text, trailing])
        row.spacing = Spacing.sm
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            thumbnail.widthAnchor.constraint(equalToConstant: WalletSheetMetrics.thumbnail),
            thumbnail.heightAnchor.constraint(equalToConstant: WalletSheetMetrics.thumbnail),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.sm),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.sm),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.md),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.sm),
        ])
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
        shownURL = nil
        thumbnail.image = nil
        // Concealment is per-FLIGHT state and must not ride a recycled row.
        thumbnail.alpha = 1
        contentView.alpha = 1
    }

    func configure(stake: WalletStake, post: GalleryPost?, now: Date, imagePipeline: ImagePipeline?) {
        // The post: who wrote it, and its opening words (a photograph with no
        // caption says what it is instead).
        if let post {
            titleLabel.text = post.authorName ?? "Post"
            let caption = post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            subtitleLabel.text = caption.isEmpty
                ? (post.kind == .text ? "Post" : "Photo or video")
                : caption.replacingOccurrences(of: "\n", with: " ")
        } else {
            titleLabel.text = "Post"
            subtitleLabel.text = " "
        }
        applyThumbnail(post: post, imagePipeline: imagePipeline)
        applyStatus(stake: stake, now: now)
        accessibilityLabel = [titleLabel.text, subtitleLabel.text].compactMap { $0 }.joined(separator: ", ")
    }

    /// The part that moves with the clock — rewritten every second for an
    /// active stake, without reconfiguring the rest.
    func applyStatus(stake: WalletStake, now: Date) {
        let resultFont = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        let result = NSMutableAttributedString()
        switch stake.outcome {
        case nil:
            result.append(walletAmount("\(stake.amount)", glyph: PointsSymbol.glyphImage(), font: resultFont))
            detailLabel.text = "Settles in \(walletRemainingText(until: stake.settlesAt, now: now))"
        case .gems(let earned):
            result.append(walletAmount(
                "+\(earned)", glyph: GemSymbol.glyphImage(), font: resultFont, color: GemSymbol.tint
            ))
            detailLabel.text = "\(stake.amount) staked · \(walletAgoText(since: stake.settlesAt, now: now))"
        case .noReward:
            result.append(NSAttributedString(string: "No reward", attributes: [
                .font: UIFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: UIColor.secondaryLabel,
            ]))
            detailLabel.text = "\(stake.amount) staked · \(walletAgoText(since: stake.settlesAt, now: now))"
        }
        resultLabel.attributedText = result
        accessibilityValue = [resultLabel.text, detailLabel.text].compactMap { $0 }.joined(separator: ", ")
    }

    private func applyThumbnail(post: GalleryPost?, imagePipeline: ImagePipeline?) {
        let url = post.flatMap { $0.kind == .text ? nil : $0.thumbnailURL }
        guard let url, let imagePipeline else {
            // A text post (or one not loaded yet) wears a quote on a tile.
            imageTask?.cancel()
            shownURL = nil
            thumbnail.contentMode = .center
            thumbnail.image = UIImage(
                systemName: post == nil ? "circle.dotted" : "text.quote",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            )
            return
        }
        guard url != shownURL else { return }
        shownURL = url
        thumbnail.contentMode = .scaleAspectFill
        if let cached = imagePipeline.cachedImage(for: url) {
            thumbnail.image = cached
            return
        }
        thumbnail.image = nil
        imageTask?.cancel()
        imageTask = Task { [weak self] in
            guard let image = try? await imagePipeline.image(for: url),
                  !Task.isCancelled, let self, self.shownURL == url else { return }
            self.thumbnail.image = image
        }
    }

    // MARK: - Hero

    /// The picture a flight takes off with — nil until the thumbnail loaded,
    /// and for a text post, which has none.
    var heroCover: UIImage? {
        thumbnail.contentMode == .scaleAspectFill ? thumbnail.image : nil
    }

    /// The thumbnail's rect in `space` — where a media post's flight leaves
    /// from and lands.
    func heroFrame(in space: UICoordinateSpace) -> CGRect {
        thumbnail.convert(thumbnail.bounds, to: space)
    }

    /// The row as drawn now — the stand-in a text post's window crossfades
    /// to and from (`WalletClaimViewController.heroOrigin`).
    func renderedImage() -> UIImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return UIGraphicsImageRenderer(bounds: bounds).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }

    /// Hides the thumbnail while its twin is in the air (media), or the whole
    /// card while the page is revealed over it (text).
    func setHeroConcealed(_ concealed: Bool, wholeCard: Bool) {
        if wholeCard {
            contentView.alpha = concealed ? 0 : 1
        } else {
            thumbnail.alpha = concealed ? 0 : 1
        }
    }
}

/// No active stake: what staking is, in a sentence, where the list would be.
final class WalletEmptyStakesCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Surface.card
        contentView.layer.cornerRadius = WalletSheetMetrics.rowCorner
        contentView.layer.cornerCurve = .continuous
        Surface.applyCardEdge(to: contentView)
        let title = UILabel()
        title.text = "No active stakes"
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let body = UILabel()
        let hours = Int(WalletStore.Policy.settlementDelay / 3600)
        body.text = "Stake points on a post you believe in. Each stake settles \(hours) hours later — and may earn gems."
        body.font = .systemFont(ofSize: 13)
        body.textColor = .secondaryLabel
        body.numberOfLines = 0
        let column = UIStackView(arrangedSubviews: [title, body])
        column.axis = .vertical
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.md),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.md),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.md),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.md),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// A section's title and, on the right, what it adds up to.
final class WalletSectionHeader: UICollectionReusableView {
    static let kind = "wallet.sectionHeader"
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        detailLabel.textColor = .secondaryLabel
        let row = UIStackView(arrangedSubviews: [titleLabel, UIView(), detailLabel])
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.xs),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.xs),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.xs),
        ])
        accessibilityTraits = .header
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String, detail: NSAttributedString?) {
        titleLabel.text = title
        detailLabel.attributedText = detail
    }
}

// MARK: - Compact bar

/// What the summary collapses into once it has scrolled away: both balances
/// on one line, pinned under the grabber over a blur that dissolves downward,
/// so the list passes BEHIND it and is never read without the balances.
///
/// ⚠️ **THE BLUR FADES IN BY SCRUBBING ITS EFFECT, NOT ITS ALPHA.** Alpha on a
/// visual-effect view (or any ancestor of one) is unsupported and renders
/// wrong; a paused property animator over `effect` is the native way to show
/// part of a material, and `progress` sets its fraction.
final class WalletCompactBar: UIView {
    private let label = UILabel()
    private let blur = WalletEdgeBlurView(edge: .top)
    private var blurAnimator: UIViewPropertyAnimator?
    private var pendingProgress: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        label.textAlignment = .center
        label.alpha = 0
        for view in [blur, label] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            // The ramp runs past the bar, so the list dissolves into it
            // rather than meeting an edge under the balances.
            blur.bottomAnchor.constraint(equalTo: bottomAnchor, constant: Spacing.xl),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, blurAnimator == nil else { return }
        // Built on attach, like every material in the app (headless CI).
        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [blur] in
            blur.effect = UIBlurEffect(style: .systemThinMaterial)
        }
        animator.pausesOnCompletion = true
        animator.fractionComplete = pendingProgress
        blurAnimator = animator
    }

    /// 0 at rest (nothing under the grabber, no blur), 1 once the summary has
    /// gone beneath it.
    var progress: CGFloat = 0 {
        didSet {
            guard progress != oldValue else { return }
            label.alpha = progress
            pendingProgress = progress
            blurAnimator?.fractionComplete = progress
        }
    }

    func configure(points: Int, gems: Int) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        let text = NSMutableAttributedString()
        text.append(walletAmount(points.formatted(), glyph: PointsSymbol.glyphImage(), font: font))
        text.append(NSAttributedString(string: "      ", attributes: [.font: font]))
        text.append(walletAmount(gems.formatted(), glyph: GemSymbol.glyphImage(), font: font))
        label.attributedText = text
        accessibilityLabel = "\(points) points, \(gems) gems"
    }

    deinit {
        MainActor.assumeIsolated { blurAnimator?.stopAnimation(true) }
    }
}

// MARK: - Edge blur

/// A blur that dissolves along its length instead of ending on an edge — the
/// list passes under the compact bar and the Claim button and simply loses
/// definition there.
///
/// The masked-effect pair is the native way to build a blur gradient: UIKit
/// has no gradient-blur type and alpha on an effect view is unsupported, so
/// the material is the system's own and a gradient MASK decides where it
/// lands. Upload's `ProgressiveBlurView` is the same recipe; features cannot
/// import one another, and the App target cannot reach it either.
///
/// ⚠️ The mask is a view assigned to `mask`, never a layer on `layer`, and
/// its frame is re-bound every layout pass. The effect is set by the owner
/// (`WalletCompactBar` scrubs it) or on window attach, never in `init`.
final class WalletEdgeBlurView: UIVisualEffectView {
    enum Edge { case top, bottom }

    private let ramp: RampView
    private let setsOwnEffect: Bool

    init(edge: Edge, setsOwnEffect: Bool = false) {
        ramp = RampView(edge: edge)
        self.setsOwnEffect = setsOwnEffect
        super.init(effect: nil)
        isUserInteractionEnabled = false
        mask = ramp
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard setsOwnEffect, window != nil, effect == nil else { return }
        effect = UIBlurEffect(style: .systemThinMaterial)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ramp.frame = bounds
    }

    /// Opaque at the edge the chrome sits on, clear toward the list.
    private final class RampView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        init(edge: Edge) {
            super.init(frame: .zero)
            guard let gradient = layer as? CAGradientLayer else { return }
            let opaque = UIColor.black.cgColor, clear = UIColor.clear.cgColor
            gradient.colors = edge == .top ? [opaque, opaque, clear] : [clear, opaque, opaque]
            gradient.locations = edge == .top ? [0, 0.55, 1] : [0, 0.45, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    }
}
