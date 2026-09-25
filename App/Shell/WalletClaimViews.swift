import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import UIKit

// The pieces of the wallet sheet (`WalletClaimViewController`): the summary at
// its head — the two currencies side by side over the streak and today's
// earnings — the stake rows under it, their section headers, and the compact
// bar the summary collapses into on scroll.

// MARK: - Shared

enum WalletSheetMetrics {
    static let sideMargin: CGFloat = Spacing.lg
    static let cardCorner: CGFloat = 18
    static let rowCorner: CGFloat = 16
    static let claimHeight: CGFloat = 52
    static let thumbnail: CGFloat = 48
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

/// One currency: its token, its name, its balance, and a word for what it is.
final class WalletBalanceTile: UIView {
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let valueLabel = UILabel()
    private let noteLabel = UILabel()

    init(icon: UIImage?, name: String, note: String) {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = WalletSheetMetrics.cardCorner
        layer.cornerCurve = .continuous

        iconView.image = icon
        iconView.contentMode = .scaleAspectFit
        nameLabel.text = name
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = .secondaryLabel
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 30, weight: .bold)
        valueLabel.textColor = .label
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.6
        noteLabel.text = note
        noteLabel.font = .systemFont(ofSize: 12, weight: .regular)
        noteLabel.textColor = .tertiaryLabel

        let top = UIStackView(arrangedSubviews: [iconView, nameLabel])
        top.spacing = Spacing.xs
        top.alignment = .center
        let column = UIStackView(arrangedSubviews: [top, valueLabel, noteLabel])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.setCustomSpacing(Spacing.xs, after: top)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.md),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.md),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.md),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.md),
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

/// The head of the sheet: Points and Gems side by side, then ONE compact card
/// split in two — the streak on the left, today's earnings on the right.
///
/// ⚠️ **ONE CARD, NOT TWO BLOCKS.** The streak card and the earnings bar used
/// to stack as two full-width sections under a centred balance; with two
/// currencies to show and a stake list below, the head has to fit the info
/// detent on its own, so the pair shares one row.
final class WalletSummaryView: UIView {
    let pointsTile = WalletBalanceTile(
        icon: UIImage(
            systemName: PointsSymbol.coin,
            withConfiguration: PointsSymbol.coinPalette
        )?.withRenderingMode(.alwaysOriginal),
        name: "Points", note: "To stake on posts"
    )
    let gemsTile = WalletBalanceTile(
        icon: GemSymbol.glyphImage(UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)),
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
        let tiles = UIStackView(arrangedSubviews: [pointsTile, gemsTile])
        tiles.distribution = .fillEqually
        tiles.spacing = Spacing.sm

        let card = UIView()
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = WalletSheetMetrics.cardCorner
        card.layer.cornerCurve = .continuous

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
        progressTrack.backgroundColor = .quaternarySystemFill
        progressTrack.layer.cornerRadius = 2
        progressFill.backgroundColor = PointsSymbol.tint
        progressFill.layer.cornerRadius = 2
        progressFill.translatesAutoresizingMaskIntoConstraints = false
        progressTrack.addSubview(progressFill)
        let earned = UIStackView(arrangedSubviews: [earnedTitle, earnedValue, progressTrack])
        earned.axis = .vertical
        earned.spacing = 3
        earned.setCustomSpacing(Spacing.xs, after: earnedValue)

        let divider = UIView()
        divider.backgroundColor = .separator
        let halves = UIStackView(arrangedSubviews: [streak, divider, earned])
        halves.alignment = .center
        halves.spacing = Spacing.md
        halves.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(halves)

