import DesignSystem
import UIKit

/// A single chat bubble, aligned trailing (mine) or leading (theirs), capped at
/// ~78% of the thread width.
final class MessageBubbleView: UIView {
    init(model: MessageDisplayModel) {
        super.init(frame: .zero)

        let bubble = UIView()
        bubble.backgroundColor = model.isMine ? .systemBlue : .secondarySystemBackground
        bubble.layer.cornerRadius = 16
        bubble.clipsToBounds = true

        let label = UILabel()
        label.text = model.body
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = model.isMine ? .white : .label
        label.pin(to: bubble, insets: NSDirectionalEdgeInsets(
            top: Spacing.sm, leading: Spacing.md, bottom: Spacing.sm, trailing: Spacing.md
        ))

        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: topAnchor),
            bubble.bottomAnchor.constraint(equalTo: bottomAnchor),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.78),
            model.isMine
                ? bubble.trailingAnchor.constraint(equalTo: trailingAnchor)
                : bubble.leadingAnchor.constraint(equalTo: leadingAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
