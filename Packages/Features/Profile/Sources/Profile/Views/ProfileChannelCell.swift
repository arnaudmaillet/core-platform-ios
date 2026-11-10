import CoreModels
import DesignSystem
import MediaCore
import PostGrid
import UIKit

/// A profile's Channels row's words (#2232), each in one place.
enum ProfileChannelsCopy {
    /// The row's button for `action`. Shorter than the card's "Request to
    /// Join": a row's action shares its line with the channel's name.
    static func title(for action: ChannelEmbed.Action) -> String {
        switch action {
        case .join: "Join"
        case .requestToJoin: "Request"
        case .requested: "Requested"
        case .open: "Open"
        }
    }

    /// Every title the button may wear: its slot holds the widest, so a
    /// change of standing never moves the row's words.
    static let actionTitles: [String] = ChannelEmbed.Action.allCases.map(title(for:))

    static let createTitle = "Create a Channel"
    static let createSubtitle = "Broadcast to the people who follow you."
    static let createSymbol = "plus"
    static let lockSymbol = "lock.fill"

    /// What VoiceOver reads for a row: "Channel Harbour notes, private, 10
    /// subscribers, Boats in, boats out." — the button is its own element.
    static func accessibilityLabel(_ row: ProfileChannel) -> String {
        var parts = ["Channel \(row.channel.displayName)"]
        if row.isPrivate { parts.append("private") }
        parts.append(ChannelEmbedCopy.subscriberCount(row.channel.subscriberCount))
        let about = row.channel.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !about.isEmpty { parts.append(about) }
        return parts.joined(separator: ", ")
    }
}

/// One channel on a profile's Channels tab (#2232): its photo; its name after
/// the channel's megaphone (#2230), with a lock when private; its subscriber
/// count; one line of its description; and, at the end, the viewer's action.
///
/// The action is a ROW action — Join and Request on the tinted ground
/// (#2231's: the action repeated on every row), Requested and Open on the
/// quiet one once acted, as Follow turns Following. Its slot holds the
/// widest title, so a change of standing morphs in place.
final class ProfileChannelCell: UICollectionViewCell {
    static let reuseIdentifier = "ProfileChannelCell"

    /// The button was tapped (Requested's tap is its menu).
    var onAction: (() -> Void)?
    /// Requested's menu confirmed the cancel.
    var onCancelRequest: (() -> Void)?

    private let photo = AvatarView(diameter: MonogramAvatarView.rowDiameter, size: .avatar)
    private let glyph = UIImageView()
    private let nameLabel = UILabel()
    private let lock = UIImageView()
    private let countLabel = UILabel()
    private let descriptionLabel = UILabel()
    private let texts = UIStackView()
    private let button: AppButton = {
        let button = AppButton(aspect: .pill(.tinted), size: .row, content: .title(ProfileChannelsCopy.title(for: .join)))
        button.selectedGround = .quiet
        button.reservedContents = ProfileChannelsCopy.actionTitles.map(AppButton.Content.title)
        button.holdsReservedSize = true
        button.morphAnchor = .trailing
        return button
    }()

