import CoreModels
import CoreStorage
import DesignSystem
import MediaCore
import PostGrid
import UIKit

// The pieces of the Wallet sheet's lists (#1494, `WalletSheetViewController`):
// the stake rows and their section headers. The sheet's top block and the
// likes gauge are `WalletSheetViews.swift`.
//
// ⚠️ **CARDS ONLY FOR WHAT CAN BE PRESSED** (26 September 2026): a card is the
// app's promise that a thing can be pressed, so balances sit bare on the sheet
// and the cards are the stake rows (which open their post), the gems card and
// the activity. The sheet's ground is the SYSTEM's (glass while small,
// opaque once large), so the rows wear a translucent fill that reads on both.

// MARK: - Shared

enum WalletSheetMetrics {
    static let sideMargin: CGFloat = Spacing.lg
    static let thumbnail: CGFloat = 48
    /// The thumbnail's corner (#1494): concentric with its card's, which it
    /// sits `Spacing.sm` inside — a little rounder than a list's media.
    static let thumbnailCorner: CGFloat = Surface.cardCornerRadius - Spacing.sm
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

// MARK: - Stakes

/// One stake: the post it was placed on, and where it stands.
///
/// The POST leads (#1395): the viewer staked on a post, not on a person, so
/// the title is its opening words and the author is the line under them.
///
/// ACTIVE — the likes committed and how long until it settles.
/// SETTLED — what it earned in gems, or "No reward" (a normal outcome: the
/// charter pays demonstrated value, not attention), and how long ago. Gem
/// violet only beside a gem amount: the server's "Rewarded" (shadow mode, no
/// gems credited) is in the secondary ink.
///
/// A card, and a pressable one: it opens the post in the feed, flying from
/// its thumbnail (media) or revealing from the card (text) — see
/// `WalletSheetViewController.openFeed`.
///
/// The stake is local and always known; the POST is a lookup (#834). While
/// it is out, the post part — thumbnail, author, caption — is bones laid over
/// the very views they stand for (charter P8/P9), and the amount and
/// countdown stay real; when it lands the bones cross-fade to the post (P10).
/// A lookup that failed says so in the caption line, and a tap on the row
/// tries again.
class WalletStakeCell: UICollectionViewListCell {
    private let thumbnail = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let resultLabel = UILabel()
    /// The outcome as a chip once settled (#1477): a ground under the
    /// verdict, grey for words, the gems' violet only for gems. Bare for an
    /// active stake's amount.
    private let resultChip = UIStackView()
    private let detailLabel = UILabel()
    /// How far an active stake is toward settling (#1477), before its
    /// "Settles in" line.
    private let settleRing = WalletSettleRing()
    /// Over the outcome while the server's verdict is on its way (#1395).
    private let resultBone = SkeletonBoneView()
    /// The thumbnail and the two lines: what the bones stand in for.
    private let postContent = UIStackView()
    private let bones = UIView()
    private var imageTask: Task<Void, Never>?
    private var shownURL: URL?
    /// The post state drawn now; nil on a fresh or recycled row.
    private var shownPhase: WalletStakePostLoads.State?
    private var pressRecognizers: [UIGestureRecognizer] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        // A row of its section's one card (#1494): the card is the
        // section's — the Rewards sheet's decoration, the Stakes screen's
        // inset-grouped list — so the row draws no ground of its own.
        backgroundConfiguration = .clear()
        // The app's one press: the card gives a little under the finger.
        PressFeedback.attach(toView: contentView, sound: nil)
        // Its watcher, switched off while a tap would do nothing (a row on
        // its bones): a card that gives and then opens nothing lies.
        pressRecognizers = contentView.gestureRecognizers ?? []

        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        // Concentric with the card (#1494) — and the flight's corner too
        // (`WalletStakeHero`), so a post flying home lands on its shape.
        thumbnail.layer.cornerRadius = WalletSheetMetrics.thumbnailCorner
        thumbnail.layer.cornerCurve = .continuous
        thumbnail.backgroundColor = .tertiarySystemFill
        thumbnail.tintColor = .secondaryLabel