        let column = UIStackView(arrangedSubviews: [tiles, card])
        column.axis = .vertical
        column.spacing = Spacing.sm
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            halves.topAnchor.constraint(equalTo: card.topAnchor, constant: Spacing.md),
            halves.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Spacing.md),
            halves.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Spacing.md),
            halves.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Spacing.md),
            streakDisc.widthAnchor.constraint(equalToConstant: 32),
            streakDisc.heightAnchor.constraint(equalToConstant: 32),
            streakIcon.centerXAnchor.constraint(equalTo: streakDisc.centerXAnchor),
            streakIcon.centerYAnchor.constraint(equalTo: streakDisc.centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 0.5),
            divider.heightAnchor.constraint(equalTo: halves.heightAnchor),
            // The two halves share the card evenly (the divider between).
            earned.widthAnchor.constraint(equalTo: streak.widthAnchor),
            progressTrack.heightAnchor.constraint(equalToConstant: 4),
            progressTrack.widthAnchor.constraint(equalTo: earned.widthAnchor),
            progressFill.leadingAnchor.constraint(equalTo: progressTrack.leadingAnchor),
            progressFill.topAnchor.constraint(equalTo: progressTrack.topAnchor),
            progressFill.bottomAnchor.constraint(equalTo: progressTrack.bottomAnchor),
        ])
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
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = WalletSheetMetrics.rowCorner
        contentView.layer.cornerCurve = .continuous

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
    }

    func configure(stake: WalletStake, entry: FeedEntry?, now: Date, imagePipeline: ImagePipeline?) {
        // The post: who wrote it, and its opening words (a photograph with no
        // caption says what it is instead).
        if let entry {
            titleLabel.text = entry.author.displayName
            let caption = entry.post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
            subtitleLabel.text = caption.isEmpty
                ? (entry.post.attachments.isEmpty ? "Post" : "Photo or video")
                : caption.replacingOccurrences(of: "\n", with: " ")
        } else {
            titleLabel.text = "Post"
            subtitleLabel.text = " "
        }
        applyThumbnail(entry: entry, imagePipeline: imagePipeline)
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
            result.append(walletGlyph(PointsSymbol.glyphImage(), font: resultFont))
            result.append(NSAttributedString(string: " \(stake.amount)", attributes: [
                .font: resultFont, .foregroundColor: UIColor.label,
            ]))
            detailLabel.text = "Settles in \(walletRemainingText(until: stake.settlesAt, now: now))"
        case .gems(let earned):
            result.append(NSAttributedString(string: "+\(earned) ", attributes: [
                .font: resultFont, .foregroundColor: GemSymbol.tint,
            ]))
            result.append(walletGlyph(GemSymbol.glyphImage(), font: resultFont))
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

    private func applyThumbnail(entry: FeedEntry?, imagePipeline: ImagePipeline?) {
        let url = entry?.post.attachments.first.flatMap { $0.thumbnailURL ?? $0.url }
        guard let url, let imagePipeline else {
            // A text post (or one not loaded yet) wears a quote on a tile.
            imageTask?.cancel()
            shownURL = nil
            thumbnail.contentMode = .center
            thumbnail.image = UIImage(
                systemName: entry == nil ? "circle.dotted" : "text.quote",
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
}

/// No active stake: what staking is, in a sentence, where the list would be.
final class WalletEmptyStakesCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        contentView.layer.cornerRadius = WalletSheetMetrics.rowCorner
        contentView.layer.cornerCurve = .continuous
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
/// on one line, pinned under the grabber, so the list below is never read
/// without them.
final class WalletCompactBar: UIView {
    private let label = UILabel()
    private let hairline = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        label.textAlignment = .center
        hairline.backgroundColor = .separator
        for view in [label, hairline] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sm),
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(points: Int, gems: Int) {
        let font = UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        let text = NSMutableAttributedString()
        text.append(walletGlyph(PointsSymbol.glyphImage(), font: font))
        text.append(NSAttributedString(string: " \(points.formatted())     ", attributes: [.font: font]))
        text.append(walletGlyph(GemSymbol.glyphImage(), font: font))
        text.append(NSAttributedString(string: " \(gems.formatted())", attributes: [.font: font]))
        label.attributedText = text
        accessibilityLabel = "\(points) points, \(gems) gems"
    }
}
