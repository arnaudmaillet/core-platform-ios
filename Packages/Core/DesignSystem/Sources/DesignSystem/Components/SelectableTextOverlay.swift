import UIKit

/// "Select Text" for text that is drawn by a `UILabel`.
///
/// A label cannot be selected, and swapping it for a text view permanently
/// would cost every row a text view it almost never uses. So, on demand, a
/// non-editable `UITextView` is laid exactly over the label — same text, same
/// font, zero container insets and padding so the glyphs land where the
/// label's did — the label fades out, and everything is selected. `end()`
/// takes the overlay away and brings the label back.
///
/// Lifted from the chat bubble's own selection mode, with the same three
/// findings kept:
///  - the label fades by ALPHA, never `isHidden`, which would collapse the
///    stack it sits in and resize the row;
///  - the overlay is laid out before `selectAll`, because selecting inside a
///    zero-sized text view shows no handles;
///  - a programmatic selection raises no Copy/Share callout on its own
///    (iOS 16+ only answers user gestures), so an owned
///    `UIEditMenuInteraction` presents it, one runloop later.
@MainActor
public final class SelectableTextOverlay {
    private let label: UILabel
    private let host: UIView
    private lazy var textView = makeTextView()
    private let editMenu = UIEditMenuInteraction(delegate: nil)

    /// Whether the overlay is up.
    public private(set) var isActive = false

    /// `host` must be an ancestor of `label`: the overlay is added there and
    /// pinned to the label's edges.
    public init(label: UILabel, host: UIView) {
        self.label = label
        self.host = host
    }

    /// Lays the overlay over the label and selects all of it. `tint` colours
    /// the selection handles. Idempotent while active.
    public func begin(tint: UIColor = .tintColor) {
        guard !isActive else { return }
        isActive = true
        textView.text = label.text
        textView.font = label.font
        textView.textColor = label.textColor
        textView.tintColor = tint
        textView.isHidden = false
        label.alpha = 0
        host.layoutIfNeeded()
        textView.becomeFirstResponder()
        textView.selectAll(nil)
        DispatchQueue.main.async { [weak self] in self?.presentEditMenu() }
    }

    /// Takes the overlay away and restores the label. Idempotent.
    public func end() {
        guard isActive else { return }
        isActive = false
        textView.resignFirstResponder()
        textView.selectedTextRange = nil
        textView.isHidden = true
        label.alpha = 1
    }

    /// Whether `view` belongs to the overlay — a host deciding whether a tap
    /// landed outside the selection asks this.
    public func contains(_ view: UIView?) -> Bool {
        guard isActive, let view else { return false }
        return view === textView || view.isDescendant(of: textView)
    }

    /// For tests: the overlay's text view, once built.
    var overlayTextView: UITextView { textView }

    private func presentEditMenu() {
        guard isActive, textView.window != nil,
              let range = textView.selectedTextRange else { return }
        let rect = textView.firstRect(for: range)
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(
            identifier: nil, sourcePoint: CGPoint(x: rect.midX, y: rect.minY)
        ))
    }

    private func makeTextView() -> UITextView {
        let textView = UITextView()
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.isHidden = true
        textView.addInteraction(editMenu)
        textView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            textView.topAnchor.constraint(equalTo: label.topAnchor),
            textView.bottomAnchor.constraint(equalTo: label.bottomAnchor),
        ])
        return textView
    }
}