        titleLabel.font = .scaledSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        subtitleLabel.font = .scaledSystemFont(ofSize: 13, relativeTo: .footnote)
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = .secondaryLabel
        resultLabel.textAlignment = .right
        detailLabel.font = .scaledMonospacedDigitSystemFont(ofSize: 12, relativeTo: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.textAlignment = .right
        for label in [resultLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 2
        postContent.addArrangedSubview(thumbnail)
        postContent.addArrangedSubview(text)
        postContent.spacing = Spacing.sm
        postContent.alignment = .center
        resultChip.addArrangedSubview(resultLabel)
        resultChip.isLayoutMarginsRelativeArrangement = true
        resultChip.layer.cornerCurve = .continuous
        let detailLine = UIStackView(arrangedSubviews: [settleRing, detailLabel])
        detailLine.spacing = 4
        detailLine.alignment = .center
        let trailing = UIStackView(arrangedSubviews: [resultChip, detailLine])
        trailing.axis = .vertical
        trailing.alignment = .trailing
        trailing.spacing = 2
        let row = UIStackView(arrangedSubviews: [postContent, trailing])
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
        buildBones()
        resultBone.translatesAutoresizingMaskIntoConstraints = false
        resultBone.isHidden = true
        contentView.addSubview(resultBone)
        NSLayoutConstraint.activate([
            resultBone.trailingAnchor.constraint(equalTo: resultLabel.trailingAnchor),
            resultBone.centerYAnchor.constraint(equalTo: resultLabel.centerYAnchor),
            resultBone.widthAnchor.constraint(equalTo: resultLabel.widthAnchor),
            resultBone.heightAnchor.constraint(equalTo: resultLabel.heightAnchor, multiplier: 0.6),
        ])
        isAccessibilityElement = true
    }

    /// The post part's skeleton: a tile bone ON the thumbnail and a line bone
    /// on each label, so the swap to the post moves nothing (P8). The labels
    /// keep a line of text under them while loading, which holds the row's
    /// height.
    private func buildBones() {
        bones.isUserInteractionEnabled = false
        bones.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bones)
        let tile = SkeletonBoneView(rounding: .fixed(WalletSheetMetrics.thumbnailCorner))
        let title = SkeletonBoneView()
        let subtitle = SkeletonBoneView()
        for bone in [tile, title, subtitle] {
            bone.translatesAutoresizingMaskIntoConstraints = false
            bones.addSubview(bone)
        }
        NSLayoutConstraint.activate([
            bones.topAnchor.constraint(equalTo: postContent.topAnchor),
            bones.leadingAnchor.constraint(equalTo: postContent.leadingAnchor),
            bones.trailingAnchor.constraint(equalTo: postContent.trailingAnchor),
            bones.bottomAnchor.constraint(equalTo: postContent.bottomAnchor),
            tile.topAnchor.constraint(equalTo: thumbnail.topAnchor),
            tile.leadingAnchor.constraint(equalTo: thumbnail.leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor),
            tile.bottomAnchor.constraint(equalTo: thumbnail.bottomAnchor),
            // A line bone is the cap height's band of its label, not the
            // label's whole line box: a bone as tall as the line reads as a
            // block, not as text.
            title.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            title.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            title.heightAnchor.constraint(equalTo: titleLabel.heightAnchor, multiplier: 0.6),
            title.widthAnchor.constraint(equalTo: postContent.widthAnchor, multiplier: 0.35),
            subtitle.leadingAnchor.constraint(equalTo: subtitleLabel.leadingAnchor),
            subtitle.centerYAnchor.constraint(equalTo: subtitleLabel.centerYAnchor),
            subtitle.heightAnchor.constraint(equalTo: subtitleLabel.heightAnchor, multiplier: 0.6),
            subtitle.widthAnchor.constraint(equalTo: postContent.widthAnchor, multiplier: 0.6),
        ])
        bones.isHidden = true
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
        // A fade that was running belongs to the row's previous stake.
        postContent.layer.removeAllAnimations()
        bones.layer.removeAllAnimations()
        shownPhase = nil
    }

