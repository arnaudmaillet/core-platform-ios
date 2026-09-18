import DesignSystem
import MediaPlayback
import StickerKit
import UIKit

/// What the band holds while Text is open: an "Add text" card, then one card
/// per text already on the page.
///
/// ```
/// ┌────┐ ┌────┐ ┌────┐
/// │ Aa+│ │Hell│ │Sale│  →
/// └────┘ └────┘ └────┘
/// Add text Hello  Sale
/// ```
///
/// A card opens its text for editing; a long press offers Delete and Bring to
/// front. Metrics follow `MediaFilterRowView`, so the band keeps one height for
/// its rows of cards.
///
/// ⚠️ **IT STORES NOTHING.** It shows the overlays it is handed and says what
/// was tapped; the overlay mode acts.
@MainActor
final class MediaOverlayToolsView: UIView {
    private enum Metrics {
        static let card: CGFloat = 56
        static let corner: CGFloat = 10
        static let caption: CGFloat = 16
        static var height: CGFloat { card + Spacing.xs + caption }
    }

    static var height: CGFloat { Metrics.height }

    enum Action: Equatable {
        case add
        case edit(id: String)
        case delete(id: String)
        case bringToFront(id: String)
    }

    var onAction: ((Action) -> Void)?

    private let scroller = ChipScrollView()
    private let row = UIStackView()
    private(set) var cardIDs: [String] = []

    init(addTitle: String, addSymbol: String) {
        super.init(frame: .zero)
        backgroundColor = .clear
        scroller.showsHorizontalScrollIndicator = false
        scroller.backgroundColor = .clear
        scroller.clipsToBounds = false
        row.axis = .horizontal
        row.spacing = Spacing.sm
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        scroller.pin(to: self)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: Spacing.lg),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor, constant: -Spacing.lg),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            heightAnchor.constraint(equalToConstant: Metrics.height)
        ])
        let add = Self.card(caption: addTitle) { [weak self] in self?.onAction?(.add) }
        add.face.setImage(
            UIImage(systemName: addSymbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)),
            for: .normal
        )
        add.face.tintColor = .label
        add.face.accessibilityLabel = addTitle
        row.addArrangedSubview(add.stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows one card per overlay in `overlays`, in their order.
    func show(_ overlays: [FrameOverlay]) {
        for view in row.arrangedSubviews.dropFirst() { view.removeFromSuperview() }
        cardIDs = overlays.map(\.id)
        for overlay in overlays {
            let id = overlay.id
            let card: (stack: UIStackView, face: UIButton)
            switch overlay.content {
            case .text(let text):
                card = Self.card(caption: text.text) { [weak self] in self?.onAction?(.edit(id: id)) }
                var title = AttributedString(String(text.text.prefix(4)))
                title.font = text.font.editorFont(ofSize: 17)
                title.foregroundColor = text.colour.uiColor
                var configuration = UIButton.Configuration.plain()
                configuration.attributedTitle = title
                card.face.configuration = configuration
                // A dark card whatever the appearance: the words are shown in
                // their own ink, which is white more often than not.
                card.face.backgroundColor = UIColor.black.withAlphaComponent(0.75)
                card.face.accessibilityLabel = "Text, \(text.text)"
                card.face.accessibilityHint = "Edits this text"
            case .emoji(let emoji):
                card = Self.card(caption: "Emoji") { [weak self] in self?.onAction?(.edit(id: id)) }
                var title = AttributedString(emoji)
                title.font = .systemFont(ofSize: 28)
                var configuration = UIButton.Configuration.plain()
                configuration.attributedTitle = title
                card.face.configuration = configuration
                card.face.accessibilityLabel = "Emoji, \(emoji)"
                card.face.accessibilityHint = "Selects it on the picture"
            case .sticker(let stickerID):
                let sticker = StickerCatalog.sticker(id: stickerID)
                card = Self.card(caption: sticker?.label ?? "Sticker") { [weak self] in
                    self?.onAction?(.edit(id: id))
                }
                card.face.imageView?.contentMode = .scaleAspectFit
                if let sticker {
                    let face = card.face
                    StickerCatalog.firstFrame(for: sticker, size: CGSize(width: 88, height: 88)) { image in
                        face.setImage(image, for: .normal)
                    }
                }
                card.face.accessibilityLabel = "Sticker, \(sticker?.label ?? stickerID)"
                card.face.accessibilityHint = "Selects it on the picture"
            }
            card.face.menu = UIMenu(children: [
                UIAction(title: "Bring to front", image: UIImage(systemName: "square.3.layers.3d.top.filled")) {
                    [weak self] _ in self?.onAction?(.bringToFront(id: id))
                },
                UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) {
                    [weak self] _ in self?.onAction?(.delete(id: id))
                }
            ])
            card.face.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: "Bring to front") { [weak self] _ in
                    self?.onAction?(.bringToFront(id: id))
                    return true
                },
                UIAccessibilityCustomAction(name: "Delete") { [weak self] _ in
                    self?.onAction?(.delete(id: id))
                    return true
                }
            ]
            row.addArrangedSubview(card.stack)
        }
    }

    private static func card(caption: String, tap: @escaping @MainActor () -> Void) -> (stack: UIStackView, face: UIButton) {
        let face = UIButton(type: .custom)
        face.backgroundColor = .tertiarySystemFill
        face.layer.cornerRadius = Metrics.corner
        face.layer.cornerCurve = .continuous
        face.clipsToBounds = true
        // ⚠️ **THE FACE GIVES, NOT THE CARD.** The caption under it is a label,
        // not part of the button, and a word that shrank with a picture it is
        // not attached to would read as the whole column being pressed.
        PressFeedback.attach(to: face)
        face.addAction(UIAction { _ in tap() }, for: .touchUpInside)
        NSLayoutConstraint.activate([
            face.widthAnchor.constraint(equalToConstant: Metrics.card),
            face.heightAnchor.constraint(equalToConstant: Metrics.card)
        ])
        let label = UILabel()
        label.text = caption
        label.font = .systemFont(ofSize: 11, weight: .medium)
        // The editor's ground follows the appearance; so does this ink.
        label.textColor = .label
        label.textAlignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.isAccessibilityElement = false
        label.heightAnchor.constraint(equalToConstant: Metrics.caption).isActive = true
        label.widthAnchor.constraint(equalToConstant: Metrics.card).isActive = true
        let stack = UIStackView(arrangedSubviews: [face, label])
        stack.axis = .vertical
        stack.spacing = Spacing.xs
        stack.alignment = .center
        return (stack, face)
    }

    /// Internal for tests: the card faces, "Add" first.
    var debugFaces: [UIButton] {
        row.arrangedSubviews.compactMap { ($0 as? UIStackView)?.arrangedSubviews.first as? UIButton }
    }
    /// Internal for tests: "Add", through the routine its card calls.
    func debugTapAdd() { onAction?(.add) }
}

// MARK: - Arriving

extension MediaOverlayToolsView: PoppingTenant {
    /// "Add text" and every card already placed.
    var poppableElements: [UIView] { row.arrangedSubviews }
}
