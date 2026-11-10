import CoreModels
import DesignSystem
import FeedInterface
import MediaCore
import PostGrid
import UIKit

/// A showcase's attachment on the Text Post screen (#2216): the channel's
/// FULL card, as the post will show it, with a ✕ that removes it — the words
/// then publish as a plain text post — and the place the post will stand at
/// on the map, or "Add a Place".
///
/// ```
///   ╭───────────────────────────────╮
///   │ (◉) Daily light 📣        (✕) │
///   │     820 subscribers           │
///   │     Tonight's light…          │
///   │ [            Open           ] │
///   ╰───────────────────────────────╯
///   [📍 Add a Place]   or   [📍 Skatepark de Bercy ✕]
/// ```
///
/// - **The card is a preview here:** it takes no touch — its Open would
///   leave the sheet for the channel the author is sharing — so only the ✕
///   and the place answer.
/// - **The place is the showcase's:** removing the card removes it too, as a
///   text post carries no place (`TextPostPlace`).
final class ShowcaseAttachmentView: UIView {
    /// The ✕: the author takes the card off.
    var onRemove: (() -> Void)?
    /// "Add a Place" (or a tap on the place shown, to change it).
    var onPickPlace: (() -> Void)?
    /// The place's own ✕: the post will stand nowhere on the map.
    var onClearPlace: (() -> Void)?

    let card = PostEmbedView()
    private let removeButton = AppIconButton(style: .bubble(.material), content: .symbol("xmark"))
    private let placeButton = AppButton(
        aspect: .pill(.quiet), size: .row, content: AppButton.Content(title: ShowcaseCopy.addPlace, symbol: "mappin.and.ellipse")
    )
    private let clearPlaceButton = AppIconButton(style: .glyph, content: .symbol("xmark.circle.fill"))
    private let stack = UIStackView()
    private(set) var place: TextPostPlace?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        removeButton.accessibilityLabel = ShowcaseCopy.removeCard
        removeButton.addAction(UIAction { [weak self] _ in self?.onRemove?() }, for: .primaryActionTriggered)
        placeButton.addAction(UIAction { [weak self] _ in self?.onPickPlace?() }, for: .primaryActionTriggered)
        clearPlaceButton.inkColor = .secondaryLabel
        clearPlaceButton.accessibilityLabel = ShowcaseCopy.removePlace
        clearPlaceButton.isHidden = true
        clearPlaceButton.addAction(UIAction { [weak self] _ in self?.onClearPlace?() }, for: .primaryActionTriggered)

        let placeRow = UIStackView(arrangedSubviews: [placeButton, clearPlaceButton, UIView()])
        placeRow.axis = .horizontal
        placeRow.alignment = .center
        placeRow.spacing = Spacing.xs

        // The card is the post's, drawn as its page will draw it.
        let cardHolder = UIView()
        card.translatesAutoresizingMaskIntoConstraints = false
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        cardHolder.addSubview(card)
        cardHolder.addSubview(removeButton)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: cardHolder.topAnchor),
            card.leadingAnchor.constraint(equalTo: cardHolder.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: cardHolder.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: cardHolder.bottomAnchor),
            // The ✕ sits on the card's corner, as a removable attachment's.
            removeButton.topAnchor.constraint(equalTo: cardHolder.topAnchor, constant: Spacing.xs),
            removeButton.trailingAnchor.constraint(equalTo: cardHolder.trailingAnchor, constant: -Spacing.xs),
        ])

        stack.axis = .vertical
        stack.spacing = Spacing.sm
        stack.addArrangedSubview(cardHolder)
        stack.addArrangedSubview(placeRow)
        stack.pin(to: self)
    }

    /// Shows `embed`'s card, full size.
    func show(_ embed: PostEmbed, pipeline: ImagePipeline?) {
        card.show(embed, size: .full, pipeline: pipeline)
        // A preview: the card's own action would leave the sheet.
        card.isUserInteractionEnabled = false
    }

    /// Shows `place`, or the invitation to add one.
    func setPlace(_ place: TextPostPlace?) {
        self.place = place
        let content = AppButton.Content(title: place?.name ?? ShowcaseCopy.addPlace, symbol: "mappin.and.ellipse")
        placeButton.setContent(content, animated: window != nil)
        placeButton.accessibilityHint = place == nil ? ShowcaseCopy.addPlaceHint : ShowcaseCopy.changePlaceHint
        clearPlaceButton.isHidden = place == nil
    }

    #if DEBUG
    var debugPlaceTitle: String? { placeButton.content.title }
    var debugShowsClearPlace: Bool { !clearPlaceButton.isHidden }
    func debugRemove() { onRemove?() }
    func debugClearPlace() { onClearPlace?() }
    #endif
}

/// The showcase composer's words (#2216), in one place.
enum ShowcaseCopy {
    static let addPlace = "Add a Place"
    static let addPlaceHint = "Shows the post on the map at a place you choose."
    static let changePlaceHint = "Choose another place."
    static let removePlace = "Remove place"
    static let removeCard = "Remove channel card"
}