    /// `phase` is where the post's lookup stands; `animated` cross-fades the
    /// bones out when it has just landed — false from inside a data source
    /// apply, which swallows the animation anyway. `pressable` is whether a
    /// tap does anything (opens the post, or retries a failed one): the card
    /// gives under the finger only then.
    /// `verdictPending`: the server's verdict on a settled stake is still to
    /// come (`WalletStore.awaitsServerStakes`), so its outcome is a bone.
    func configure(
        stake: WalletStake, post: GalleryPost?, phase: WalletStakePostLoads.State,
        pressable: Bool, now: Date, imagePipeline: ImagePipeline?, animated: Bool,
        verdictPending: Bool = false
    ) {
        for recognizer in pressRecognizers { recognizer.isEnabled = pressable }
        // The post: its opening words (a photograph with no caption says what
        // it is instead), then who wrote it.
        if let post {
            titleLabel.text = Self.title(of: post)
            subtitleLabel.text = post.authorName ?? " "
        } else {
            titleLabel.text = "Post"
            // Under the bones while loading: a line of text holds the row's
            // height, so the post landing moves nothing.
            subtitleLabel.text = phase == .failed ? "Couldn't load this post" : " "
        }
        applyThumbnail(post: post, failed: phase == .failed, imagePipeline: imagePipeline)
        applyStatus(stake: stake, now: now, verdictPending: verdictPending)
        applyPhase(phase, animated: animated)
        accessibilityLabel = phase == .loading
            ? "Loading post"
            : [titleLabel.text, subtitleLabel.text].compactMap { $0 }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", ")
    }

    /// Bones while the post is out; the post once it is in — cross-faded
    /// when it lands under the viewer's eyes, set outright otherwise. A row
    /// already showing its post is left alone, so a refresh in the middle of
    /// the fade does not cut it short.
    private func applyPhase(_ phase: WalletStakePostLoads.State, animated: Bool) {
        let previous = shownPhase
        shownPhase = phase
        if phase == .loading {
            postContent.alpha = 0
            bones.showSkeleton()
            return
        }
        guard previous == nil || previous == .loading else { return }
        if previous == .loading, animated, window != nil {
            bones.crossfadeSkeleton(to: postContent)
        } else {
            bones.isHidden = true
            postContent.alpha = 1
        }
    }

    /// The row's title: the post's opening words, on one line; a post with
    /// no caption says what it is.
    static func title(of post: GalleryPost) -> String {
        let caption = post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caption.isEmpty else { return post.kind == .text ? "Post" : "Photo or video" }
        return caption.replacingOccurrences(of: "\n", with: " ")
    }