    /// The channel shown, to tell a change of standing (a morph) from a
    /// new channel in a reused cell (no animation).
    private var shownID: ConversationID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
        onCancelRequest = nil
    }

    func configure(with row: ProfileChannel, pending: Bool, pipeline: ImagePipeline?) {
        let channel = row.channel
        let sameChannel = shownID == row.id
        shownID = row.id
        photo.setMonogram(MonogramAvatarView.monogram(name: channel.displayName, handle: ""))
        photo.setPicture(channel.photoURL, pipeline: pipeline)
        nameLabel.text = channel.displayName
        lock.isHidden = !row.isPrivate
        countLabel.text = ChannelEmbedCopy.subscriberCount(channel.subscriberCount)
        let about = channel.description.trimmingCharacters(in: .whitespacesAndNewlines)
        descriptionLabel.text = about
        descriptionLabel.isHidden = about.isEmpty
        accessibilityLabel = ProfileChannelsCopy.accessibilityLabel(row)
        applyAction(channel.action, pending: pending, animated: sameChannel && window != nil)
    }

    private func applyAction(_ action: ChannelEmbed.Action?, pending: Bool, animated: Bool) {
        guard let action else {
            button.isHidden = true
            button.menu = nil
            return
        }
        button.isHidden = false
        let quiet = action == .requested || action == .open
        button.setContent(.title(ProfileChannelsCopy.title(for: action)), selected: quiet, animated: animated)
        button.setPhase(pending ? .loading : .content, animated: animated)
        button.haptic = quiet ? nil : .toggleOn
        button.accessibilityHint = action == .requested ? ChannelEmbedCopy.cancelRequestMessage : nil
        // Requested: the tap offers the cancel, a write only once confirmed.
        if action == .requested {
            let cancel = UIAction(title: ChannelEmbedCopy.cancelRequestTitle, attributes: .destructive) { [weak self] _ in
                self?.onCancelRequest?()
            }
            button.menu = UIMenu(title: ChannelEmbedCopy.cancelRequestMessage, children: [cancel])
            button.showsMenuAsPrimaryAction = true
        } else {
            button.menu = nil
            button.showsMenuAsPrimaryAction = false
        }
    }

    /// The write was refused: the button says so.
    func showFailure() {
        button.setPhase(.content, animated: window != nil)
        button.fail()
    }

    @objc private func buttonTapped() {
        onAction?()
    }

    private func build() {
        isAccessibilityElement = false
        photo.translatesAutoresizingMaskIntoConstraints = false
        photo.isUserInteractionEnabled = false

        glyph.image = UIImage(systemName: ChannelEmbedCopy.channelSymbol)
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
        glyph.tintColor = Palette.tint
        lock.image = UIImage(systemName: ProfileChannelsCopy.lockSymbol)
        lock.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption1, scale: .small)
        lock.tintColor = .secondaryLabel
        for mark in [glyph, lock] {
            mark.setContentHuggingPriority(.required, for: .horizontal)
            mark.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        nameLabel.font = .scaledFont(forTextStyle: .subheadline, weight: .semibold)
        nameLabel.textColor = .label
        nameLabel.adjustsFontForContentSizeCategory = true
        let nameRow = UIStackView(arrangedSubviews: [glyph, nameLabel, lock])
        nameRow.axis = .horizontal
        nameRow.alignment = .center
        nameRow.spacing = Spacing.xs

        countLabel.font = .appFont(forTextStyle: .footnote)
        countLabel.textColor = .secondaryLabel
        countLabel.adjustsFontForContentSizeCategory = true
        descriptionLabel.font = .appFont(forTextStyle: .footnote)
        descriptionLabel.textColor = .secondaryLabel
        descriptionLabel.numberOfLines = 1
        descriptionLabel.adjustsFontForContentSizeCategory = true

        texts.axis = .vertical
        texts.spacing = 2
        texts.addArrangedSubview(nameRow)
        texts.addArrangedSubview(countLabel)
        texts.addArrangedSubview(descriptionLabel)
        texts.isAccessibilityElement = true
        texts.setContentHuggingPriority(.defaultLow, for: .horizontal)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addTarget(self, action: #selector(buttonTapped), for: .primaryActionTriggered)

        let row = UIStackView(arrangedSubviews: [photo, texts, button])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.md
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            photo.widthAnchor.constraint(equalToConstant: MonogramAvatarView.rowDiameter),
            photo.heightAnchor.constraint(equalToConstant: MonogramAvatarView.rowDiameter),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.sm),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.sm),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.lg),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.lg),
        ])
    }

    override var accessibilityLabel: String? {
        didSet { texts.accessibilityLabel = accessibilityLabel }
    }

    #if DEBUG
    var debugActionTitle: String? { button.isHidden ? nil : button.content.title }
    var debugActionIsQuiet: Bool { button.isSelected }
    var debugActionOpensMenu: Bool { button.showsMenuAsPrimaryAction && button.menu != nil }
    var debugShowsLock: Bool { !lock.isHidden }
    var debugNameText: String? { nameLabel.text }
    var debugCountText: String? { countLabel.text }
    var debugDescriptionText: String? { descriptionLabel.isHidden ? nil : descriptionLabel.text }
    #endif
}

/// "Create a Channel", leading the viewer's own Channels tab (#2232): a
/// plus on the brand's container disc, in the channel photo's slot, so its
/// words line up with the channels' names.
final class ProfileChannelCreateCell: UICollectionViewCell {
    static let reuseIdentifier = "ProfileChannelCreateCell"

    private let disc = UIView()
    private let plus = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        let side = MonogramAvatarView.rowDiameter
        disc.backgroundColor = Palette.primaryContainer
        disc.layer.cornerRadius = side / 2
        disc.layer.cornerCurve = .circular
        disc.translatesAutoresizingMaskIntoConstraints = false
        plus.image = UIImage(systemName: ProfileChannelsCopy.createSymbol)
        plus.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title3, scale: .medium)
        plus.tintColor = Palette.onPrimaryContainer
        plus.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(plus)

        let title = UILabel()
        title.text = ProfileChannelsCopy.createTitle
        title.font = .scaledFont(forTextStyle: .subheadline, weight: .semibold)
        title.textColor = Palette.brandText
        title.adjustsFontForContentSizeCategory = true
        let subtitle = UILabel()
        subtitle.text = ProfileChannelsCopy.createSubtitle
        subtitle.font = .appFont(forTextStyle: .footnote)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 1
        subtitle.adjustsFontForContentSizeCategory = true
        let texts = UIStackView(arrangedSubviews: [title, subtitle])
        texts.axis = .vertical
        texts.spacing = 2

        let row = UIStackView(arrangedSubviews: [disc, texts])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Spacing.md
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: side),
            disc.heightAnchor.constraint(equalToConstant: side),
            plus.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            plus.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.sm),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Spacing.sm),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.lg),
            row.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Spacing.lg),
        ])

        isAccessibilityElement = true
        accessibilityLabel = ProfileChannelsCopy.createTitle
        accessibilityTraits = .button
    }
}