    /// The part that moves with the clock — rewritten every second for an
    /// active stake, without reconfiguring the rest.
    func applyStatus(stake: WalletStake, now: Date, verdictPending: Bool = false) {
        let resultFont = UIFont.scaledMonospacedDigitSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline)
        let wordFont = UIFont.scaledSystemFont(ofSize: 15, weight: .medium, relativeTo: .subheadline)
        let detailFont = detailLabel.font ?? .scaledMonospacedDigitSystemFont(ofSize: 12, relativeTo: .caption1)
        let ago = walletAgoText(since: stake.settlesAt, now: now)
        let staked = StakeMenu.likes(stake.amount) + " staked"
        let result = NSMutableAttributedString()
        // "10 ♥ staked · 2d ago": the amount in the sheet's one order, its
        // glyph after it (`walletAmount`).
        func detail(_ tail: String) -> NSAttributedString {
            let line = NSMutableAttributedString(attributedString: walletAmount(
                "\(stake.amount)", glyph: LikesSymbol.glyphImage(), font: detailFont, color: .secondaryLabel
            ))
            line.append(NSAttributedString(string: tail, attributes: [
                .font: detailFont, .foregroundColor: UIColor.secondaryLabel,
            ]))
            return line
        }
        func words(_ text: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: wordFont, .foregroundColor: UIColor.secondaryLabel])
        }
        // What VoiceOver reads after the post: the amount with its unit, then
        // the outcome.
        let spoken: [String]
        // ⚠️ A SETTLED OUTCOME THE SERVER HAS NOT GIVEN YET IS A BONE
        // (#1395): the device's "+1" turned into the server's "Rewarded"
        // under the viewer's eyes, once the listing landed.
        let pending = verdictPending && stake.isSettled
        resultBone.isHidden = !pending
        switch stake.outcome {
        case _ where pending:
            // The widest verdict's room under the bone, in no ink: a label's
            // alpha is not trusted on the sheet's glass.
            result.append(NSAttributedString(string: "Rewarded", attributes: [
                .font: wordFont, .foregroundColor: UIColor.clear,
            ]))
            detailLabel.attributedText = detail(" staked · \(ago)")
            spoken = [staked, ago, "result loading"]
        case nil:
            result.append(walletAmount("\(stake.amount)", glyph: LikesSymbol.glyphImage(), font: resultFont))
            let remaining = walletRemainingText(until: stake.settlesAt, now: now)
            detailLabel.attributedText = NSAttributedString(string: "Settles in \(remaining)", attributes: [
                .font: detailFont, .foregroundColor: UIColor.secondaryLabel,
            ])
            spoken = [staked, "settles in \(remaining)"]
        case .gems(let earned):
            result.append(walletAmount(
                "+\(earned)", glyph: GemSymbol.glyphImage(), font: resultFont, color: GemSymbol.tint
            ))
            detailLabel.attributedText = detail(" staked · \(ago)")
            spoken = [staked, ago, earned == 1 ? "earned 1 gem" : "earned \(earned) gems"]
        case .noReward, .notRewarded:
            result.append(words("No reward"))
            detailLabel.attributedText = detail(" staked · \(ago)")
            spoken = [staked, ago, "no reward"]
        // The server's verdicts (#903): the outcome alone, never gems the
        // balance does not hold while settlement runs in shadow mode — and
        // so not in gem violet either, which promises gems.
        case .rewarded:
            result.append(words("Rewarded"))
            detailLabel.attributedText = detail(" staked · \(ago)")
            spoken = [staked, ago, "rewarded"]
        case .pending:
            result.append(words("Result tomorrow"))
            detailLabel.attributedText = detail(" staked · settled \(ago)")
            spoken = [staked, "settled \(ago)", "result tomorrow"]
        }
        resultLabel.attributedText = result
        applyChip(for: pending ? nil : stake.outcome, pending: pending)
        settleRing.isHidden = stake.isSettled
        settleRing.progress = stake.settleProgress(at: now)
        accessibilityValue = spoken.joined(separator: ", ")
    }

    /// The outcome's chip: gems on the gems' violet wash, every verdict in
    /// words on a grey one — so violet always means gems (#1477). An active
    /// stake's amount, and a verdict still on its way, wear none.
    private func applyChip(for outcome: WalletStake.Outcome?, pending: Bool) {
        let ground: UIColor? = switch outcome {
        case nil: nil
        case .gems: GemSymbol.tint.withAlphaComponent(0.16)
        case .noReward, .notRewarded, .rewarded, .pending: .tertiarySystemFill
        }
        resultChip.backgroundColor = ground
        resultChip.directionalLayoutMargins = ground == nil
            ? .zero
            : NSDirectionalEdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8)
        resultChip.layer.cornerRadius = ground == nil ? 0 : resultChip.bounds.height / 2
        resultChip.setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A capsule at whatever height the text size gives it.
        if resultChip.backgroundColor != nil { resultChip.layer.cornerRadius = resultChip.bounds.height / 2 }
    }

    /// The chip's ground now. Tests and QA.
    var drawnChipGround: UIColor? { resultChip.backgroundColor }
    /// The ring's progress, or nil when it is not shown.
    var drawnSettleProgress: Double? { settleRing.isHidden ? nil : settleRing.progress }

    private func applyThumbnail(post: GalleryPost?, failed: Bool, imagePipeline: ImagePipeline?) {
        let url = post.flatMap { $0.kind == .text ? nil : $0.thumbnailURL }
        guard let url, let imagePipeline else {
            // A text post wears a quote on a tile; a post that could not be
            // loaded, a warning — never the dotted "on its way" circle, which
            // read as still loading.
            imageTask?.cancel()
            shownURL = nil
            thumbnail.contentMode = .center
            let symbol = post != nil ? "text.quote" : failed ? "exclamationmark.triangle" : "circle.dotted"
            thumbnail.image = UIImage(
                systemName: symbol,
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
    /// to and from (`WalletSheetViewController.heroOrigin`).
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
/// A stake row inside its section's one card (#1494, the Wallet sheet's
/// Active stakes): no card of its own, a hairline between rows.
final class WalletGroupedStakeCell: WalletStakeCell {
    private let separator = UIView()

    /// Whether the hairline over the row shows: every row but the first.
    var showsSeparator = false {
        didSet { separator.isHidden = !showsSeparator }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        separator.backgroundColor = .separator
        separator.isHidden = true
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        let hairline = separator.heightAnchor.constraint(equalToConstant: Surface.hairline(for: traitCollection))
        NSLayoutConstraint.activate([
            hairline,
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.sm + WalletSheetMetrics.thumbnail + Spacing.sm),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        registerForTraitChanges([UITraitDisplayScale.self]) { (cell: WalletGroupedStakeCell, _: UITraitCollection) in
            hairline.constant = Surface.hairline(for: cell.traitCollection)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

final class WalletEmptyStakesCell: UICollectionViewCell {
    /// "Find a post to stake" (#1494): where staking is — a like on a post,
    /// in the feeds. Nil hides the button.
    var onFindPosts: (() -> Void)? {
        didSet { findButton.isHidden = onFindPosts == nil }
    }

    private let findButton = UIButton(configuration: .tinted())

    override init(frame: CGRect) {
        super.init(frame: frame)
        // The Active stakes card's whole content (#1494): no card of its own,
        // centred in what is left of the sheet's height (the list sizes it).
        let icon = UIImageView(image: LikesSymbol.glyphImage(UIImage.SymbolConfiguration(pointSize: 32, weight: .regular)))
        icon.contentMode = .center
        let title = UILabel()
        title.text = "No active stakes"
        title.font = .scaledSystemFont(ofSize: 17, weight: .semibold, relativeTo: .headline)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        let body = UILabel()
        let hours = Int(WalletStore.Policy.settlementDelay / 3600)
        body.text = "Stake likes on a post you believe in. Each stake settles \(hours) hours later — and may earn gems."
        body.font = .scaledSystemFont(ofSize: 13, relativeTo: .footnote)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = .secondaryLabel
        body.numberOfLines = 0
        body.textAlignment = .center

        // The failed row's tinted capsule (`WalletStakesFailedCell`).
        var button = UIButton.Configuration.tinted()
        button.cornerStyle = .capsule
        button.baseForegroundColor = Palette.tint
        button.baseBackgroundColor = Palette.tint
        button.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        button.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.appFont(forTextStyle: .subheadline)
            return attributes
        }
        button.title = "Find a post to stake"
        findButton.configuration = button
        findButton.accessibilityIdentifier = "wallet.stakes.find"
        findButton.isHidden = true
        findButton.addAction(UIAction { [weak self] _ in self?.onFindPosts?() }, for: .primaryActionTriggered)

        let column = UIStackView(arrangedSubviews: [icon, title, body, findButton])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = Spacing.xs
        column.setCustomSpacing(Spacing.sm, after: icon)
        column.setCustomSpacing(Spacing.md, after: body)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: Spacing.xl),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.xl),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.xl),
            column.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -Spacing.xl),
            column.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onFindPosts = nil
    }
}

/// Some stakes' posts could not be loaded (#834): says so at the head of a
/// section whose rows failed (`WalletStakeList`), with Try Again — which asks for those posts only, never the whole
/// sheet. The empty card's shape and type, so the list keeps one voice.
final class WalletStakesFailedCell: UICollectionViewListCell {
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let retryButton = UIButton(configuration: .plain())
    /// Try Again was pressed.
    var onRetry: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // A row of the Active stakes card (#1494): no card of its own.
        titleLabel.text = "Couldn't load some posts"
        titleLabel.font = .scaledSystemFont(ofSize: 15, weight: .semibold, relativeTo: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.font = .scaledSystemFont(ofSize: 13, relativeTo: .footnote)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = .secondaryLabel
        bodyLabel.numberOfLines = 0

        // A tinted capsule in the brand's tint (#1124): plain tinted text drew
        // in the sheet's vibrant ink — black on the glass — and read as one
        // more line of the message, not as a button (filmed, 10 October 2026).
        var button = UIButton.Configuration.tinted()
        button.cornerStyle = .capsule
        button.baseForegroundColor = Palette.tint
        button.baseBackgroundColor = Palette.tint
        button.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
        button.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.appFont(forTextStyle: .subheadline)
            return attributes
        }
        button.title = "Try Again"
        retryButton.configuration = button
        retryButton.contentHorizontalAlignment = .leading
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)

        let column = UIStackView(arrangedSubviews: [titleLabel, bodyLabel, retryButton])
        column.axis = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.setCustomSpacing(Spacing.sm, after: bodyLabel)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.md),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.md),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.md),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.md),
        ])
        configure(retrying: false, failedAfterRetry: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRetry = nil
    }

    /// While a Try Again is out the row STAYS, saying so with its button off
    /// (`WalletStakeList`); a retry that failed too says so, rather than
    /// repeating the first message as if nothing had been tried.
    func configure(retrying: Bool, failedAfterRetry: Bool) {
        bodyLabel.text = failedAfterRetry
            ? "Still couldn't load them. Check your connection and try again in a moment."
            : "Your stakes are safe. Check your connection and try again."
        retryButton.configuration?.title = retrying ? "Trying Again…" : "Try Again"
        retryButton.isEnabled = !retrying
    }
}

/// A section's title — the app's one (`SectionTitleView`) — and, at the
/// trailing end, what the section adds up to (its accessory).
final class WalletSectionHeader: UICollectionReusableView {
    static let kind = "wallet.sectionHeader"
    let titleView = SectionTitleView()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        detailLabel.font = .scaledMonospacedDigitSystemFont(ofSize: 13, weight: .medium, relativeTo: .footnote, maximumPointSize: 16)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        titleView.trailingAccessory = detailLabel
        titleView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleView)
        NSLayoutConstraint.activate([
            titleView.topAnchor.constraint(equalTo: topAnchor),
            titleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The heading's tap, when it leads somewhere (`isLink`).
    var onSeeAll: (() -> Void)? {
        didSet { titleView.onTap = onSeeAll }
    }

    func configure(title: String, detail: NSAttributedString?, isLink: Bool = false) {
        titleView.content = .init(title: title, isLink: isLink)
        detailLabel.attributedText = detail
        detailLabel.isHidden = (detail?.length ?? 0) == 0
        titleView.setNeedsLayout()
    }
}

/// A small ring that fills as a stake nears its settlement (#1477): a quiet
/// track, the likes' pink for the time gone — the likes it holds are the
/// ones that come back.
final class WalletSettleRing: UIView {
    static let diameter: CGFloat = 11
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()

    /// 0 when placed, 1 at settlement.
    var progress: Double = 0 {
        didSet { fill.strokeEnd = CGFloat(min(1, max(0, progress))) }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for shape in [track, fill] {
            shape.fillColor = nil
            shape.lineWidth = 2
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        fill.strokeEnd = 0
        applyColours()
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]
        ) { (ring: WalletSettleRing, _: UITraitCollection) in
            ring.applyColours()
        }
        isAccessibilityElement = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.diameter, height: Self.diameter) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset = track.lineWidth / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        // From twelve o'clock, clockwise — a clock's way.
        let path = UIBezierPath(
            arcCenter: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true
        ).cgPath
        track.frame = bounds
        fill.frame = bounds
        track.path = path
        fill.path = path
    }

    private func applyColours() {
        track.strokeColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
        fill.strokeColor = LikesSymbol.tint.resolvedColor(with: traitCollection).cgColor
    }
}
